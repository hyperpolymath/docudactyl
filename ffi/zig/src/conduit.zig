// Docudactyl — Preprocessing Conduit
//
// Lightweight pre-processing pipeline that runs before the main Chapel parse.
// Pre-computes metadata that would otherwise be computed redundantly:
//
//   1. Content-type detection (magic bytes, not just extension)
//   2. File validation (empty, corrupt, accessible)
//   3. SHA-256 pre-computation (feeds L2 Dragonfly cache lookup)
//   4. File size capture (avoids stat() in main loop)
//
// Chapel calls ddac_conduit_process() on a batch of paths. The conduit
// returns an array of ConduitResult structs that the main loop uses to
// skip invalid files and pre-populate cache keys.
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

const std = @import("std");

// ============================================================================
// Content-Type Detection (Magic Bytes)
// ============================================================================

/// Content kind detected from file magic bytes.
/// Matches ContentKind enum in docudactyl_ffi.zig (0-6).
const ContentKind = enum(u8) {
    pdf = 0,
    image = 1,
    audio = 2,
    video = 3,
    epub = 4,
    geo = 5,
    unknown = 6,
};

/// Detect content type from the first few bytes of a file.
fn detectMagic(header: []const u8) ContentKind {
    if (header.len < 4) return .unknown;

    // PDF: %PDF
    if (header[0] == '%' and header[1] == 'P' and header[2] == 'D' and header[3] == 'F')
        return .pdf;

    // PNG: 89 50 4E 47
    if (header[0] == 0x89 and header[1] == 0x50 and header[2] == 0x4E and header[3] == 0x47)
        return .image;

    // JPEG: FF D8 FF
    if (header[0] == 0xFF and header[1] == 0xD8 and header[2] == 0xFF)
        return .image;

    // TIFF: 49 49 2A 00 (little-endian) or 4D 4D 00 2A (big-endian)
    if ((header[0] == 0x49 and header[1] == 0x49 and header[2] == 0x2A and header[3] == 0x00) or
        (header[0] == 0x4D and header[1] == 0x4D and header[2] == 0x00 and header[3] == 0x2A))
        return .image;

    // BMP: 42 4D
    if (header[0] == 0x42 and header[1] == 0x4D)
        return .image;

    // WebP: RIFF + WEBP at offset 8
    if (header.len >= 12 and header[0] == 'R' and header[1] == 'I' and
        header[2] == 'F' and header[3] == 'F' and
        header[8] == 'W' and header[9] == 'E' and header[10] == 'B' and header[11] == 'P')
        return .image;

    // MP3: ID3 tag or FF FB sync
    if ((header[0] == 'I' and header[1] == 'D' and header[2] == '3') or
        (header[0] == 0xFF and (header[1] & 0xE0) == 0xE0))
        return .audio;

    // FLAC: fLaC
    if (header[0] == 'f' and header[1] == 'L' and header[2] == 'a' and header[3] == 'C')
        return .audio;

    // WAV: RIFF + WAVE at offset 8
    if (header.len >= 12 and header[0] == 'R' and header[1] == 'I' and
        header[2] == 'F' and header[3] == 'F' and
        header[8] == 'W' and header[9] == 'A' and header[10] == 'V' and header[11] == 'E')
        return .audio;

    // OGG: OggS
    if (header[0] == 'O' and header[1] == 'g' and header[2] == 'g' and header[3] == 'S')
        return .audio; // Could also be video (Theora), but audio is more common

    // MP4/MOV: ftyp at offset 4
    if (header.len >= 8 and header[4] == 'f' and header[5] == 't' and
        header[6] == 'y' and header[7] == 'p')
        return .video;

    // MKV/WebM: 1A 45 DF A3 (EBML header)
    if (header[0] == 0x1A and header[1] == 0x45 and header[2] == 0xDF and header[3] == 0xA3)
        return .video;

    // AVI: RIFF + AVI at offset 8
    if (header.len >= 12 and header[0] == 'R' and header[1] == 'I' and
        header[2] == 'F' and header[3] == 'F' and
        header[8] == 'A' and header[9] == 'V' and header[10] == 'I')
        return .video;

    // EPUB: PK (ZIP) — we detect EPUB specifically by checking for META-INF
    if (header[0] == 'P' and header[1] == 'K' and header[2] == 0x03 and header[3] == 0x04)
        return .epub; // Heuristic: ZIP files in document context are likely EPUB

    // Shapefile: starts with 00 00 27 0A (big-endian int 9994)
    if (header.len >= 4 and header[0] == 0x00 and header[1] == 0x00 and
        header[2] == 0x27 and header[3] == 0x0A)
        return .geo;

    return .unknown;
}

// ============================================================================
// Conduit Result (C-ABI struct)
// ============================================================================

/// Result of pre-processing a single file.
/// Fixed-size struct for zero-copy transfer to Chapel.
const ConduitResult = extern struct {
    /// Detected content kind (0-6, matches ContentKind).
    content_kind: u8,

    /// Validation status: 0=ok, 1=not_found, 2=empty, 3=unreadable.
    validation: u8,

    /// Padding for alignment.
    _pad: [6]u8,

    /// File size in bytes.
    file_size: i64,

    /// SHA-256 hex digest (64 chars + null).
    sha256: [65]u8,

    /// Padding for 8-byte alignment.
    _pad2: [7]u8,
};

// Verify struct layout
comptime {
    if (@sizeOf(ConduitResult) != 88)
        @compileError("ConduitResult must be 88 bytes");
    if (@alignOf(ConduitResult) != 8)
        @compileError("ConduitResult must be 8-byte aligned");
}

// ============================================================================
// C-ABI exports
// ============================================================================

/// Pre-process a single file: detect type, validate, compute SHA-256.
/// path: null-terminated absolute path
/// result_out: pointer to ConduitResult (88 bytes)
/// Returns 0 on success, non-zero on error.
export fn ddac_conduit_process(path: [*:0]const u8, result_out: *ConduitResult) c_int {
    result_out.* = std.mem.zeroes(ConduitResult);

    // Open file
    const file = std.fs.openFileAbsoluteZ(path, .{}) catch {
        result_out.validation = 1; // not found
        return 1;
    };
    defer file.close();

    // Get file size
    const stat = file.stat() catch {
        result_out.validation = 3; // unreadable
        return 3;
    };
    result_out.file_size = @intCast(stat.size);

    if (stat.size == 0) {
        result_out.validation = 2; // empty
        return 2;
    }

    // Read header for magic-byte detection
    var header: [16]u8 = undefined;
    const header_n = file.read(&header) catch {
        result_out.validation = 3;
        return 3;
    };
    result_out.content_kind = @intFromEnum(detectMagic(header[0..header_n]));

    // Seek back to start for SHA-256
    file.seekTo(0) catch return 0;

    // Compute SHA-256 over entire file
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch break;
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    const digest = hasher.finalResult();

    // Convert to hex
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte_val, i| {
        result_out.sha256[i * 2] = hex_chars[byte_val >> 4];
        result_out.sha256[i * 2 + 1] = hex_chars[byte_val & 0x0f];
    }
    result_out.sha256[64] = 0;

    result_out.validation = 0;
    return 0;
}

/// Batch pre-process: process N files and write results.
/// paths: array of N null-terminated path pointers
/// results: array of N ConduitResult structs
/// count: number of files
/// Returns number of valid (validation==0) files.
export fn ddac_conduit_batch(
    paths: [*]const [*:0]const u8,
    results: [*]ConduitResult,
    count: u32,
) u32 {
    var valid: u32 = 0;
    for (0..count) |i| {
        const rc = ddac_conduit_process(paths[i], &results[i]);
        if (rc == 0) valid += 1;
    }
    return valid;
}

/// Get the struct size for Chapel allocation.
export fn ddac_conduit_result_size() usize {
    return @sizeOf(ConduitResult);
}
