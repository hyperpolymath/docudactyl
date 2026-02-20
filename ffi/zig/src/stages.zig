// Docudactyl Processing Stages — Configurable Analysis Pipeline
//
// Each stage is enabled via a bitmask flag passed to ddac_parse.
// Stage results are written to {output_path}.stages in JSON format.
// Stages run AFTER the base parse, extending per-document analysis.
//
// Stage tiers (approximate per-document throughput):
//   Lightning (>100 docs/s): PREMIS, exact_dedup, merkle_proof
//   Fast (10-50 docs/s):     language_detect, readability, keywords, citations, coord_normalize
//   Medium (0.2-5 docs/s):   ocr_confidence, perceptual_hash, toc_extract, subtitle_extract
//   Slow (minutes/doc):      multi_lang_ocr, whisper, handwriting_ocr (ML stubs)
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

const std = @import("std");

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
// JSON Writer Helper
// ============================================================================

const StagesWriter = struct {
    file: std.fs.File,
    first: bool,

    fn init(file: std.fs.File) StagesWriter {
        return .{ .file = file, .first = true };
    }

    fn begin(self: *StagesWriter) void {
        self.file.writeAll("{\"stages\":{") catch {};
    }

    fn end(self: *StagesWriter) void {
        self.file.writeAll("}}\n") catch {};
    }

    fn beginSection(self: *StagesWriter, name: []const u8) void {
        if (!self.first) self.file.writeAll(",") catch {};
        self.first = false;
        self.file.writeAll("\"") catch {};
        self.file.writeAll(name) catch {};
        self.file.writeAll("\":{") catch {};
    }

    fn endSection(self: *StagesWriter) void {
        self.file.writeAll("}") catch {};
    }

    /// Write a JSON string value, escaping special characters.
    fn writeJsonStr(self: *StagesWriter, s: []const u8) void {
        self.file.writeAll("\"") catch {};
        var start: usize = 0;
        for (s, 0..) |ch, i| {
            const esc: ?[]const u8 = switch (ch) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                else => null,
            };
            if (esc) |e| {
                if (i > start) self.file.writeAll(s[start..i]) catch {};
                self.file.writeAll(e) catch {};
                start = i + 1;
            }
        }
        if (start < s.len) self.file.writeAll(s[start..]) catch {};
        self.file.writeAll("\"") catch {};
    }

    /// Write raw pre-formatted content.
    fn raw(self: *StagesWriter, s: []const u8) void {
        self.file.writeAll(s) catch {};
    }
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

fn isStopWord(word: []const u8) bool {
    const stops = [_][]const u8{
        "a",     "about",   "after",  "all",    "also",   "am",     "an",
        "and",   "any",     "are",    "as",     "at",     "be",     "been",
        "before","being",   "between","both",   "but",    "by",     "can",
        "could", "did",     "do",     "does",   "doing",  "down",   "during",
        "each",  "few",     "for",    "from",   "further","get",    "got",
        "had",   "has",     "have",   "he",     "her",    "here",   "him",
        "his",   "how",     "i",      "if",     "in",     "into",   "is",
        "it",    "its",     "just",   "may",    "me",     "might",  "more",
        "most",  "must",    "my",     "no",     "nor",    "not",    "now",
        "of",    "off",     "on",     "once",   "only",   "or",     "other",
        "our",   "out",     "over",   "own",    "s",      "same",   "shall",
        "she",   "should",  "so",     "some",   "such",   "t",      "than",
        "that",  "the",     "their",  "them",   "then",   "there",  "these",
        "they",  "this",    "those",  "through","to",     "too",    "under",
        "until", "up",      "us",     "very",   "was",    "we",     "were",
        "what",  "when",    "where",  "which",  "while",  "who",    "whom",
        "why",   "will",    "with",   "would",  "you",    "your",
    };
    for (stops) |sw| {
        if (std.mem.eql(u8, word, sw)) return true;
    }
    return false;
}

// ============================================================================
// Stage Implementations — Text Analysis
// ============================================================================

/// Language detection via Unicode script analysis.
/// Counts byte patterns to identify dominant script/language.
fn stageLanguageDetect(w: *StagesWriter, text: []const u8) void {
    w.beginSection("language_detect");

    var latin: u64 = 0;
    var cjk: u64 = 0;
    var cyrillic: u64 = 0;
    var arabic: u64 = 0;
    var devanagari: u64 = 0;
    var total: u64 = 0;

    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b < 0x80) {
            // ASCII — count only alphabetic
            if (std.ascii.isAlphabetic(b)) {
                latin += 1;
                total += 1;
            }
            i += 1;
        } else if (b >= 0xC0 and b < 0xE0 and i + 1 < text.len) {
            // 2-byte UTF-8
            if (b >= 0xD0 and b <= 0xD3) cyrillic += 1 // U+0400-U+04FF
            else if (b >= 0xD8 and b <= 0xDB) arabic += 1 // U+0600-U+06FF
            else latin += 1; // Extended Latin and others
            total += 1;
            i += 2;
        } else if (b >= 0xE0 and b < 0xF0 and i + 2 < text.len) {
            // 3-byte UTF-8
            if (b == 0xE0 and text[i + 1] >= 0xA4 and text[i + 1] <= 0xA7) devanagari += 1 // U+0900-U+097F
            else if (b >= 0xE4 and b <= 0xE9) cjk += 1 // U+4000-U+9FFF (CJK Unified)
            else total += 1; // other scripts
            total += 1;
            i += 3;
        } else if (b >= 0xF0 and i + 3 < text.len) {
            total += 1;
            i += 4;
        } else {
            i += 1;
        }
    }

    // Determine dominant script
    const max_count = @max(latin, @max(cjk, @max(cyrillic, @max(arabic, devanagari))));
    const script: []const u8 = if (max_count == 0) "Unknown"
        else if (max_count == cjk) "CJK"
        else if (max_count == cyrillic) "Cyrillic"
        else if (max_count == arabic) "Arabic"
        else if (max_count == devanagari) "Devanagari"
        else "Latin";

    // Rough language guess from script
    const language: []const u8 = if (max_count == 0) "und"
        else if (max_count == cjk) "zh"
        else if (max_count == cyrillic) "ru"
        else if (max_count == arabic) "ar"
        else if (max_count == devanagari) "hi"
        else "en";

    const conf: f64 = if (total > 0) @as(f64, @floatFromInt(max_count)) / @as(f64, @floatFromInt(total)) else 0.0;

    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"script\":\"{s}\",\"language\":\"{s}\",\"confidence\":{d:.3}", .{
        script, language, conf,
    }) catch return;
    w.raw(s);
    w.endSection();
}

/// Flesch-Kincaid readability scoring.
fn stageReadability(w: *StagesWriter, text: []const u8) void {
    w.beginSection("readability");

    var sentences: u64 = 0;
    var words: u64 = 0;
    var syllables: u64 = 0;
    var in_word = false;
    var vowel_prev = false;

    for (text) |ch| {
        const lower = std.ascii.toLower(ch);

        // Sentence boundaries
        if (ch == '.' or ch == '?' or ch == '!') {
            sentences += 1;
        }

        // Word boundaries
        if (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t' or ch == '.' or ch == ',' or ch == ';' or ch == ':') {
            if (in_word) {
                words += 1;
                // End-of-word: add at least one syllable per word
                if (syllables == 0) syllables = 1;
                vowel_prev = false;
            }
            in_word = false;
        } else if (std.ascii.isAlphabetic(ch)) {
            in_word = true;
            // Syllable estimation: count vowel groups
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

    // Flesch-Kincaid Grade Level
    const fk_grade = 0.39 * (w_f / s_f) + 11.8 * (sy_f / w_f) - 15.59;
    // Flesch Reading Ease
    const fk_ease = 206.835 - 1.015 * (w_f / s_f) - 84.6 * (sy_f / w_f);

    var buf: [384]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "\"flesch_kincaid_grade\":{d:.1},\"flesch_reading_ease\":{d:.1},\"sentences\":{d},\"words\":{d},\"syllables\":{d}", .{
        fk_grade, fk_ease, sentences, words, syllables,
    }) catch return;
    w.raw(out);
    w.endSection();
}

/// Keyword extraction via word frequency analysis.
fn stageKeywords(w: *StagesWriter, text: []const u8) void {
    w.beginSection("keywords");

    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Count word frequencies
    var counts = std.StringHashMap(u32).init(alloc);

    var lower_buf: [128]u8 = undefined;
    var pos: usize = 0;
    while (pos < text.len) {
        // Skip non-alpha
        while (pos < text.len and !std.ascii.isAlphabetic(text[pos])) : (pos += 1) {}
        if (pos >= text.len) break;

        const start = pos;
        while (pos < text.len and std.ascii.isAlphabetic(text[pos])) : (pos += 1) {}
        const word = text[start..pos];

        // Skip short words
        if (word.len < 3 or word.len > 127) continue;

        // Lowercase
        for (word, 0..) |ch, i| {
            lower_buf[i] = std.ascii.toLower(ch);
        }
        const lower = lower_buf[0..word.len];

        // Skip stop words
        if (isStopWord(lower)) continue;

        // Clone key for HashMap (arena-allocated, freed in bulk)
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
            // Shift down
            var i = insert_pos;
            while (i > 0 and top[i - 1].count < entry.count) : (i -= 1) {
                top[i] = top[i - 1];
            }
            top[i] = entry;
        }
    }

    // Write JSON
    var buf: [64]u8 = undefined;
    const cnt = std.fmt.bufPrint(&buf, "\"count\":{d},\"total_unique\":{d},\"words\":[", .{
        top_count, counts.count(),
    }) catch return;
    w.raw(cnt);

    for (top[0..top_count], 0..) |entry, i| {
        if (i > 0) w.raw(",");
        w.writeJsonStr(entry.word);
    }
    w.raw("]");
    w.endSection();
}

/// Citation pattern extraction (DOI, ISBN, URL, year references).
fn stageCitationExtract(w: *StagesWriter, text: []const u8) void {
    w.beginSection("citations");

    var doi_count: u32 = 0;
    var isbn_count: u32 = 0;
    var url_count: u32 = 0;
    var year_count: u32 = 0;
    var num_ref_count: u32 = 0;

    var i: usize = 0;
    while (i < text.len) {
        // DOI: "10." followed by 4+ digits, then "/"
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

        // ISBN: "ISBN" (case-insensitive) followed by optional colon/space then digits
        if (i + 4 < text.len) {
            const maybe_isbn = text[i..i + 4];
            if (std.ascii.eqlIgnoreCase(maybe_isbn, "isbn")) {
                isbn_count += 1;
                i += 4;
                continue;
            }
        }

        // URL: "http://" or "https://"
        if (i + 7 < text.len) {
            if (std.mem.startsWith(u8, text[i..], "http://") or
                std.mem.startsWith(u8, text[i..], "https://")) {
                url_count += 1;
                // Skip to whitespace
                while (i < text.len and text[i] != ' ' and text[i] != '\n') : (i += 1) {}
                continue;
            }
        }

        // Year reference: (19xx) or (20xx) where xx are digits
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

        // Numeric reference: [N] or [NN] or [NNN]
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

    const total = doi_count + isbn_count + url_count + year_count + num_ref_count;
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"total\":{d},\"doi\":{d},\"isbn\":{d},\"url\":{d},\"year_ref\":{d},\"numeric_ref\":{d}", .{
        total, doi_count, isbn_count, url_count, year_count, num_ref_count,
    }) catch return;
    w.raw(s);
    w.endSection();
}

// ============================================================================
// Stage Implementations — Image Analysis
// ============================================================================

/// OCR confidence (captured during base parse, just written here).
fn stageOcrConfidence(w: *StagesWriter, confidence: i32) void {
    w.beginSection("ocr_confidence");
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"mean_confidence\":{d}", .{confidence}) catch return;
    w.raw(s);
    w.endSection();
}

/// Perceptual hash (average hash) via Leptonica.
/// Re-reads the image, samples 8x8 blocks, thresholds against mean.
fn stagePerceptualHash(w: *StagesWriter, input_path: [*:0]const u8) void {
    w.beginSection("perceptual_hash");

    const pix = c.pixRead(input_path);
    if (pix == null) {
        w.raw("\"error\":\"cannot read image\"");
        w.endSection();
        return;
    }
    defer c.pixDestroy(@constCast(&pix));

    // Convert to 8-bit grayscale
    const gray = c.pixConvertTo8(pix, 0);
    if (gray == null) {
        w.raw("\"error\":\"grayscale conversion failed\"");
        w.endSection();
        return;
    }
    defer c.pixDestroy(@constCast(&gray));

    const pw: u32 = @intCast(c.pixGetWidth(gray));
    const ph: u32 = @intCast(c.pixGetHeight(gray));
    if (pw < 8 or ph < 8) {
        w.raw("\"error\":\"image too small for perceptual hash\"");
        w.endSection();
        return;
    }

    // Sample 8x8 grid, compute average pixel values
    var values: [64]f64 = undefined;
    var total: f64 = 0.0;
    for (0..8) |row| {
        for (0..8) |col| {
            // Center of each block
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

    // Format as 16-char hex string
    var hex_buf: [17]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (0..16) |hi| {
        const shift: u6 = @intCast((15 - hi) * 4);
        hex_buf[hi] = hex_chars[@as(usize, @intCast((hash >> shift) & 0xF))];
    }
    hex_buf[16] = 0;

    w.raw("\"ahash\":\"");
    w.raw(hex_buf[0..16]);
    w.raw("\"");
    w.endSection();
}

// ============================================================================
// Stage Implementations — Document Structure
// ============================================================================

/// Table of Contents extraction via Poppler index API.
fn stageTocExtract(w: *StagesWriter, input_path: [*:0]const u8) void {
    w.beginSection("toc");

    // Build file:// URI
    const path_slice = std.mem.span(input_path);
    const prefix = "file://";
    var uri_buf: [4096]u8 = undefined;
    if (prefix.len + path_slice.len >= 4096) {
        w.raw("\"error\":\"path too long\"");
        w.endSection();
        return;
    }
    @memcpy(uri_buf[0..prefix.len], prefix);
    @memcpy(uri_buf[prefix.len .. prefix.len + path_slice.len], path_slice);
    uri_buf[prefix.len + path_slice.len] = 0;

    var gerr: ?*c.GError = null;
    const doc = c.poppler_document_new_from_file(&uri_buf, null, &gerr);
    if (doc == null) {
        if (gerr) |e| c.g_error_free(e);
        w.raw("\"error\":\"cannot open PDF\"");
        w.endSection();
        return;
    }
    defer c.g_object_unref(doc);

    const iter_ptr = c.poppler_index_iter_new(doc);
    if (iter_ptr == null) {
        w.raw("\"entries\":[]");
        w.endSection();
        return;
    }
    defer c.poppler_index_iter_free(iter_ptr);

    // Walk the top-level index entries (max 100 to bound output size)
    w.raw("\"entries\":[");
    var count: u32 = 0;
    const max_entries: u32 = 100;

    walkTocEntries(w, iter_ptr, &count, max_entries, 0);

    w.raw("]");
    w.endSection();
}

/// Recursively walk Poppler index entries (depth-limited).
fn walkTocEntries(w: *StagesWriter, iter_ptr: *c.PopplerIndexIter, count: *u32, max: u32, depth: u32) void {
    if (depth > 5) return; // prevent deep recursion

    var running = true;
    while (running) {
        if (count.* >= max) return;

        const action = c.poppler_index_iter_get_action(iter_ptr);
        if (action != null) {
            defer c.poppler_action_free(action);

            // Get title from action
            if (action.*.any.title) |title_ptr| {
                if (count.* > 0) w.raw(",");
                w.raw("{\"title\":");
                w.writeJsonStr(std.mem.span(title_ptr));

                var buf: [32]u8 = undefined;
                const d = std.fmt.bufPrint(&buf, ",\"depth\":{d}", .{depth}) catch "";
                w.raw(d);
                w.raw("}");
                count.* += 1;
            }
        }

        // Recurse into children
        const child = c.poppler_index_iter_get_child(iter_ptr);
        if (child != null) {
            walkTocEntries(w, child, count, max, depth + 1);
            c.poppler_index_iter_free(child);
        }

        running = (c.poppler_index_iter_next(iter_ptr) != 0);
    }
}

// ============================================================================
// Stage Implementations — Audio/Video
// ============================================================================

/// Subtitle stream information extraction via FFmpeg.
fn stageSubtitleExtract(w: *StagesWriter, input_path: [*:0]const u8) void {
    w.beginSection("subtitles");

    var fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(&fmt_ctx, input_path, null, null) < 0) {
        w.raw("\"error\":\"cannot open media file\"");
        w.endSection();
        return;
    }
    defer c.avformat_close_input(&fmt_ctx);

    if (c.avformat_find_stream_info(fmt_ctx, null) < 0) {
        w.raw("\"error\":\"cannot read stream info\"");
        w.endSection();
        return;
    }

    const ctx = fmt_ctx.?;
    var stream_count: u32 = 0;
    w.raw("\"streams\":[");

    for (0..ctx.nb_streams) |i| {
        const stream = ctx.streams[i];
        if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_SUBTITLE) {
            if (stream_count > 0) w.raw(",");

            w.raw("{\"index\":");
            var idx_buf: [16]u8 = undefined;
            const idx_s = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch "";
            w.raw(idx_s);

            // Codec name
            const codec = c.avcodec_find_decoder(stream.*.codecpar.*.codec_id);
            if (codec != null and codec.*.name != null) {
                w.raw(",\"codec\":");
                w.writeJsonStr(std.mem.span(codec.*.name));
            }

            // Language tag from metadata
            if (stream.*.metadata) |metadata| {
                const tag = c.av_dict_get(metadata, "language", null, 0);
                if (tag != null) {
                    if (tag.*.value) |v| {
                        w.raw(",\"language\":");
                        w.writeJsonStr(std.mem.span(v));
                    }
                }
            }

            w.raw("}");
            stream_count += 1;
        }
    }

    w.raw("]");
    var cnt_buf: [32]u8 = undefined;
    const cnt_s = std.fmt.bufPrint(&cnt_buf, ",\"stream_count\":{d}", .{stream_count}) catch "";
    w.raw(cnt_s);
    w.endSection();
}

// ============================================================================
// Stage Implementations — Preservation / Integrity
// ============================================================================

/// PREMIS preservation metadata generation.
fn stagePremisMetadata(w: *StagesWriter, ctx: *const StageContext) void {
    w.beginSection("premis");

    // File size
    const path_slice = std.mem.span(ctx.input_path);
    const file_size: i64 = blk: {
        const f = std.fs.openFileAbsolute(path_slice, .{}) catch break :blk 0;
        defer f.close();
        const stat = f.stat() catch break :blk 0;
        break :blk @intCast(stat.size);
    };

    w.raw("\"object_category\":\"file\"");

    w.raw(",\"format\":");
    w.writeJsonStr(std.mem.sliceTo(ctx.mime_type, 0));

    var buf: [128]u8 = undefined;
    const sz = std.fmt.bufPrint(&buf, ",\"size\":{d}", .{file_size}) catch "";
    w.raw(sz);

    w.raw(",\"fixity\":{\"algorithm\":\"SHA-256\",\"value\":");
    w.writeJsonStr(std.mem.sliceTo(ctx.sha256, 0));
    w.raw("}");

    w.raw(",\"format_registry\":\"PRONOM\"");
    w.endSection();
}

/// Merkle proof — SHA-256 hash tree over extracted content chunks.
fn stageMerkleProof(w: *StagesWriter, output_path: [*:0]const u8) void {
    w.beginSection("merkle_proof");

    const file = std.fs.openFileAbsoluteZ(output_path, .{}) catch {
        w.raw("\"error\":\"cannot read output file\"");
        w.endSection();
        return;
    };
    defer file.close();

    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Hash 4KB chunks
    var leaf_hashes = std.ArrayList([32]u8).init(alloc);
    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&chunk_buf) catch break;
        if (n == 0) break;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(chunk_buf[0..n]);
        leaf_hashes.append(hasher.finalResult()) catch break;
    }

    if (leaf_hashes.items.len == 0) {
        w.raw("\"root\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"depth\":0,\"leaf_count\":0");
        w.endSection();
        return;
    }

    // Build Merkle tree bottom-up
    var current = leaf_hashes.items;
    var depth: u32 = 0;
    while (current.len > 1) {
        var next = std.ArrayList([32]u8).init(alloc);
        var i: usize = 0;
        while (i < current.len) : (i += 2) {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(&current[i]);
            if (i + 1 < current.len) {
                hasher.update(&current[i + 1]);
            } else {
                hasher.update(&current[i]); // duplicate last if odd
            }
            next.append(hasher.finalResult()) catch break;
        }
        current = next.items;
        depth += 1;
    }

    // Format root hash as hex
    const hex_chars = "0123456789abcdef";
    var root_hex: [64]u8 = undefined;
    for (current[0], 0..) |byte, bi| {
        root_hex[bi * 2] = hex_chars[byte >> 4];
        root_hex[bi * 2 + 1] = hex_chars[byte & 0x0f];
    }

    w.raw("\"root\":\"");
    w.raw(&root_hex);
    w.raw("\"");

    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, ",\"depth\":{d},\"leaf_count\":{d}", .{
        depth, leaf_hashes.items.len,
    }) catch "";
    w.raw(s);
    w.endSection();
}

/// Exact dedup support — output SHA-256 for cross-document comparison by Chapel.
fn stageExactDedup(w: *StagesWriter, sha256: *const [65]u8) void {
    w.beginSection("exact_dedup");
    w.raw("\"sha256\":");
    w.writeJsonStr(std.mem.sliceTo(sha256, 0));
    w.endSection();
}

/// Near dedup support — output perceptual hash for Chapel comparison.
/// Writes the same ahash computed by STAGE_PERCEPTUAL_HASH if run,
/// or computes independently if perceptual_hash was not enabled.
fn stageNearDedup(w: *StagesWriter, input_path: [*:0]const u8, content_kind: c_int) void {
    w.beginSection("near_dedup");

    if (content_kind != CK_IMAGE) {
        w.raw("\"status\":\"not_applicable\",\"reason\":\"not an image\"");
        w.endSection();
        return;
    }

    // Compute perceptual hash (same as stagePerceptualHash)
    const pix = c.pixRead(input_path);
    if (pix == null) {
        w.raw("\"error\":\"cannot read image\"");
        w.endSection();
        return;
    }
    defer c.pixDestroy(@constCast(&pix));

    const gray = c.pixConvertTo8(pix, 0);
    if (gray == null) {
        w.raw("\"error\":\"grayscale conversion failed\"");
        w.endSection();
        return;
    }
    defer c.pixDestroy(@constCast(&gray));

    const pw: u32 = @intCast(c.pixGetWidth(gray));
    const ph: u32 = @intCast(c.pixGetHeight(gray));
    if (pw < 8 or ph < 8) {
        w.raw("\"error\":\"image too small\"");
        w.endSection();
        return;
    }

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
        if (values[idx] > mean) hash |= @as(u64, 1) << @as(u6, @intCast(idx));
    }

    var hex_buf: [17]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (0..16) |hi| {
        const shift: u6 = @intCast((15 - hi) * 4);
        hex_buf[hi] = hex_chars[@as(usize, @intCast((hash >> shift) & 0xF))];
    }
    w.raw("\"ahash\":\"");
    w.raw(hex_buf[0..16]);
    w.raw("\"");
    w.endSection();
}

/// Coordinate normalization — report CRS and bounding box from GDAL.
fn stageCoordNormalize(w: *StagesWriter, input_path: [*:0]const u8) void {
    w.beginSection("coordinates");

    const dataset = c.GDALOpen(input_path, c.GA_ReadOnly);
    if (dataset == null) {
        w.raw("\"error\":\"cannot open geospatial file\"");
        w.endSection();
        return;
    }
    defer _ = c.GDALClose(dataset);

    // Get CRS
    const proj = c.GDALGetProjectionRef(dataset);
    const proj_str = if (proj) |p| std.mem.span(p) else "";

    // Get geotransform
    var gt: [6]f64 = undefined;
    _ = c.GDALGetGeoTransform(dataset, &gt);

    const x_size: f64 = @floatFromInt(c.GDALGetRasterXSize(dataset));
    const y_size: f64 = @floatFromInt(c.GDALGetRasterYSize(dataset));

    // Compute bounding box in native CRS
    const min_x = gt[0];
    const max_x = gt[0] + gt[1] * x_size;
    const max_y = gt[3];
    const min_y = gt[3] + gt[5] * y_size;

    w.raw("\"crs\":");
    // Truncate CRS string if very long (WKT can be huge)
    const crs_display = if (proj_str.len > 200) proj_str[0..200] else proj_str;
    w.writeJsonStr(crs_display);

    var buf: [384]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, ",\"bounds\":{{\"min_x\":{d:.6},\"min_y\":{d:.6},\"max_x\":{d:.6},\"max_y\":{d:.6}}}", .{
        min_x, min_y, max_x, max_y,
    }) catch "";
    w.raw(s);

    var sz_buf: [64]u8 = undefined;
    const sz = std.fmt.bufPrint(&sz_buf, ",\"raster_x\":{d:.0},\"raster_y\":{d:.0}", .{ x_size, y_size }) catch "";
    w.raw(sz);
    w.endSection();
}

// ============================================================================
// Stage Implementations — ML Stubs
// ============================================================================

/// Write a stub stage that requires an ML runtime not yet available.
fn writeStub(w: *StagesWriter, name: []const u8, reason: []const u8) void {
    w.beginSection(name);
    w.raw("\"status\":\"not_available\",\"reason\":");
    w.writeJsonStr(reason);
    w.endSection();
}

// ============================================================================
// Multi-Language OCR
// ============================================================================

/// Re-run OCR with a multi-language Tesseract configuration.
/// Creates a temporary TessBaseAPI with "eng+fra+deu+spa+ita+por".
fn stageMultiLangOcr(w: *StagesWriter, input_path: [*:0]const u8) void {
    w.beginSection("multi_lang_ocr");

    const tess = c.TessBaseAPICreate();
    if (tess == null) {
        w.raw("\"error\":\"cannot create Tesseract instance\"");
        w.endSection();
        return;
    }
    defer c.TessBaseAPIDelete(tess);

    // Initialise with multiple languages (common European set)
    if (c.TessBaseAPIInit3(tess, null, "eng+fra+deu+spa+ita+por") != 0) {
        // Fallback: try English only if multi-lang models not installed
        if (c.TessBaseAPIInit3(tess, null, "eng") != 0) {
            w.raw("\"error\":\"Tesseract init failed\"");
            w.endSection();
            return;
        }
    }

    const pix = c.pixRead(input_path);
    if (pix == null) {
        w.raw("\"error\":\"cannot read image\"");
        w.endSection();
        return;
    }
    defer c.pixDestroy(@constCast(&pix));

    c.TessBaseAPISetImage2(tess, pix);
    if (c.TessBaseAPIRecognize(tess, null) != 0) {
        w.raw("\"error\":\"recognition failed\"");
        w.endSection();
        return;
    }

    const conf = c.TessBaseAPIMeanTextConf(tess);
    const text_ptr = c.TessBaseAPIGetUTF8Text(tess);
    var word_count: u64 = 0;
    var char_count: u64 = 0;
    if (text_ptr != null) {
        const text = std.mem.span(text_ptr);
        char_count = text.len;
        // Count words
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

    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"languages\":\"eng+fra+deu+spa+ita+por\",\"confidence\":{d},\"words\":{d},\"chars\":{d}", .{
        conf, word_count, char_count,
    }) catch return;
    w.raw(s);
    w.endSection();
}

// ============================================================================
// Stage Runner — Main Entry Point
// ============================================================================

/// Run all enabled processing stages. Called from ddac_parse after base parse.
/// Writes results to {output_path}.stages in JSON format.
pub fn runStages(ctx: StageContext) void {
    if (ctx.stages == STAGE_NONE) return;

    // Build stages output path: {output_path}.stages
    const path_slice = std.mem.span(ctx.output_path);
    const suffix = ".stages";
    var path_buf: [4096]u8 = undefined;
    if (path_slice.len + suffix.len >= 4096) return;
    @memcpy(path_buf[0..path_slice.len], path_slice);
    @memcpy(path_buf[path_slice.len .. path_slice.len + suffix.len], suffix);
    path_buf[path_slice.len + suffix.len] = 0;

    const stages_path: [*:0]u8 = @ptrCast(path_buf[0 .. path_slice.len + suffix.len :0]);
    const file = std.fs.createFileAbsoluteZ(stages_path, .{}) catch return;
    defer file.close();

    var w = StagesWriter.init(file);
    w.begin();

    // ── Phase 1: Result-only stages (no extra I/O) ───────────────────

    if (ctx.stages & STAGE_PREMIS_METADATA != 0) {
        stagePremisMetadata(&w, &ctx);
    }

    if (ctx.stages & STAGE_EXACT_DEDUP != 0) {
        stageExactDedup(&w, ctx.sha256);
    }

    if (ctx.stages & STAGE_OCR_CONFIDENCE != 0 and ctx.content_kind == CK_IMAGE and ctx.ocr_confidence >= 0) {
        stageOcrConfidence(&w, ctx.ocr_confidence);
    }

    // ── Phase 2: Text-based stages (read extracted text) ─────────────

    const needs_text = (ctx.stages & (STAGE_LANGUAGE_DETECT | STAGE_READABILITY |
        STAGE_KEYWORDS | STAGE_CITATION_EXTRACT)) != 0;

    if (needs_text) {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();

        if (readExtractedText(ctx.output_path, arena.allocator())) |text| {
            if (ctx.stages & STAGE_LANGUAGE_DETECT != 0)
                stageLanguageDetect(&w, text);

            if (ctx.stages & STAGE_READABILITY != 0)
                stageReadability(&w, text);

            if (ctx.stages & STAGE_KEYWORDS != 0)
                stageKeywords(&w, text);

            if (ctx.stages & STAGE_CITATION_EXTRACT != 0)
                stageCitationExtract(&w, text);
        }
    }

    // ── Phase 3: Integrity stages (read output file) ─────────────────

    if (ctx.stages & STAGE_MERKLE_PROOF != 0) {
        stageMerkleProof(&w, ctx.output_path);
    }

    // ── Phase 4: PDF-specific stages ─────────────────────────────────

    if (ctx.stages & STAGE_TOC_EXTRACT != 0 and ctx.content_kind == CK_PDF) {
        stageTocExtract(&w, ctx.input_path);
    }

    // ── Phase 5: Image-specific stages ───────────────────────────────

    if (ctx.stages & STAGE_PERCEPTUAL_HASH != 0 and ctx.content_kind == CK_IMAGE) {
        stagePerceptualHash(&w, ctx.input_path);
    }

    if (ctx.stages & STAGE_NEAR_DEDUP != 0) {
        stageNearDedup(&w, ctx.input_path, ctx.content_kind);
    }

    if (ctx.stages & STAGE_MULTI_LANG_OCR != 0 and ctx.content_kind == CK_IMAGE) {
        stageMultiLangOcr(&w, ctx.input_path);
    }

    // ── Phase 6: AV-specific stages ──────────────────────────────────

    if (ctx.stages & STAGE_SUBTITLE_EXTRACT != 0 and
        (ctx.content_kind == CK_VIDEO or ctx.content_kind == CK_AUDIO))
    {
        stageSubtitleExtract(&w, ctx.input_path);
    }

    // ── Phase 7: Geospatial stages ───────────────────────────────────

    if (ctx.stages & STAGE_COORD_NORMALIZE != 0 and ctx.content_kind == CK_GEOSPATIAL) {
        stageCoordNormalize(&w, ctx.input_path);
    }

    // ── Phase 8: ML stub stages ──────────────────────────────────────

    if (ctx.stages & STAGE_NER != 0)
        writeStub(&w, "ner", "Requires ML runtime (spaCy/HuggingFace). Install and rebuild with -DNER_ENABLED.");

    if (ctx.stages & STAGE_WHISPER_TRANSCRIBE != 0)
        writeStub(&w, "whisper_transcribe", "Requires Whisper model and CUDA/Metal runtime.");

    if (ctx.stages & STAGE_IMAGE_CLASSIFY != 0)
        writeStub(&w, "image_classify", "Requires image classification model (ResNet/ViT).");

    if (ctx.stages & STAGE_LAYOUT_ANALYSIS != 0)
        writeStub(&w, "layout_analysis", "Requires document layout model (LayoutLM/DiT).");

    if (ctx.stages & STAGE_HANDWRITING_OCR != 0)
        writeStub(&w, "handwriting_ocr", "Requires handwriting recognition model (TrOCR).");

    if (ctx.stages & STAGE_FORMAT_CONVERT != 0)
        writeStub(&w, "format_convert", "Format conversion not yet implemented.");

    w.end();
}
