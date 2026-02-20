// Docudactyl FFI — Unified Multi-Format Parser Dispatcher
//
// Thin Zig wrapper around C libraries for HPC document processing.
// Chapel calls these functions via C FFI. Each parser writes extracted
// content to an output file; the result struct is a summary.
//
// Linked C libraries:
//   - libpoppler-glib  (PDF text/metadata extraction)
//   - libtesseract     (OCR for images)
//   - libavformat/libavcodec/libavutil (audio/video metadata)
//   - libxml2          (EPUB/XHTML parsing)
//   - libgdal          (geospatial: shapefiles, GeoTIFF)
//   - libvips          (image dimensions/metadata)
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

const std = @import("std");
const stages = @import("stages.zig");
const cache = @import("cache.zig");
const dragonfly = @import("dragonfly.zig");
const prefetch = @import("prefetch.zig");
const conduit = @import("conduit.zig");
const gpu_ocr = @import("gpu_ocr.zig");
const hw_crypto = @import("hw_crypto.zig");
const ml_inference = @import("ml_inference.zig");

// Ensure submodule exports are included in the shared library
comptime {
    _ = cache;
    _ = dragonfly;
    _ = prefetch;
    _ = conduit;
    _ = gpu_ocr;
    _ = hw_crypto;
    _ = ml_inference;
}

const c = @cImport({
    // Poppler (PDF)
    @cInclude("poppler/glib/poppler.h");
    // Tesseract (OCR) + Leptonica (image I/O)
    @cInclude("tesseract/capi.h");
    @cInclude("leptonica/allheaders.h");
    // FFmpeg (audio/video)
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/dict.h");
    // libxml2 (EPUB)
    @cInclude("libxml/parser.h");
    @cInclude("libxml/tree.h");
    @cInclude("libxml/xpath.h");
    // GDAL (geospatial)
    @cInclude("gdal.h");
    @cInclude("cpl_conv.h");
    // libvips (image metadata)
    @cInclude("vips/vips.h");
});

// ============================================================================
// Version & Compile-Time Dependency Checks
// ============================================================================

const VERSION = "0.1.0";
const BUILD_INFO = "docudactyl-ffi built with Zig " ++ @import("builtin").zig_version_string;

// Zig minimum version: 0.15.0 (Module-based build API)
comptime {
    const zig_ver = @import("builtin").zig_version;
    if (zig_ver.major == 0 and zig_ver.minor < 15) {
        @compileError("Docudactyl FFI requires Zig >= 0.15.0 (build API changed)");
    }
}

// Poppler: verify poppler_document_new_from_file exists (available since Poppler 0.1)
comptime {
    if (!@hasDecl(c, "poppler_document_new_from_file")) {
        @compileError("Poppler headers missing or too old: poppler_document_new_from_file not found");
    }
}

// Tesseract: verify TessBaseAPIInit3 exists (Tesseract 3.02+; may be removed in 6.0)
comptime {
    if (!@hasDecl(c, "TessBaseAPIInit3")) {
        @compileError("Tesseract headers missing or too old: TessBaseAPIInit3 not found. " ++
            "If Tesseract 6.0+ removed this, switch to TessBaseAPIInit4.");
    }
}

// FFmpeg: verify avformat_open_input exists (libavformat 53+)
comptime {
    if (!@hasDecl(c, "avformat_open_input")) {
        @compileError("FFmpeg headers missing or too old: avformat_open_input not found");
    }
}

// GDAL: verify GDALOpen exists
comptime {
    if (!@hasDecl(c, "GDALOpen")) {
        @compileError("GDAL headers missing or too old: GDALOpen not found");
    }
}

// libxml2: verify xmlReadFile exists (libxml2 2.6+)
comptime {
    if (!@hasDecl(c, "xmlReadFile")) {
        @compileError("libxml2 headers missing or too old: xmlReadFile not found");
    }
}

// ============================================================================
// Result struct — flat C-compatible, identical to Chapel's extern record
// ============================================================================

/// Content kind enum matching Chapel's ContentKind
pub const ContentKind = enum(c_int) {
    pdf = 0,
    image = 1,
    audio = 2,
    video = 3,
    epub = 4,
    geospatial = 5,
    unknown = 6,
};

/// Parse result — flat struct, no pointers, safe for FFI
/// Fields use fixed-size arrays to avoid allocation/lifetime issues across FFI.
pub const ParseResult = extern struct {
    status: c_int,            // 0 = success, nonzero = error code
    content_kind: c_int,      // ContentKind value
    page_count: i32,          // pages (PDF/EPUB) or 0
    word_count: i64,          // extracted words
    char_count: i64,          // extracted characters
    duration_sec: f64,        // audio/video duration in seconds, 0 for text
    parse_time_ms: f64,       // wall-clock time to parse this document
    sha256: [65]u8,           // hex-encoded SHA-256 + null terminator
    error_msg: [256]u8,       // error message + null terminator
    title: [256]u8,           // document title
    author: [256]u8,          // document author
    mime_type: [64]u8,        // detected MIME type
};

/// Library handle — holds initialised library contexts
const HandleState = struct {
    allocator: std.mem.Allocator,
    tess_api: ?*c.TessBaseAPI,
    gdal_initialised: bool,
    vips_initialised: bool,
    /// ML inference engine handle (optional, set via ddac_set_ml_handle)
    ml_handle: ?*anyopaque = null,
    /// GPU OCR coprocessor handle (optional, set via ddac_set_gpu_ocr_handle)
    gpu_ocr_handle: ?*anyopaque = null,
};

// ============================================================================
// Helpers
// ============================================================================

/// Copy a slice into a fixed-size buffer, null-terminating
fn copyToFixed(comptime N: usize, dest: *[N]u8, src: []const u8) void {
    const len = @min(src.len, N - 1);
    @memcpy(dest[0..len], src[0..len]);
    dest[len] = 0;
}

/// Zero-fill a fixed-size buffer
fn zeroFixed(comptime N: usize, dest: *[N]u8) void {
    @memset(dest, 0);
}

/// Create a blank result with all fields zeroed
fn blankResult() ParseResult {
    var r: ParseResult = undefined;
    @memset(std.mem.asBytes(&r), 0);
    return r;
}

/// Count words in a byte slice (whitespace-delimited)
fn countWords(text: []const u8) i64 {
    var count: i64 = 0;
    var in_word = false;
    for (text) |ch| {
        if (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t') {
            if (in_word) {
                count += 1;
                in_word = false;
            }
        } else {
            in_word = true;
        }
    }
    if (in_word) count += 1;
    return count;
}

/// Compute SHA-256 of a file and write hex string into dest
fn computeSha256(path: []const u8, dest: *[65]u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch return false;
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    const digest = hasher.finalResult();
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        dest[i * 2] = hex_chars[byte >> 4];
        dest[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    dest[64] = 0;
    return true;
}

/// Get wall-clock time in milliseconds
fn nowMs() f64 {
    const ts = std.time.nanoTimestamp();
    return @as(f64, @floatFromInt(ts)) / 1_000_000.0;
}

// ============================================================================
// Per-format parsers
// ============================================================================

/// PDF: extract text + metadata via Poppler
fn parsePdf(input_path: [*:0]const u8, output_path: [*:0]const u8, result: *ParseResult) void {
    const uri_buf_size = 4096;
    var uri_buf: [uri_buf_size]u8 = undefined;

    // Poppler requires a file:// URI
    const path_slice = std.mem.span(input_path);
    const prefix = "file://";
    if (prefix.len + path_slice.len >= uri_buf_size) {
        copyToFixed(256, &result.error_msg, "Path too long for URI buffer");
        result.status = 1;
        return;
    }
    @memcpy(uri_buf[0..prefix.len], prefix);
    @memcpy(uri_buf[prefix.len .. prefix.len + path_slice.len], path_slice);
    uri_buf[prefix.len + path_slice.len] = 0;

    var gerr: ?*c.GError = null;
    const doc = c.poppler_document_new_from_file(&uri_buf, null, &gerr);
    if (doc == null) {
        if (gerr) |e| {
            const msg = std.mem.span(e.*.message);
            copyToFixed(256, &result.error_msg, msg);
            c.g_error_free(e);
        } else {
            copyToFixed(256, &result.error_msg, "Failed to open PDF");
        }
        result.status = 2; // ParseError
        return;
    }
    defer c.g_object_unref(doc);

    const n_pages = c.poppler_document_get_n_pages(doc);
    result.page_count = @intCast(n_pages);
    result.content_kind = @intFromEnum(ContentKind.pdf);
    copyToFixed(64, &result.mime_type, "application/pdf");

    // Extract title/author
    if (c.poppler_document_get_title(doc)) |t| {
        copyToFixed(256, &result.title, std.mem.span(t));
        c.g_free(t);
    }
    if (c.poppler_document_get_author(doc)) |a| {
        copyToFixed(256, &result.author, std.mem.span(a));
        c.g_free(a);
    }

    // Extract text page by page, write to output file
    const out_file = std.fs.createFileAbsoluteZ(output_path, .{}) catch {
        copyToFixed(256, &result.error_msg, "Cannot create output file");
        result.status = 1;
        return;
    };
    defer out_file.close();

    var total_chars: i64 = 0;
    var total_words: i64 = 0;

    var i: c_int = 0;
    while (i < n_pages) : (i += 1) {
        const page = c.poppler_document_get_page(doc, i) orelse continue;
        defer c.g_object_unref(page);

        if (c.poppler_page_get_text(page)) |text_ptr| {
            const text = std.mem.span(text_ptr);
            out_file.writeAll(text) catch {};
            out_file.writeAll("\n") catch {};
            total_chars += @intCast(text.len);
            total_words += countWords(text);
            c.g_free(text_ptr);
        }
    }

    result.word_count = total_words;
    result.char_count = total_chars;
    result.status = 0;
}

/// Minimum image dimension for OCR (pixels). Images smaller than this
/// in either dimension are too small for Tesseract to produce useful text.
const MIN_OCR_DIMENSION: c_int = 10;

/// Data captured during base parse, passed to processing stages.
const CapturedData = struct {
    ocr_confidence: i32 = -1,
};

/// Detect image MIME type from file extension.
fn detectImageMime(input_path: [*:0]const u8, result: *ParseResult) void {
    const path_str = std.mem.span(input_path);
    if (std.mem.endsWith(u8, path_str, ".png")) {
        copyToFixed(64, &result.mime_type, "image/png");
    } else if (std.mem.endsWith(u8, path_str, ".jpg") or std.mem.endsWith(u8, path_str, ".jpeg")) {
        copyToFixed(64, &result.mime_type, "image/jpeg");
    } else if (std.mem.endsWith(u8, path_str, ".tiff") or std.mem.endsWith(u8, path_str, ".tif")) {
        copyToFixed(64, &result.mime_type, "image/tiff");
    } else if (std.mem.endsWith(u8, path_str, ".bmp")) {
        copyToFixed(64, &result.mime_type, "image/bmp");
    } else if (std.mem.endsWith(u8, path_str, ".webp")) {
        copyToFixed(64, &result.mime_type, "image/webp");
    } else {
        copyToFixed(64, &result.mime_type, "image/unknown");
    }
}

/// Try GPU OCR for an image. Returns true if GPU processed it successfully
/// (result is populated and output file is written). Returns false if GPU
/// processing failed or is unavailable — caller should fall back to CPU.
fn tryGpuOcr(state: *HandleState, input_path: [*:0]const u8, output_path: [*:0]const u8, result: *ParseResult, captured: *CapturedData) bool {
    const ocr_handle = state.gpu_ocr_handle orelse return false;

    // Submit single image, immediately flush, and collect
    const slot = gpu_ocr.ddac_gpu_ocr_submit(ocr_handle, input_path, output_path);
    if (slot < 0) return false;

    gpu_ocr.ddac_gpu_ocr_flush(ocr_handle);

    const ready = gpu_ocr.ddac_gpu_ocr_results_ready(ocr_handle);
    if (ready == 0) return false;

    var ocr_result: gpu_ocr.OcrResult = std.mem.zeroes(gpu_ocr.OcrResult);
    const rc = gpu_ocr.ddac_gpu_ocr_collect(ocr_handle, @intCast(slot), &ocr_result);
    if (rc != 0) return false;

    // status=3 (gpu_error) means "use CPU fallback"
    if (ocr_result.status == 3 or ocr_result.status == 1) return false;

    // GPU processed successfully (status=0) or skipped (status=2)
    result.char_count = ocr_result.char_count;
    result.word_count = ocr_result.word_count;
    result.page_count = 1;
    captured.ocr_confidence = ocr_result.confidence;
    result.status = 0;
    return true;
}

/// Image: OCR via Tesseract + dimensions via libvips
/// When GPU OCR handle is attached, tries GPU path first (single-image
/// submit → flush → collect). Falls back to CPU Tesseract on gpu_error.
fn parseImage(input_path: [*:0]const u8, output_path: [*:0]const u8, state: *HandleState, result: *ParseResult, captured: *CapturedData) void {
    result.content_kind = @intFromEnum(ContentKind.image);
    detectImageMime(input_path, result);

    // Try GPU OCR first (if handle is attached)
    if (tryGpuOcr(state, input_path, output_path, result, captured)) {
        return; // GPU handled it
    }

    // CPU Tesseract path (original or GPU fallback)
    const tess = state.tess_api orelse {
        copyToFixed(256, &result.error_msg, "Tesseract not initialised");
        result.status = 1;
        return;
    };

    // Set image for OCR
    const pix = c.pixRead(input_path);
    if (pix == null) {
        copyToFixed(256, &result.error_msg, "Cannot read image file");
        result.status = 2;
        return;
    }
    defer c.pixDestroy(@constCast(&pix));

    // Check minimum dimensions — tiny images (icons, spacers) produce
    // only Tesseract warnings and no useful OCR text
    const img_w = c.pixGetWidth(pix);
    const img_h = c.pixGetHeight(pix);
    if (img_w < MIN_OCR_DIMENSION or img_h < MIN_OCR_DIMENSION) {
        // Write an empty output file and succeed with zero words
        const out_file = std.fs.createFileAbsoluteZ(output_path, .{}) catch {
            copyToFixed(256, &result.error_msg, "Cannot create output file");
            result.status = 1;
            return;
        };
        out_file.close();
        result.page_count = 1;
        result.word_count = 0;
        result.char_count = 0;
        result.status = 0;
        return;
    }

    c.TessBaseAPISetImage2(tess, pix);
    if (c.TessBaseAPIRecognize(tess, null) != 0) {
        copyToFixed(256, &result.error_msg, "Tesseract recognition failed");
        result.status = 2;
        return;
    }

    // Capture OCR confidence for processing stages (0-100 scale)
    captured.ocr_confidence = @intCast(c.TessBaseAPIMeanTextConf(tess));

    const ocr_text_ptr = c.TessBaseAPIGetUTF8Text(tess);
    if (ocr_text_ptr == null) {
        copyToFixed(256, &result.error_msg, "No text extracted from image");
        result.status = 0; // not an error, just no text
        return;
    }
    defer c.TessDeleteText(ocr_text_ptr);
    const ocr_text = std.mem.span(ocr_text_ptr);

    // Write extracted text to output
    const out_file = std.fs.createFileAbsoluteZ(output_path, .{}) catch {
        copyToFixed(256, &result.error_msg, "Cannot create output file");
        result.status = 1;
        return;
    };
    defer out_file.close();
    out_file.writeAll(ocr_text) catch {};

    result.char_count = @intCast(ocr_text.len);
    result.word_count = countWords(ocr_text);
    result.page_count = 1;
    result.status = 0;
}

/// Format an FFmpeg error code into a human-readable message
fn avErrorMsg(errnum: c_int, dest: *[256]u8) void {
    var buf: [256]u8 = undefined;
    if (c.av_strerror(errnum, &buf, 256) == 0) {
        const msg = std.mem.sliceTo(&buf, 0);
        copyToFixed(256, dest, msg);
    } else {
        copyToFixed(256, dest, "Unknown FFmpeg error");
    }
}

/// Audio: metadata + duration via FFmpeg (libavformat)
fn parseAudio(input_path: [*:0]const u8, output_path: [*:0]const u8, result: *ParseResult) void {
    result.content_kind = @intFromEnum(ContentKind.audio);

    var fmt_ctx: ?*c.AVFormatContext = null;
    const open_err = c.avformat_open_input(&fmt_ctx, input_path, null, null);
    if (open_err < 0) {
        avErrorMsg(open_err, &result.error_msg);
        result.status = 2;
        return;
    }
    defer c.avformat_close_input(&fmt_ctx);

    const stream_err = c.avformat_find_stream_info(fmt_ctx, null);
    if (stream_err < 0) {
        avErrorMsg(stream_err, &result.error_msg);
        result.status = 2;
        return;
    }

    const ctx = fmt_ctx.?;
    // Duration in seconds
    if (ctx.duration > 0) {
        result.duration_sec = @as(f64, @floatFromInt(ctx.duration)) / @as(f64, @floatFromInt(c.AV_TIME_BASE));
    }

    // Extract metadata (title, artist)
    if (ctx.metadata) |metadata| {
        var tag: ?*c.AVDictionaryEntry = null;
        tag = c.av_dict_get(metadata, "title", null, 0);
        if (tag) |t| {
            if (t.value) |v| copyToFixed(256, &result.title, std.mem.span(v));
        }
        tag = c.av_dict_get(metadata, "artist", null, 0);
        if (tag) |t| {
            if (t.value) |v| copyToFixed(256, &result.author, std.mem.span(v));
        }
    }

    // Write metadata summary to output file
    const out_file = std.fs.createFileAbsoluteZ(output_path, .{}) catch {
        copyToFixed(256, &result.error_msg, "Cannot create output file");
        result.status = 1;
        return;
    };
    defer out_file.close();

    var buf: [512]u8 = undefined;
    const written = std.fmt.bufPrint(&buf, "(audio (duration {d:.2}) (title \"{s}\") (artist \"{s}\"))\n", .{
        result.duration_sec,
        std.mem.sliceTo(&result.title, 0),
        std.mem.sliceTo(&result.author, 0),
    }) catch &buf;
    out_file.writeAll(written) catch {};

    // MIME detection
    const path_str = std.mem.span(input_path);
    if (std.mem.endsWith(u8, path_str, ".mp3")) {
        copyToFixed(64, &result.mime_type, "audio/mpeg");
    } else if (std.mem.endsWith(u8, path_str, ".wav")) {
        copyToFixed(64, &result.mime_type, "audio/wav");
    } else if (std.mem.endsWith(u8, path_str, ".flac")) {
        copyToFixed(64, &result.mime_type, "audio/flac");
    } else {
        copyToFixed(64, &result.mime_type, "audio/unknown");
    }

    result.status = 0;
}

/// Video: subtitles + metadata via FFmpeg
fn parseVideo(input_path: [*:0]const u8, output_path: [*:0]const u8, result: *ParseResult) void {
    result.content_kind = @intFromEnum(ContentKind.video);

    var fmt_ctx: ?*c.AVFormatContext = null;
    const open_err = c.avformat_open_input(&fmt_ctx, input_path, null, null);
    if (open_err < 0) {
        avErrorMsg(open_err, &result.error_msg);
        result.status = 2;
        return;
    }
    defer c.avformat_close_input(&fmt_ctx);

    const stream_err = c.avformat_find_stream_info(fmt_ctx, null);
    if (stream_err < 0) {
        avErrorMsg(stream_err, &result.error_msg);
        result.status = 2;
        return;
    }

    const ctx = fmt_ctx.?;
    if (ctx.duration > 0) {
        result.duration_sec = @as(f64, @floatFromInt(ctx.duration)) / @as(f64, @floatFromInt(c.AV_TIME_BASE));
    }

    // Extract metadata
    if (ctx.metadata) |metadata| {
        var tag: ?*c.AVDictionaryEntry = null;
        tag = c.av_dict_get(metadata, "title", null, 0);
        if (tag) |t| {
            if (t.value) |v| copyToFixed(256, &result.title, std.mem.span(v));
        }
        tag = c.av_dict_get(metadata, "artist", null, 0);
        if (tag) |t| {
            if (t.value) |v| copyToFixed(256, &result.author, std.mem.span(v));
        }
    }

    // Look for subtitle streams and extract text
    const out_file = std.fs.createFileAbsoluteZ(output_path, .{}) catch {
        copyToFixed(256, &result.error_msg, "Cannot create output file");
        result.status = 1;
        return;
    };
    defer out_file.close();

    var sub_count: i64 = 0;
    for (0..ctx.nb_streams) |i| {
        const stream = ctx.streams[i];
        if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_SUBTITLE) {
            sub_count += 1;
        }
    }

    var buf: [512]u8 = undefined;
    const written = std.fmt.bufPrint(&buf, "(video (duration {d:.2}) (subtitle-streams {d}) (title \"{s}\"))\n", .{
        result.duration_sec,
        sub_count,
        std.mem.sliceTo(&result.title, 0),
    }) catch &buf;
    out_file.writeAll(written) catch {};

    // MIME
    const path_str = std.mem.span(input_path);
    if (std.mem.endsWith(u8, path_str, ".mp4")) {
        copyToFixed(64, &result.mime_type, "video/mp4");
    } else if (std.mem.endsWith(u8, path_str, ".mkv")) {
        copyToFixed(64, &result.mime_type, "video/x-matroska");
    } else {
        copyToFixed(64, &result.mime_type, "video/unknown");
    }

    result.status = 0;
}

/// EPUB: structured text extraction via libxml2
fn parseEpub(input_path: [*:0]const u8, output_path: [*:0]const u8, result: *ParseResult) void {
    result.content_kind = @intFromEnum(ContentKind.epub);
    copyToFixed(64, &result.mime_type, "application/epub+zip");

    // EPUB is a ZIP — for now, parse the container.xml or content.opf
    // In a production version this would unzip and iterate XHTML files.
    // Here we use libxml2 to parse the file if it's an unzipped XHTML.
    const doc = c.xmlReadFile(input_path, null, c.XML_PARSE_RECOVER | c.XML_PARSE_NOERROR);
    if (doc == null) {
        // Capture libxml2 error if available
        const xml_err = c.xmlGetLastError();
        if (xml_err) |e| {
            if (e.*.message) |msg| {
                copyToFixed(256, &result.error_msg, std.mem.span(msg));
            } else {
                copyToFixed(256, &result.error_msg, "Cannot parse EPUB/XHTML content");
            }
        } else {
            copyToFixed(256, &result.error_msg, "Cannot parse EPUB/XHTML content");
        }
        result.status = 2;
        return;
    }
    defer c.xmlFreeDoc(doc);

    const out_file = std.fs.createFileAbsoluteZ(output_path, .{}) catch {
        copyToFixed(256, &result.error_msg, "Cannot create output file");
        result.status = 1;
        return;
    };
    defer out_file.close();

    // Extract all text content from the XML tree
    const root = c.xmlDocGetRootElement(doc);
    if (root == null) {
        result.status = 0;
        return;
    }

    var total_chars: i64 = 0;
    var total_words: i64 = 0;
    extractXmlText(root, out_file, &total_chars, &total_words);

    result.char_count = total_chars;
    result.word_count = total_words;
    result.page_count = 1; // EPUB doesn't have fixed pages
    result.status = 0;
}

/// Recursively extract text from XML nodes
fn extractXmlText(node: *c.xmlNode, file: std.fs.File, chars: *i64, words: *i64) void {
    var cur: ?*c.xmlNode = node;
    while (cur) |n| {
        if (n.type == c.XML_TEXT_NODE or n.type == c.XML_CDATA_SECTION_NODE) {
            if (n.content) |content| {
                const text = std.mem.span(content);
                file.writeAll(text) catch {};
                chars.* += @intCast(text.len);
                words.* += countWords(text);
            }
        }
        if (n.children) |children| {
            extractXmlText(children, file, chars, words);
        }
        cur = n.next;
    }
}

/// Geospatial: projection + bounds via GDAL
fn parseGeo(input_path: [*:0]const u8, output_path: [*:0]const u8, result: *ParseResult) void {
    result.content_kind = @intFromEnum(ContentKind.geospatial);

    const dataset = c.GDALOpen(input_path, c.GA_ReadOnly);
    if (dataset == null) {
        // Capture GDAL's last error message
        const gdal_msg = c.CPLGetLastErrorMsg();
        if (gdal_msg) |msg| {
            const msg_str = std.mem.span(msg);
            if (msg_str.len > 0) {
                copyToFixed(256, &result.error_msg, msg_str);
            } else {
                copyToFixed(256, &result.error_msg, "Cannot open geospatial file");
            }
        } else {
            copyToFixed(256, &result.error_msg, "Cannot open geospatial file");
        }
        result.status = 2;
        return;
    }
    defer _ = c.GDALClose(dataset);

    // Get projection
    const proj = c.GDALGetProjectionRef(dataset);

    // Get geotransform (bounds)
    var gt: [6]f64 = undefined;
    _ = c.GDALGetGeoTransform(dataset, &gt);

    const x_size = c.GDALGetRasterXSize(dataset);
    const y_size = c.GDALGetRasterYSize(dataset);

    // Write metadata to output
    const out_file = std.fs.createFileAbsoluteZ(output_path, .{}) catch {
        copyToFixed(256, &result.error_msg, "Cannot create output file");
        result.status = 1;
        return;
    };
    defer out_file.close();

    var buf: [1024]u8 = undefined;
    const proj_str = if (proj) |p| std.mem.span(p) else "unknown";
    const written = std.fmt.bufPrint(&buf, "(geospatial\n  (raster-size {d} {d})\n  (origin {d:.6} {d:.6})\n  (pixel-size {d:.6} {d:.6})\n  (projection \"{s}\"))\n", .{
        x_size,
        y_size,
        gt[0],
        gt[3],
        gt[1],
        gt[5],
        proj_str,
    }) catch &buf;
    out_file.writeAll(written) catch {};

    // MIME
    const path_str = std.mem.span(input_path);
    if (std.mem.endsWith(u8, path_str, ".shp")) {
        copyToFixed(64, &result.mime_type, "application/x-shapefile");
    } else if (std.mem.endsWith(u8, path_str, ".geotiff") or std.mem.endsWith(u8, path_str, ".tif")) {
        copyToFixed(64, &result.mime_type, "image/tiff");
    } else {
        copyToFixed(64, &result.mime_type, "application/x-geospatial");
    }

    result.status = 0;
}

// ============================================================================
// Content type detection (by file extension)
// ============================================================================

fn detectKind(path: [*:0]const u8) ContentKind {
    const s = std.mem.span(path);
    // Find last dot
    const dot_pos = std.mem.lastIndexOfScalar(u8, s, '.') orelse return .unknown;
    const ext = s[dot_pos..];

    if (std.mem.eql(u8, ext, ".pdf")) return .pdf;
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return .image;
    if (std.mem.eql(u8, ext, ".png")) return .image;
    if (std.mem.eql(u8, ext, ".tiff") or std.mem.eql(u8, ext, ".tif")) return .image;
    if (std.mem.eql(u8, ext, ".bmp")) return .image;
    if (std.mem.eql(u8, ext, ".mp3")) return .audio;
    if (std.mem.eql(u8, ext, ".wav")) return .audio;
    if (std.mem.eql(u8, ext, ".flac")) return .audio;
    if (std.mem.eql(u8, ext, ".ogg")) return .audio;
    if (std.mem.eql(u8, ext, ".mp4")) return .video;
    if (std.mem.eql(u8, ext, ".mkv")) return .video;
    if (std.mem.eql(u8, ext, ".avi")) return .video;
    if (std.mem.eql(u8, ext, ".webm")) return .video;
    if (std.mem.eql(u8, ext, ".epub")) return .epub;
    if (std.mem.eql(u8, ext, ".shp")) return .geospatial;
    if (std.mem.eql(u8, ext, ".geotiff")) return .geospatial;

    return .unknown;
}

// ============================================================================
// Exported C API — called from Chapel
// ============================================================================

/// Initialise the library. Returns an opaque handle.
/// Must be called once per thread/task.
export fn ddac_init() ?*anyopaque {
    const allocator = std.heap.c_allocator;

    const state = allocator.create(HandleState) catch return null;
    state.* = .{
        .allocator = allocator,
        .tess_api = null,
        .gdal_initialised = false,
        .vips_initialised = false,
    };

    // Initialise Tesseract (English)
    const tess = c.TessBaseAPICreate();
    if (tess != null) {
        if (c.TessBaseAPIInit3(tess, null, "eng") == 0) {
            state.tess_api = tess;
        } else {
            c.TessBaseAPIDelete(tess);
        }
    }

    // Initialise GDAL
    c.GDALAllRegister();
    state.gdal_initialised = true;

    // Initialise libvips
    if (c.vips_init("docudactyl") == 0) {
        state.vips_initialised = true;
    }

    return @ptrCast(state);
}

/// Free all library contexts. Safe to call with null.
export fn ddac_free(handle: ?*anyopaque) void {
    const ptr = handle orelse return;
    const state: *HandleState = @ptrCast(@alignCast(ptr));

    if (state.tess_api) |tess| {
        c.TessBaseAPIEnd(tess);
        c.TessBaseAPIDelete(tess);
    }

    if (state.vips_initialised) {
        c.vips_shutdown();
    }

    // GDAL has no per-handle cleanup; GDALDestroyDriverManager is global

    state.allocator.destroy(state);
}

/// Parse a document. Detects format from extension, dispatches to the right
/// C library, writes extracted content to output_path, returns summary.
/// After the base parse, runs any enabled processing stages (bitmask).
///
/// output_fmt: 0 = scheme, 1 = json, 2 = csv (controls output formatting)
/// stage_flags: bitmask of DDAC_STAGE_* flags (0 = no extra stages)
export fn ddac_parse(
    handle: ?*anyopaque,
    input_path: ?[*:0]const u8,
    output_path: ?[*:0]const u8,
    output_fmt: c_int,
    stage_flags: u64,
) ParseResult {
    _ = output_fmt; // format selection handled by Chapel's ShardedOutput

    var result = blankResult();

    const ptr = handle orelse {
        result.status = 4; // NullPointer
        copyToFixed(256, &result.error_msg, "Null handle");
        return result;
    };
    const state: *HandleState = @ptrCast(@alignCast(ptr));

    const in_path = input_path orelse {
        result.status = 3; // InvalidParam
        copyToFixed(256, &result.error_msg, "Null input path");
        return result;
    };

    const out_path = output_path orelse {
        result.status = 3;
        copyToFixed(256, &result.error_msg, "Null output path");
        return result;
    };

    // Early existence check — produce a clear FileNotFound error
    // rather than letting each parser fail with a cryptic message
    const in_slice = std.mem.span(in_path);
    std.fs.accessAbsolute(in_slice, .{}) catch {
        result.status = 2; // FileNotFound
        copyToFixed(256, &result.error_msg, "File not found: ");
        // Append as much of the path as fits
        const prefix_len = std.mem.len(@as([*:0]const u8, @ptrCast(&result.error_msg)));
        const remaining = 255 - prefix_len;
        const path_len = @min(in_slice.len, remaining);
        @memcpy(result.error_msg[prefix_len .. prefix_len + path_len], in_slice[0..path_len]);
        result.error_msg[prefix_len + path_len] = 0;
        return result;
    };

    // Compute SHA-256
    _ = computeSha256(in_slice, &result.sha256);

    // Time the parse
    const start = nowMs();

    // Detect content type and dispatch
    var captured = CapturedData{};
    const kind = detectKind(in_path);
    switch (kind) {
        .pdf => parsePdf(in_path, out_path, &result),
        .image => parseImage(in_path, out_path, state, &result, &captured),
        .audio => parseAudio(in_path, out_path, &result),
        .video => parseVideo(in_path, out_path, &result),
        .epub => parseEpub(in_path, out_path, &result),
        .geospatial => parseGeo(in_path, out_path, &result),
        .unknown => {
            result.status = 5; // UnsupportedFormat
            result.content_kind = @intFromEnum(ContentKind.unknown);
            copyToFixed(256, &result.error_msg, "Unsupported file format");
        },
    }

    result.parse_time_ms = nowMs() - start;

    // Run processing stages (only if base parse succeeded and stages requested)
    if (stage_flags != 0 and result.status == 0) {
        const stage_ctx = stages.StageContext{
            .stages = stage_flags,
            .input_path = in_path,
            .output_path = out_path,
            .content_kind = result.content_kind,
            .sha256 = &result.sha256,
            .mime_type = &result.mime_type,
            .page_count = result.page_count,
            .word_count = result.word_count,
            .char_count = result.char_count,
            .duration_sec = result.duration_sec,
            .ocr_confidence = captured.ocr_confidence,
            .tess_api = if (state.tess_api) |t| @ptrCast(t) else null,
            .ml_handle = state.ml_handle,
        };
        stages.runStages(stage_ctx);
    }

    return result;
}

/// Attach an ML inference engine handle to a parse handle.
/// Must be called after ddac_init(). The ML handle remains owned by the caller
/// (Chapel) — it will NOT be freed by ddac_free().
export fn ddac_set_ml_handle(handle: ?*anyopaque, ml_handle: ?*anyopaque) void {
    const ptr = handle orelse return;
    const state: *HandleState = @ptrCast(@alignCast(ptr));
    state.ml_handle = ml_handle;
}

/// Attach a GPU OCR coprocessor handle to a parse handle.
/// Must be called after ddac_init(). The GPU OCR handle remains owned by the
/// caller (Chapel) — it will NOT be freed by ddac_free().
export fn ddac_set_gpu_ocr_handle(handle: ?*anyopaque, ocr_handle: ?*anyopaque) void {
    const ptr = handle orelse return;
    const state: *HandleState = @ptrCast(@alignCast(ptr));
    state.gpu_ocr_handle = ocr_handle;
}

/// Return version string (null-terminated, static storage).
export fn ddac_version() [*:0]const u8 {
    return VERSION;
}
