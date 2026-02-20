// Docudactyl Processing Stages — Configurable Analysis Pipeline
//
// Each stage is enabled via a bitmask flag passed to ddac_parse.
// Stage results are written to {output_path}.stages.capnp in Cap'n Proto
// binary format (see schema/stages.capnp for the wire format).
//
// Stage tiers (approximate per-document throughput):
//   Lightning (>100 docs/s): PREMIS, exact_dedup, merkle_proof
//   Fast (10-50 docs/s):     language_detect, readability, keywords, citations
//   Medium (0.2-5 docs/s):   ocr_confidence, perceptual_hash, toc_extract
//   Slow (minutes/doc):      multi_lang_ocr, whisper, handwriting_ocr (ML stubs)
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

const std = @import("std");
const capnp = @import("capnp.zig");

// C library bindings — same libraries linked by build.zig
const c = @cImport({
    @cInclude("poppler/glib/poppler.h");
    @cInclude("tesseract/capi.h");
    @cInclude("leptonica/allheaders.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/dict.h");
    @cInclude("gdal.h");
    @cInclude("cpl_conv.h");
    @cInclude("vips/vips.h");
});

// ============================================================================
// Stage Bitmask Constants
// ============================================================================

pub const STAGE_NONE: u64 = 0;

// Text analysis stages
pub const STAGE_LANGUAGE_DETECT: u64 = 1 << 0;
pub const STAGE_READABILITY: u64 = 1 << 1;
pub const STAGE_KEYWORDS: u64 = 1 << 2;
pub const STAGE_CITATION_EXTRACT: u64 = 1 << 3;

// Image/OCR stages
pub const STAGE_OCR_CONFIDENCE: u64 = 1 << 4;
pub const STAGE_PERCEPTUAL_HASH: u64 = 1 << 5;

// Document structure stages
pub const STAGE_TOC_EXTRACT: u64 = 1 << 6;
pub const STAGE_MULTI_LANG_OCR: u64 = 1 << 7;

// Audio/Video stages
pub const STAGE_SUBTITLE_EXTRACT: u64 = 1 << 8;

// Preservation/Integrity stages
pub const STAGE_PREMIS_METADATA: u64 = 1 << 9;
pub const STAGE_MERKLE_PROOF: u64 = 1 << 10;
pub const STAGE_EXACT_DEDUP: u64 = 1 << 11;
pub const STAGE_NEAR_DEDUP: u64 = 1 << 12;
pub const STAGE_COORD_NORMALIZE: u64 = 1 << 13;

// ML-dependent stages (stub implementations)
pub const STAGE_NER: u64 = 1 << 14;
pub const STAGE_WHISPER_TRANSCRIBE: u64 = 1 << 15;
pub const STAGE_IMAGE_CLASSIFY: u64 = 1 << 16;
pub const STAGE_LAYOUT_ANALYSIS: u64 = 1 << 17;
pub const STAGE_HANDWRITING_OCR: u64 = 1 << 18;
pub const STAGE_FORMAT_CONVERT: u64 = 1 << 19;

/// Total number of defined stages.
pub const STAGE_COUNT: u6 = 20;

// ── Presets ──────────────────────────────────────────────────────────────

/// All stages enabled.
pub const STAGE_ALL: u64 = (@as(u64, 1) << STAGE_COUNT) - 1;

/// Fast stages only — minimal I/O overhead, no re-reading input.
pub const STAGE_FAST: u64 = STAGE_LANGUAGE_DETECT | STAGE_READABILITY |
    STAGE_KEYWORDS | STAGE_EXACT_DEDUP | STAGE_PREMIS_METADATA |
    STAGE_MERKLE_PROOF | STAGE_CITATION_EXTRACT;

/// Analysis stages — includes fast + format-specific re-reads.
pub const STAGE_ANALYSIS: u64 = STAGE_FAST | STAGE_OCR_CONFIDENCE |
    STAGE_PERCEPTUAL_HASH | STAGE_TOC_EXTRACT | STAGE_NEAR_DEDUP |
    STAGE_COORD_NORMALIZE | STAGE_SUBTITLE_EXTRACT;

/// Default: no extra stages (base parse only).
pub const STAGE_DEFAULT: u64 = STAGE_NONE;

// ============================================================================
// Stage Context — passed from ddac_parse to runStages
// ============================================================================

/// Content kind values (mirrors ContentKind enum in docudactyl_ffi.zig)
pub const CK_PDF: c_int = 0;
pub const CK_IMAGE: c_int = 1;
pub const CK_AUDIO: c_int = 2;
pub const CK_VIDEO: c_int = 3;
pub const CK_EPUB: c_int = 4;
pub const CK_GEOSPATIAL: c_int = 5;

/// All data stages need, using basic types to avoid circular imports.
pub const StageContext = struct {
    stages: u64,
    input_path: [*:0]const u8,
    output_path: [*:0]const u8,
    content_kind: c_int,
    sha256: *const [65]u8,
    mime_type: *const [64]u8,
    page_count: i32,
    word_count: i64,
    char_count: i64,
    duration_sec: f64,
    /// Tesseract OCR confidence (0-100) captured during base parse, or -1.
    ocr_confidence: i32,
    /// Tesseract API handle (opaque, cast to *TessBaseAPI inside stages).
    tess_api: ?*anyopaque,
};

// ============================================================================
// Text Reading Helper
// ============================================================================

const MAX_TEXT_READ: usize = 1024 * 1024; // 1 MB cap for text analysis

/// Read extracted text from the output file (written by base parse).
fn readExtractedText(output_path: [*:0]const u8, allocator: std.mem.Allocator) ?[]u8 {
    const file = std.fs.openFileAbsoluteZ(output_path, .{}) catch return null;
    defer file.close();

    const stat = file.stat() catch return null;
    const read_size = @min(stat.size, MAX_TEXT_READ);
    if (read_size == 0) return null;

    const buf = allocator.alloc(u8, read_size) catch return null;
    const n = file.readAll(buf) catch {
        allocator.free(buf);
        return null;
    };
    return buf[0..n];
}

// ============================================================================
// Stop Words (English)
// ============================================================================

/// Compile-time perfect hash map for O(1) stop-word lookup.
/// Replaces the previous linear scan over ~120 entries.
const stop_word_map = std.StaticStringMap(void).initComptime(.{
    .{ "a", {} },       .{ "about", {} },   .{ "after", {} },   .{ "all", {} },
    .{ "also", {} },    .{ "am", {} },      .{ "an", {} },      .{ "and", {} },
    .{ "any", {} },     .{ "are", {} },     .{ "as", {} },      .{ "at", {} },
    .{ "be", {} },      .{ "been", {} },    .{ "before", {} },  .{ "being", {} },
    .{ "between", {} }, .{ "both", {} },    .{ "but", {} },     .{ "by", {} },
    .{ "can", {} },     .{ "could", {} },   .{ "did", {} },     .{ "do", {} },
    .{ "does", {} },    .{ "doing", {} },   .{ "down", {} },    .{ "during", {} },
    .{ "each", {} },    .{ "few", {} },     .{ "for", {} },     .{ "from", {} },
    .{ "further", {} }, .{ "get", {} },     .{ "got", {} },     .{ "had", {} },
    .{ "has", {} },     .{ "have", {} },    .{ "he", {} },      .{ "her", {} },
    .{ "here", {} },    .{ "him", {} },     .{ "his", {} },     .{ "how", {} },
    .{ "i", {} },       .{ "if", {} },      .{ "in", {} },      .{ "into", {} },
    .{ "is", {} },      .{ "it", {} },      .{ "its", {} },     .{ "just", {} },
    .{ "may", {} },     .{ "me", {} },      .{ "might", {} },   .{ "more", {} },
    .{ "most", {} },    .{ "must", {} },    .{ "my", {} },      .{ "no", {} },
    .{ "nor", {} },     .{ "not", {} },     .{ "now", {} },     .{ "of", {} },
    .{ "off", {} },     .{ "on", {} },      .{ "once", {} },    .{ "only", {} },
    .{ "or", {} },      .{ "other", {} },   .{ "our", {} },     .{ "out", {} },
    .{ "over", {} },    .{ "own", {} },     .{ "s", {} },       .{ "same", {} },
    .{ "shall", {} },   .{ "she", {} },     .{ "should", {} },  .{ "so", {} },
    .{ "some", {} },    .{ "such", {} },    .{ "t", {} },       .{ "than", {} },
    .{ "that", {} },    .{ "the", {} },     .{ "their", {} },   .{ "them", {} },
    .{ "then", {} },    .{ "there", {} },   .{ "these", {} },   .{ "they", {} },
    .{ "this", {} },    .{ "those", {} },   .{ "through", {} }, .{ "to", {} },
    .{ "too", {} },     .{ "under", {} },   .{ "until", {} },   .{ "up", {} },
    .{ "us", {} },      .{ "very", {} },    .{ "was", {} },     .{ "we", {} },
    .{ "were", {} },    .{ "what", {} },    .{ "when", {} },    .{ "where", {} },
    .{ "which", {} },   .{ "while", {} },   .{ "who", {} },     .{ "whom", {} },
    .{ "why", {} },     .{ "will", {} },    .{ "with", {} },    .{ "would", {} },
    .{ "you", {} },     .{ "your", {} },
});

fn isStopWord(word: []const u8) bool {
    return stop_word_map.has(word);
}

// ============================================================================
// Stage Implementations — Text Analysis
// ============================================================================

/// Language detection via Unicode script analysis.
fn stageLanguageDetect(b: *capnp.Builder, text: []const u8) void {
    var latin: u64 = 0;
    var cjk: u64 = 0;
    var cyrillic: u64 = 0;
    var arabic: u64 = 0;
    var devanagari: u64 = 0;
    var total: u64 = 0;

    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte < 0x80) {
            if (std.ascii.isAlphabetic(byte)) {
                latin += 1;
                total += 1;
            }
            i += 1;
        } else if (byte >= 0xC0 and byte < 0xE0 and i + 1 < text.len) {
            if (byte >= 0xD0 and byte <= 0xD3) cyrillic += 1
            else if (byte >= 0xD8 and byte <= 0xDB) arabic += 1
            else latin += 1;
            total += 1;
            i += 2;
        } else if (byte >= 0xE0 and byte < 0xF0 and i + 2 < text.len) {
            if (byte == 0xE0 and text[i + 1] >= 0xA4 and text[i + 1] <= 0xA7) devanagari += 1
            else if (byte >= 0xE4 and byte <= 0xE9) cjk += 1
            else total += 1;
            total += 1;
            i += 3;
        } else if (byte >= 0xF0 and i + 3 < text.len) {
            total += 1;
            i += 4;
        } else {
            i += 1;
        }
    }

    const max_count = @max(latin, @max(cjk, @max(cyrillic, @max(arabic, devanagari))));
    const script: []const u8 = if (max_count == 0) "Unknown"
        else if (max_count == cjk) "CJK"
        else if (max_count == cyrillic) "Cyrillic"
        else if (max_count == arabic) "Arabic"
        else if (max_count == devanagari) "Devanagari"
        else "Latin";

    const language: []const u8 = if (max_count == 0) "und"
        else if (max_count == cjk) "zh"
        else if (max_count == cyrillic) "ru"
        else if (max_count == arabic) "ar"
        else if (max_count == devanagari) "hi"
        else "en";

    const conf: f64 = if (total > 0) @as(f64, @floatFromInt(max_count)) / @as(f64, @floatFromInt(total)) else 0.0;

    b.setText(capnp.PTR_LANG_SCRIPT, script);
    b.setText(capnp.PTR_LANG_LANGUAGE, language);
    b.setF64(capnp.OFF_LANG_CONFIDENCE, conf);
}

/// Flesch-Kincaid readability scoring.
fn stageReadability(b: *capnp.Builder, text: []const u8) void {
    var sentences: u64 = 0;
    var words: u64 = 0;
    var syllables: u64 = 0;
    var in_word = false;
    var vowel_prev = false;

    for (text) |ch| {
        const lower = std.ascii.toLower(ch);

        if (ch == '.' or ch == '?' or ch == '!') {
            sentences += 1;
        }

        if (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t' or ch == '.' or ch == ',' or ch == ';' or ch == ':') {
            if (in_word) {
                words += 1;
                if (syllables == 0) syllables = 1;
                vowel_prev = false;
            }
            in_word = false;
        } else if (std.ascii.isAlphabetic(ch)) {
            in_word = true;
            const is_vowel = (lower == 'a' or lower == 'e' or lower == 'i' or lower == 'o' or lower == 'u' or lower == 'y');
            if (is_vowel and !vowel_prev) {
                syllables += 1;
            }
            vowel_prev = is_vowel;
        }
    }
    if (in_word) words += 1;
    if (sentences == 0) sentences = 1;
    if (words == 0) words = 1;
    if (syllables == 0) syllables = words;

    const w_f: f64 = @floatFromInt(words);
    const s_f: f64 = @floatFromInt(sentences);
    const sy_f: f64 = @floatFromInt(syllables);

    const fk_grade = 0.39 * (w_f / s_f) + 11.8 * (sy_f / w_f) - 15.59;
    const fk_ease = 206.835 - 1.015 * (w_f / s_f) - 84.6 * (sy_f / w_f);

    b.setF64(capnp.OFF_READ_GRADE, fk_grade);
    b.setF64(capnp.OFF_READ_EASE, fk_ease);
    b.setU64(capnp.OFF_READ_SENTENCES, sentences);
    b.setU64(capnp.OFF_READ_WORDS, words);
    b.setU64(capnp.OFF_READ_SYLLABLES, syllables);
}

/// Keyword extraction via word frequency analysis.
fn stageKeywords(b: *capnp.Builder, text: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var counts = std.StringHashMap(u32).init(alloc);

    var lower_buf: [128]u8 = undefined;
    var pos: usize = 0;
    while (pos < text.len) {
        while (pos < text.len and !std.ascii.isAlphabetic(text[pos])) : (pos += 1) {}
        if (pos >= text.len) break;

        const start = pos;
        while (pos < text.len and std.ascii.isAlphabetic(text[pos])) : (pos += 1) {}
        const word = text[start..pos];

        if (word.len < 3 or word.len > 127) continue;

        for (word, 0..) |ch, idx| {
            lower_buf[idx] = std.ascii.toLower(ch);
        }
        const lower = lower_buf[0..word.len];

        if (isStopWord(lower)) continue;

        if (counts.getPtr(lower)) |val| {
            val.* += 1;
        } else {
            const owned = alloc.dupe(u8, lower) catch continue;
            counts.put(owned, 1) catch continue;
        }
    }

    // Find top 20 by frequency using insertion sort
    const MAX_KW: usize = 20;
    const Entry = struct { word: []const u8, count: u32 };
    var top: [MAX_KW]Entry = undefined;
    var top_count: usize = 0;

    var iter = counts.iterator();
    while (iter.next()) |kv| {
        const entry = Entry{ .word = kv.key_ptr.*, .count = kv.value_ptr.* };
        if (top_count < MAX_KW or entry.count > top[top_count - 1].count) {
            var insert_pos = top_count;
            if (insert_pos == MAX_KW) insert_pos -= 1 else top_count += 1;
            var j = insert_pos;
            while (j > 0 and top[j - 1].count < entry.count) : (j -= 1) {
                top[j] = top[j - 1];
            }
            top[j] = entry;
        }
    }

    b.setU32(capnp.OFF_KW_COUNT, @intCast(top_count));
    b.setU32(capnp.OFF_KW_UNIQUE, @intCast(counts.count()));

    // Collect keyword strings for the text list
    var kw_slices: [MAX_KW][]const u8 = undefined;
    for (0..top_count) |ki| {
        kw_slices[ki] = top[ki].word;
    }
    b.setTextList(capnp.PTR_KW_WORDS, kw_slices[0..top_count]);
}

/// Citation pattern extraction (DOI, ISBN, URL, year references).
fn stageCitationExtract(b: *capnp.Builder, text: []const u8) void {
    var doi_count: u32 = 0;
    var isbn_count: u32 = 0;
    var url_count: u32 = 0;
    var year_count: u32 = 0;
    var num_ref_count: u32 = 0;

    var i: usize = 0;
    while (i < text.len) {
        if (i + 7 < text.len and text[i] == '1' and text[i + 1] == '0' and text[i + 2] == '.') {
            var j = i + 3;
            var digits: u32 = 0;
            while (j < text.len and std.ascii.isDigit(text[j])) : (j += 1) { digits += 1; }
            if (digits >= 4 and j < text.len and text[j] == '/') {
                doi_count += 1;
                i = j + 1;
                continue;
            }
        }

        if (i + 4 < text.len) {
            const maybe_isbn = text[i..i + 4];
            if (std.ascii.eqlIgnoreCase(maybe_isbn, "isbn")) {
                isbn_count += 1;
                i += 4;
                continue;
            }
        }

        if (i + 7 < text.len) {
            if (std.mem.startsWith(u8, text[i..], "http://") or
                std.mem.startsWith(u8, text[i..], "https://")) {
                url_count += 1;
                while (i < text.len and text[i] != ' ' and text[i] != '\n') : (i += 1) {}
                continue;
            }
        }

        if (i + 5 < text.len and text[i] == '(') {
            if ((text[i + 1] == '1' and text[i + 2] == '9') or
                (text[i + 1] == '2' and text[i + 2] == '0'))
            {
                if (std.ascii.isDigit(text[i + 3]) and std.ascii.isDigit(text[i + 4]) and text[i + 5] == ')') {
                    year_count += 1;
                    i += 6;
                    continue;
                }
            }
        }

        if (i + 2 < text.len and text[i] == '[' and std.ascii.isDigit(text[i + 1])) {
            var j = i + 1;
            while (j < text.len and std.ascii.isDigit(text[j])) : (j += 1) {}
            if (j < text.len and text[j] == ']' and j - i - 1 <= 4) {
                num_ref_count += 1;
                i = j + 1;
                continue;
            }
        }

        i += 1;
    }

    b.setU32(capnp.OFF_CIT_TOTAL, doi_count + isbn_count + url_count + year_count + num_ref_count);
    b.setU32(capnp.OFF_CIT_DOI, doi_count);
    b.setU32(capnp.OFF_CIT_ISBN, isbn_count);
    b.setU32(capnp.OFF_CIT_URL, url_count);
    b.setU32(capnp.OFF_CIT_YEAR, year_count);
    b.setU32(capnp.OFF_CIT_NUMREF, num_ref_count);
}

// ============================================================================
// Stage Implementations — Image Analysis
// ============================================================================

/// OCR confidence (captured during base parse).
fn stageOcrConfidence(b: *capnp.Builder, confidence: i32) void {
    b.setI32(capnp.OFF_OCR_CONF, confidence);
}

/// Perceptual hash (average hash) via Leptonica.
fn stagePerceptualHash(b: *capnp.Builder, input_path: [*:0]const u8) void {
    const pix = c.pixRead(input_path);
    if (pix == null) return;
    defer c.pixDestroy(@constCast(&pix));

    const gray = c.pixConvertTo8(pix, 0);
    if (gray == null) return;
    defer c.pixDestroy(@constCast(&gray));

    const pw: u32 = @intCast(c.pixGetWidth(gray));
    const ph: u32 = @intCast(c.pixGetHeight(gray));
    if (pw < 8 or ph < 8) return;

    var values: [64]f64 = undefined;
    var total: f64 = 0.0;
    for (0..8) |row| {
        for (0..8) |col| {
            const x: c_int = @intCast(@as(u32, @intCast(col)) * pw / 8 + pw / 16);
            const y: c_int = @intCast(@as(u32, @intCast(row)) * ph / 8 + ph / 16);
            var pixel: c.l_uint32 = 0;
            _ = c.pixGetPixel(gray, x, y, &pixel);
            const val: f64 = @floatFromInt(pixel & 0xFF);
            values[row * 8 + col] = val;
            total += val;
        }
    }

    const mean = total / 64.0;
    var hash: u64 = 0;
    for (0..64) |idx| {
        if (values[idx] > mean) {
            hash |= @as(u64, 1) << @as(u6, @intCast(idx));
        }
    }

    var hex_buf: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (0..16) |hi| {
        const shift: u6 = @intCast((15 - hi) * 4);
        hex_buf[hi] = hex_chars[@as(usize, @intCast((hash >> shift) & 0xF))];
    }

    b.setText(capnp.PTR_PHASH_AHASH, &hex_buf);
}

// ============================================================================
// Stage Implementations — Document Structure
// ============================================================================

/// Table of Contents extraction via Poppler index API.
fn stageTocExtract(b: *capnp.Builder, input_path: [*:0]const u8) void {
    const path_slice = std.mem.span(input_path);
    const prefix = "file://";
    var uri_buf: [4096]u8 = undefined;
    if (prefix.len + path_slice.len >= 4096) return;
    @memcpy(uri_buf[0..prefix.len], prefix);
    @memcpy(uri_buf[prefix.len .. prefix.len + path_slice.len], path_slice);
    uri_buf[prefix.len + path_slice.len] = 0;

    var gerr: ?*c.GError = null;
    const doc = c.poppler_document_new_from_file(&uri_buf, null, &gerr);
    if (doc == null) {
        if (gerr) |e| c.g_error_free(e);
        return;
    }
    defer c.g_object_unref(doc);

    const iter_ptr = c.poppler_index_iter_new(doc);
    if (iter_ptr == null) return;
    defer c.poppler_index_iter_free(iter_ptr);

    // First pass: count entries (max 100)
    var entry_count: usize = 0;
    const max_entries: usize = 100;
    countTocEntries(iter_ptr, &entry_count, max_entries, 0);

    if (entry_count == 0) return;

    // Re-create iterator for second pass
    c.poppler_index_iter_free(iter_ptr);
    const iter2 = c.poppler_index_iter_new(doc);
    if (iter2 == null) return;
    defer c.poppler_index_iter_free(iter2);

    // Allocate composite list
    var list = b.allocCompositeList(capnp.PTR_TOC_ENTRIES, entry_count, capnp.TOC_DW, capnp.TOC_PW) orelse return;

    // Second pass: populate entries
    var idx: usize = 0;
    writeTocEntries(&list, iter2, &idx, entry_count, 0);
}

fn countTocEntries(iter_ptr: *c.PopplerIndexIter, count: *usize, max: usize, depth: u32) void {
    if (depth > 5) return;
    var running = true;
    while (running) {
        if (count.* >= max) return;
        const action = c.poppler_index_iter_get_action(iter_ptr);
        if (action != null) {
            defer c.poppler_action_free(action);
            if (action.*.any.title != null) count.* += 1;
        }
        const child = c.poppler_index_iter_get_child(iter_ptr);
        if (child != null) {
            countTocEntries(child, count, max, depth + 1);
            c.poppler_index_iter_free(child);
        }
        running = (c.poppler_index_iter_next(iter_ptr) != 0);
    }
}

fn writeTocEntries(list: *capnp.CompositeList, iter_ptr: *c.PopplerIndexIter, idx: *usize, max: usize, depth: u32) void {
    if (depth > 5) return;
    var running = true;
    while (running) {
        if (idx.* >= max) return;
        const action = c.poppler_index_iter_get_action(iter_ptr);
        if (action != null) {
            defer c.poppler_action_free(action);
            if (action.*.any.title) |title_ptr| {
                list.setElemText(idx.*, 0, std.mem.span(title_ptr));
                list.setElemU32(idx.*, capnp.TOC_OFF_DEPTH, depth);
                idx.* += 1;
            }
        }
        const child = c.poppler_index_iter_get_child(iter_ptr);
        if (child != null) {
            writeTocEntries(list, child, idx, max, depth + 1);
            c.poppler_index_iter_free(child);
        }
        running = (c.poppler_index_iter_next(iter_ptr) != 0);
    }
}

// ============================================================================
// Stage Implementations — Audio/Video
// ============================================================================

/// Subtitle stream information extraction via FFmpeg.
fn stageSubtitleExtract(b: *capnp.Builder, input_path: [*:0]const u8) void {
    var fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(&fmt_ctx, input_path, null, null) < 0) return;
    defer c.avformat_close_input(&fmt_ctx);

    if (c.avformat_find_stream_info(fmt_ctx, null) < 0) return;

    const ctx = fmt_ctx.?;

    // First pass: count subtitle streams
    var stream_count: usize = 0;
    for (0..ctx.nb_streams) |si| {
        const stream = ctx.streams[si];
        if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_SUBTITLE) {
            stream_count += 1;
        }
    }

    b.setU32(capnp.OFF_SUB_COUNT, @intCast(stream_count));
    if (stream_count == 0) return;

    var list = b.allocCompositeList(capnp.PTR_SUB_STREAMS, stream_count, capnp.SUB_DW, capnp.SUB_PW) orelse return;

    var elem_idx: usize = 0;
    for (0..ctx.nb_streams) |si| {
        const stream = ctx.streams[si];
        if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_SUBTITLE) {
            list.setElemU32(elem_idx, capnp.SUB_OFF_INDEX, @intCast(si));

            const codec = c.avcodec_find_decoder(stream.*.codecpar.*.codec_id);
            if (codec != null and codec.*.name != null) {
                list.setElemText(elem_idx, 0, std.mem.span(codec.*.name));
            }

            if (stream.*.metadata) |metadata| {
                const tag = c.av_dict_get(metadata, "language", null, 0);
                if (tag != null) {
                    if (tag.*.value) |v| {
                        list.setElemText(elem_idx, 1, std.mem.span(v));
                    }
                }
            }

            elem_idx += 1;
        }
    }
}

// ============================================================================
// Stage Implementations — Preservation / Integrity
// ============================================================================

/// PREMIS preservation metadata generation.
fn stagePremisMetadata(b: *capnp.Builder, ctx: *const StageContext) void {
    const path_slice = std.mem.span(ctx.input_path);
    const file_size: i64 = blk: {
        const f = std.fs.openFileAbsolute(path_slice, .{}) catch break :blk 0;
        defer f.close();
        const stat = f.stat() catch break :blk 0;
        break :blk @intCast(stat.size);
    };

    b.setText(capnp.PTR_PREMIS_CAT, "file");
    b.setText(capnp.PTR_PREMIS_FMT, std.mem.sliceTo(ctx.mime_type, 0));
    b.setI64(capnp.OFF_PREMIS_SIZE, file_size);
    b.setText(capnp.PTR_PREMIS_FIXALG, "SHA-256");
    b.setText(capnp.PTR_PREMIS_FIXVAL, std.mem.sliceTo(ctx.sha256, 0));
    b.setText(capnp.PTR_PREMIS_FMTREG, "PRONOM");
}

/// Streaming Merkle tree — O(log n) memory instead of O(n).
///
/// Maintains a stack of partial hashes at each tree level. When two hashes
/// accumulate at a given level, they're combined and pushed up. This processes
/// arbitrarily large files with only ~32 * max_depth bytes of state.
const MerkleStack = struct {
    /// Stack of partial hashes at each tree depth.
    /// Index 0 = leaf level, index 1 = first interior level, etc.
    /// A slot is "occupied" when its flag is set.
    hashes: [MAX_DEPTH][32]u8,
    occupied: [MAX_DEPTH]bool,
    leaf_count: u32,

    const MAX_DEPTH: usize = 32; // supports up to 2^32 leaves (~17 TB at 4KB chunks)

    fn init() MerkleStack {
        return .{
            .hashes = undefined,
            .occupied = [_]bool{false} ** MAX_DEPTH,
            .leaf_count = 0,
        };
    }

    /// Push a leaf hash into the streaming tree.
    fn pushLeaf(self: *MerkleStack, leaf: [32]u8) void {
        self.leaf_count += 1;
        self.pushAt(0, leaf);
    }

    fn pushAt(self: *MerkleStack, level: usize, hash: [32]u8) void {
        if (level >= MAX_DEPTH) return;
        if (self.occupied[level]) {
            // Combine with existing hash at this level and push up
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(&self.hashes[level]);
            hasher.update(&hash);
            self.occupied[level] = false;
            self.pushAt(level + 1, hasher.finalResult());
        } else {
            self.hashes[level] = hash;
            self.occupied[level] = true;
        }
    }

    /// Finalize the tree — combine all remaining partial hashes bottom-up.
    /// Returns the root hash and tree depth.
    fn finalize(self: *MerkleStack) struct { root: [32]u8, depth: u32 } {
        var found_first = false;
        var current: [32]u8 = undefined;
        var depth: u32 = 0;

        for (0..MAX_DEPTH) |level| {
            if (self.occupied[level]) {
                if (!found_first) {
                    current = self.hashes[level];
                    found_first = true;
                    depth = @intCast(level);
                } else {
                    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
                    hasher.update(&self.hashes[level]);
                    hasher.update(&current);
                    current = hasher.finalResult();
                    depth = @intCast(level + 1);
                }
            }
        }

        return .{ .root = current, .depth = depth };
    }
};

/// Merkle proof — SHA-256 hash tree over extracted content chunks.
/// Uses streaming computation: O(log n) memory instead of O(n).
fn stageMerkleProof(b: *capnp.Builder, output_path: [*:0]const u8) void {
    const file = std.fs.openFileAbsoluteZ(output_path, .{}) catch return;
    defer file.close();

    var tree = MerkleStack.init();
    var chunk_buf: [4096]u8 = undefined;

    while (true) {
        const n = file.read(&chunk_buf) catch break;
        if (n == 0) break;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(chunk_buf[0..n]);
        tree.pushLeaf(hasher.finalResult());
    }

    if (tree.leaf_count == 0) {
        b.setText(capnp.PTR_MERKLE_ROOT, "0000000000000000000000000000000000000000000000000000000000000000");
        b.setU32(capnp.OFF_MERKLE_DEPTH, 0);
        b.setU32(capnp.OFF_MERKLE_LEAVES, 0);
        return;
    }

    const result = tree.finalize();

    const hex_chars = "0123456789abcdef";
    var root_hex: [64]u8 = undefined;
    for (result.root, 0..) |byte_val, bi| {
        root_hex[bi * 2] = hex_chars[byte_val >> 4];
        root_hex[bi * 2 + 1] = hex_chars[byte_val & 0x0f];
    }

    b.setText(capnp.PTR_MERKLE_ROOT, &root_hex);
    b.setU32(capnp.OFF_MERKLE_DEPTH, result.depth);
    b.setU32(capnp.OFF_MERKLE_LEAVES, tree.leaf_count);
}

/// Exact dedup support — SHA-256 for cross-document comparison.
fn stageExactDedup(b: *capnp.Builder, sha256: *const [65]u8) void {
    b.setText(capnp.PTR_EXACT_SHA, std.mem.sliceTo(sha256, 0));
}

/// Near dedup support — perceptual hash for image comparison.
fn stageNearDedup(b: *capnp.Builder, input_path: [*:0]const u8, content_kind: c_int) void {
    if (content_kind != CK_IMAGE) {
        b.setText(capnp.PTR_NEAR_STATUS, "not_applicable");
        b.setText(capnp.PTR_NEAR_REASON, "not an image");
        return;
    }

    const pix = c.pixRead(input_path);
    if (pix == null) return;
    defer c.pixDestroy(@constCast(&pix));

    const gray = c.pixConvertTo8(pix, 0);
    if (gray == null) return;
    defer c.pixDestroy(@constCast(&gray));

    const pw: u32 = @intCast(c.pixGetWidth(gray));
    const ph: u32 = @intCast(c.pixGetHeight(gray));
    if (pw < 8 or ph < 8) return;

    var values: [64]f64 = undefined;
    var total: f64 = 0.0;
    for (0..8) |row| {
        for (0..8) |col| {
            const x: c_int = @intCast(@as(u32, @intCast(col)) * pw / 8 + pw / 16);
            const y: c_int = @intCast(@as(u32, @intCast(row)) * ph / 8 + ph / 16);
            var pixel: c.l_uint32 = 0;
            _ = c.pixGetPixel(gray, x, y, &pixel);
            const val: f64 = @floatFromInt(pixel & 0xFF);
            values[row * 8 + col] = val;
            total += val;
        }
    }

    const mean_val = total / 64.0;
    var hash: u64 = 0;
    for (0..64) |idx| {
        if (values[idx] > mean_val) hash |= @as(u64, 1) << @as(u6, @intCast(idx));
    }

    var hex_buf: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (0..16) |hi| {
        const shift: u6 = @intCast((15 - hi) * 4);
        hex_buf[hi] = hex_chars[@as(usize, @intCast((hash >> shift) & 0xF))];
    }
    b.setText(capnp.PTR_NEAR_AHASH, &hex_buf);
}

/// Coordinate normalization — CRS and bounding box from GDAL.
fn stageCoordNormalize(b: *capnp.Builder, input_path: [*:0]const u8) void {
    const dataset = c.GDALOpen(input_path, c.GA_ReadOnly);
    if (dataset == null) return;
    defer _ = c.GDALClose(dataset);

    const proj = c.GDALGetProjectionRef(dataset);
    const proj_str = if (proj) |p| std.mem.span(p) else "";

    var gt: [6]f64 = undefined;
    _ = c.GDALGetGeoTransform(dataset, &gt);

    const x_size: f64 = @floatFromInt(c.GDALGetRasterXSize(dataset));
    const y_size: f64 = @floatFromInt(c.GDALGetRasterYSize(dataset));

    const min_x = gt[0];
    const max_x = gt[0] + gt[1] * x_size;
    const max_y = gt[3];
    const min_y = gt[3] + gt[5] * y_size;

    const crs_display = if (proj_str.len > 200) proj_str[0..200] else proj_str;
    b.setText(capnp.PTR_COORD_CRS, crs_display);
    b.setF64(capnp.OFF_COORD_MINX, min_x);
    b.setF64(capnp.OFF_COORD_MINY, min_y);
    b.setF64(capnp.OFF_COORD_MAXX, max_x);
    b.setF64(capnp.OFF_COORD_MAXY, max_y);
    b.setF64(capnp.OFF_COORD_RASTX, x_size);
    b.setF64(capnp.OFF_COORD_RASTY, y_size);
}

// ============================================================================
// Stage Implementations — ML Stubs
// ============================================================================

fn writeStub(b: *capnp.Builder, status_ptr: usize, reason_ptr: usize, reason: []const u8) void {
    b.setText(status_ptr, "not_available");
    b.setText(reason_ptr, reason);
}

// ============================================================================
// Multi-Language OCR
// ============================================================================

fn stageMultiLangOcr(b: *capnp.Builder, input_path: [*:0]const u8) void {
    const tess = c.TessBaseAPICreate();
    if (tess == null) return;
    defer c.TessBaseAPIDelete(tess);

    if (c.TessBaseAPIInit3(tess, null, "eng+fra+deu+spa+ita+por") != 0) {
        if (c.TessBaseAPIInit3(tess, null, "eng") != 0) return;
    }

    const pix = c.pixRead(input_path);
    if (pix == null) return;
    defer c.pixDestroy(@constCast(&pix));

    c.TessBaseAPISetImage2(tess, pix);
    if (c.TessBaseAPIRecognize(tess, null) != 0) return;

    const conf = c.TessBaseAPIMeanTextConf(tess);
    const text_ptr = c.TessBaseAPIGetUTF8Text(tess);
    var word_count: u64 = 0;
    var char_count: u64 = 0;
    if (text_ptr != null) {
        const text = std.mem.span(text_ptr);
        char_count = text.len;
        var in_word = false;
        for (text) |ch| {
            if (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t') {
                if (in_word) { word_count += 1; in_word = false; }
            } else {
                in_word = true;
            }
        }
        if (in_word) word_count += 1;
        c.TessDeleteText(text_ptr);
    }

    b.setText(capnp.PTR_MLANG_LANGS, "eng+fra+deu+spa+ita+por");
    b.setI32(capnp.OFF_MLANG_CONF, @intCast(conf));
    b.setU64(capnp.OFF_MLANG_WORDS, word_count);
    b.setU64(capnp.OFF_MLANG_CHARS, char_count);
}

// ============================================================================
// Stage Runner — Main Entry Point
// ============================================================================

/// Run all enabled processing stages. Called from ddac_parse after base parse.
/// Writes results to {output_path}.stages.capnp in Cap'n Proto binary format.
pub fn runStages(ctx: StageContext) void {
    if (ctx.stages == STAGE_NONE) return;

    // Build stages output path: {output_path}.stages.capnp
    const path_slice = std.mem.span(ctx.output_path);
    const suffix = ".stages.capnp";
    var path_buf: [4096]u8 = undefined;
    if (path_slice.len + suffix.len >= 4096) return;
    @memcpy(path_buf[0..path_slice.len], path_slice);
    @memcpy(path_buf[path_slice.len .. path_slice.len + suffix.len], suffix);
    path_buf[path_slice.len + suffix.len] = 0;

    const stages_path: [*:0]u8 = @ptrCast(path_buf[0 .. path_slice.len + suffix.len :0]);
    const file = std.fs.createFileAbsoluteZ(stages_path, .{}) catch return;
    defer file.close();

    // Initialise Cap'n Proto builder (64 KB stack buffer)
    var buf: [65536]u8 align(8) = undefined;
    var b = capnp.Builder.init(&buf);
    b.initRoot();

    // Write the stages bitmask so readers know which fields are populated
    b.setU64(capnp.OFF_STAGES_MASK, ctx.stages);

    // ── Phase 1: Result-only stages (no extra I/O) ───────────────────

    if (ctx.stages & STAGE_PREMIS_METADATA != 0) {
        stagePremisMetadata(&b, &ctx);
    }

    if (ctx.stages & STAGE_EXACT_DEDUP != 0) {
        stageExactDedup(&b, ctx.sha256);
    }

    if (ctx.stages & STAGE_OCR_CONFIDENCE != 0 and ctx.content_kind == CK_IMAGE and ctx.ocr_confidence >= 0) {
        stageOcrConfidence(&b, ctx.ocr_confidence);
    }

    // ── Phase 2: Text-based stages (read extracted text) ─────────────

    const needs_text = (ctx.stages & (STAGE_LANGUAGE_DETECT | STAGE_READABILITY |
        STAGE_KEYWORDS | STAGE_CITATION_EXTRACT)) != 0;

    if (needs_text) {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();

        if (readExtractedText(ctx.output_path, arena.allocator())) |text| {
            if (ctx.stages & STAGE_LANGUAGE_DETECT != 0)
                stageLanguageDetect(&b, text);

            if (ctx.stages & STAGE_READABILITY != 0)
                stageReadability(&b, text);

            if (ctx.stages & STAGE_KEYWORDS != 0)
                stageKeywords(&b, text);

            if (ctx.stages & STAGE_CITATION_EXTRACT != 0)
                stageCitationExtract(&b, text);
        }
    }

    // ── Phase 3: Integrity stages (read output file) ─────────────────

    if (ctx.stages & STAGE_MERKLE_PROOF != 0) {
        stageMerkleProof(&b, ctx.output_path);
    }

    // ── Phase 4: PDF-specific stages ─────────────────────────────────

    if (ctx.stages & STAGE_TOC_EXTRACT != 0 and ctx.content_kind == CK_PDF) {
        stageTocExtract(&b, ctx.input_path);
    }

    // ── Phase 5: Image-specific stages ───────────────────────────────

    if (ctx.stages & STAGE_PERCEPTUAL_HASH != 0 and ctx.content_kind == CK_IMAGE) {
        stagePerceptualHash(&b, ctx.input_path);
    }

    if (ctx.stages & STAGE_NEAR_DEDUP != 0) {
        stageNearDedup(&b, ctx.input_path, ctx.content_kind);
    }

    if (ctx.stages & STAGE_MULTI_LANG_OCR != 0 and ctx.content_kind == CK_IMAGE) {
        stageMultiLangOcr(&b, ctx.input_path);
    }

    // ── Phase 6: AV-specific stages ──────────────────────────────────

    if (ctx.stages & STAGE_SUBTITLE_EXTRACT != 0 and
        (ctx.content_kind == CK_VIDEO or ctx.content_kind == CK_AUDIO))
    {
        stageSubtitleExtract(&b, ctx.input_path);
    }

    // ── Phase 7: Geospatial stages ───────────────────────────────────

    if (ctx.stages & STAGE_COORD_NORMALIZE != 0 and ctx.content_kind == CK_GEOSPATIAL) {
        stageCoordNormalize(&b, ctx.input_path);
    }

    // ── Phase 8: ML stub stages ──────────────────────────────────────

    if (ctx.stages & STAGE_NER != 0)
        writeStub(&b, capnp.PTR_NER_STATUS, capnp.PTR_NER_REASON, "Requires ML runtime (spaCy/HuggingFace). Install and rebuild with -DNER_ENABLED.");

    if (ctx.stages & STAGE_WHISPER_TRANSCRIBE != 0)
        writeStub(&b, capnp.PTR_WHISPER_STATUS, capnp.PTR_WHISPER_REASON, "Requires Whisper model and CUDA/Metal runtime.");

    if (ctx.stages & STAGE_IMAGE_CLASSIFY != 0)
        writeStub(&b, capnp.PTR_IMGCLASS_STATUS, capnp.PTR_IMGCLASS_REASON, "Requires image classification model (ResNet/ViT).");

    if (ctx.stages & STAGE_LAYOUT_ANALYSIS != 0)
        writeStub(&b, capnp.PTR_LAYOUT_STATUS, capnp.PTR_LAYOUT_REASON, "Requires document layout model (LayoutLM/DiT).");

    if (ctx.stages & STAGE_HANDWRITING_OCR != 0)
        writeStub(&b, capnp.PTR_HWOCR_STATUS, capnp.PTR_HWOCR_REASON, "Requires handwriting recognition model (TrOCR).");

    if (ctx.stages & STAGE_FORMAT_CONVERT != 0)
        writeStub(&b, capnp.PTR_FMTCONV_STATUS, capnp.PTR_FMTCONV_REASON, "Format conversion not yet implemented.");

    // ── Write Cap'n Proto message to file ─────────────────────────────

    b.writeMessage(file) catch {};
}
