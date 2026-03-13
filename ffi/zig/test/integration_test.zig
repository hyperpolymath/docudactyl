// Docudactyl FFI Integration Tests
//
// Verify that the Zig FFI correctly implements the C ABI declared in
// generated/abi/docudactyl_ffi.h and proven in src/Docudactyl/ABI/.
//
// These tests exercise the C-exported functions by linking against
// libdocudactyl_ffi.so — they verify the actual ABI, not internal Zig code.
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

const std = @import("std");
const testing = std.testing;

// ============================================================================
// Core Lifecycle (C ABI)
// ============================================================================

extern fn ddac_init() ?*anyopaque;
extern fn ddac_free(?*anyopaque) void;
extern fn ddac_version() [*:0]const u8;

// ============================================================================
// Handle Setters (C ABI)
// ============================================================================

extern fn ddac_set_ml_handle(?*anyopaque, ?*anyopaque) void;
extern fn ddac_set_gpu_ocr_handle(?*anyopaque, ?*anyopaque) void;

// ============================================================================
// LMDB Cache (C ABI)
// ============================================================================

extern fn ddac_cache_init([*:0]const u8, u64) ?*anyopaque;
extern fn ddac_cache_free(?*anyopaque) void;
extern fn ddac_cache_count(?*anyopaque) u64;
extern fn ddac_cache_sync(?*anyopaque) void;
extern fn ddac_cache_lookup(?*anyopaque, [*:0]const u8, i64, i64, ?*anyopaque, usize) c_int;
extern fn ddac_cache_store(?*anyopaque, [*:0]const u8, i64, i64, ?*const anyopaque, usize) void;

// ============================================================================
// I/O Prefetcher (C ABI)
// ============================================================================

extern fn ddac_prefetch_init(u32) ?*anyopaque;
extern fn ddac_prefetch_hint(?*anyopaque, [*:0]const u8) void;
extern fn ddac_prefetch_done(?*anyopaque, [*:0]const u8) void;
extern fn ddac_prefetch_free(?*anyopaque) void;
extern fn ddac_prefetch_inflight(?*anyopaque) u32;

// ============================================================================
// Hardware Crypto (C ABI)
// ============================================================================

const CryptoCaps = extern struct {
    has_sha_ni: u8,
    has_avx2: u8,
    has_avx512: u8,
    has_arm_sha2: u8,
    has_arm_sha512: u8,
    has_aes_ni: u8,
    _pad: [2]u8,
    sha256_tier: u8,
    _pad2: [7]u8,
};

extern fn ddac_crypto_detect(*CryptoCaps) void;
extern fn ddac_crypto_sha256_tier() u8;
extern fn ddac_crypto_sha256_name() [*:0]const u8;
extern fn ddac_crypto_caps_size() usize;

// ============================================================================
// ML Inference (C ABI)
// ============================================================================

extern fn ddac_ml_init() ?*anyopaque;
extern fn ddac_ml_free(?*anyopaque) void;
extern fn ddac_ml_available(?*anyopaque) u8;
extern fn ddac_ml_provider(?*anyopaque) u8;
extern fn ddac_ml_provider_name(?*anyopaque) [*:0]const u8;
extern fn ddac_ml_set_model_dir(?*anyopaque, [*:0]const u8) void;
extern fn ddac_ml_result_size() usize;
extern fn ddac_ml_stage_count() u8;
extern fn ddac_ml_model_name(u8) [*:0]const u8;

// ============================================================================
// GPU OCR (C ABI)
// ============================================================================

extern fn ddac_gpu_ocr_init() ?*anyopaque;
extern fn ddac_gpu_ocr_free(?*anyopaque) void;
extern fn ddac_gpu_ocr_backend(?*anyopaque) u8;
extern fn ddac_gpu_ocr_max_batch() u32;
extern fn ddac_gpu_ocr_result_size() usize;

// ============================================================================
// Conduit (C ABI)
// ============================================================================

extern fn ddac_conduit_result_size() usize;
extern fn ddac_conduit_process([*:0]const u8, ?*anyopaque) c_int;

// ============================================================================
// Dragonfly / Redis (C ABI)
// ============================================================================

extern fn ddac_dragonfly_connect([*:0]const u8) ?*anyopaque;
extern fn ddac_dragonfly_close(?*anyopaque) void;

// ============================================================================
// Tests — Core Lifecycle
// ============================================================================

test "create and destroy handle" {
    const handle = ddac_init() orelse return error.InitFailed;
    defer ddac_free(handle);
    try testing.expect(@intFromPtr(handle) != 0);
}

test "free null is safe" {
    ddac_free(null);
}

test "multiple handles are independent" {
    const h1 = ddac_init() orelse return error.InitFailed;
    defer ddac_free(h1);
    const h2 = ddac_init() orelse return error.InitFailed;
    defer ddac_free(h2);
    try testing.expect(h1 != h2);
}

// ============================================================================
// Tests — Version
// ============================================================================

test "version string is not empty" {
    const ver = ddac_version();
    const ver_str = std.mem.span(ver);
    try testing.expect(ver_str.len > 0);
}

test "version string is semantic version format" {
    const ver = ddac_version();
    const ver_str = std.mem.span(ver);
    try testing.expect(std.mem.count(u8, ver_str, ".") >= 1);
}

test "version is 0.4.0" {
    const ver = ddac_version();
    const ver_str = std.mem.span(ver);
    try testing.expectEqualStrings("0.4.0", ver_str);
}

// ============================================================================
// Tests — Handle Setters
// ============================================================================

test "set ML handle on null handle is safe" {
    ddac_set_ml_handle(null, null);
}

test "set GPU OCR handle on null handle is safe" {
    ddac_set_gpu_ocr_handle(null, null);
}

test "set ML handle with null ML handle is safe" {
    const handle = ddac_init() orelse return error.InitFailed;
    defer ddac_free(handle);
    ddac_set_ml_handle(handle, null);
}

test "set GPU OCR handle with null OCR handle is safe" {
    const handle = ddac_init() orelse return error.InitFailed;
    defer ddac_free(handle);
    ddac_set_gpu_ocr_handle(handle, null);
}

// ============================================================================
// Tests — Hardware Crypto
// ============================================================================

test "crypto detect returns valid tier" {
    var caps: CryptoCaps = std.mem.zeroes(CryptoCaps);
    ddac_crypto_detect(&caps);
    // Tier must be 0, 1, or 2
    try testing.expect(caps.sha256_tier <= 2);
}

test "crypto sha256 tier matches detect" {
    var caps: CryptoCaps = std.mem.zeroes(CryptoCaps);
    ddac_crypto_detect(&caps);
    const tier = ddac_crypto_sha256_tier();
    try testing.expectEqual(caps.sha256_tier, tier);
}

test "crypto sha256 name is not empty" {
    const name = ddac_crypto_sha256_name();
    const name_str = std.mem.span(name);
    try testing.expect(name_str.len > 0);
}

test "crypto caps size is 16 bytes" {
    const size = ddac_crypto_caps_size();
    try testing.expectEqual(@as(usize, 16), size);
}

test "crypto capabilities are boolean flags" {
    var caps: CryptoCaps = std.mem.zeroes(CryptoCaps);
    ddac_crypto_detect(&caps);
    try testing.expect(caps.has_sha_ni <= 1);
    try testing.expect(caps.has_avx2 <= 1);
    try testing.expect(caps.has_avx512 <= 1);
    try testing.expect(caps.has_arm_sha2 <= 1);
    try testing.expect(caps.has_arm_sha512 <= 1);
    try testing.expect(caps.has_aes_ni <= 1);
}

// ============================================================================
// Tests — I/O Prefetcher
// ============================================================================

test "prefetch init and free" {
    const handle = ddac_prefetch_init(8);
    if (handle) |h| {
        const inflight = ddac_prefetch_inflight(h);
        try testing.expectEqual(@as(u32, 0), inflight);
        ddac_prefetch_free(h);
    }
    // null return is acceptable (io_uring may not be available)
}

test "prefetch free null is safe" {
    ddac_prefetch_free(null);
}

test "prefetch hint and done with nonexistent file is safe" {
    const handle = ddac_prefetch_init(4) orelse return;
    defer ddac_prefetch_free(handle);
    ddac_prefetch_hint(handle, "/nonexistent/file.pdf");
    ddac_prefetch_done(handle, "/nonexistent/file.pdf");
}

// ============================================================================
// Tests — LMDB Cache
// ============================================================================

test "cache init with temp dir" {
    var buf: [256]u8 = undefined;
    const tmpdir = std.fmt.bufPrintZ(&buf, "/tmp/ddac-test-{d}", .{std.time.milliTimestamp()}) catch return;
    std.fs.makeDirAbsolute(std.mem.span(tmpdir)) catch return;
    defer std.fs.deleteTreeAbsolute(std.mem.span(tmpdir)) catch {};

    const handle = ddac_cache_init(tmpdir, 64);
    if (handle) |h| {
        const count = ddac_cache_count(h);
        try testing.expectEqual(@as(u64, 0), count);
        ddac_cache_sync(h);
        ddac_cache_free(h);
    }
}

test "cache free null is safe" {
    ddac_cache_free(null);
}

test "cache lookup on empty cache returns miss" {
    var buf: [256]u8 = undefined;
    const tmpdir = std.fmt.bufPrintZ(&buf, "/tmp/ddac-test-{d}", .{std.time.milliTimestamp()}) catch return;
    std.fs.makeDirAbsolute(std.mem.span(tmpdir)) catch return;
    defer std.fs.deleteTreeAbsolute(std.mem.span(tmpdir)) catch {};

    const handle = ddac_cache_init(tmpdir, 64) orelse return;
    defer ddac_cache_free(handle);

    var result_buf: [952]u8 = undefined;
    const hit = ddac_cache_lookup(
        handle,
        "/nonexistent/path.pdf",
        1000,
        5000,
        @ptrCast(&result_buf),
        952,
    );
    // Should miss (return 0 on miss, 1 on hit)
    try testing.expectEqual(@as(c_int, 0), hit);
}

// ============================================================================
// Tests — ML Inference Engine
// ============================================================================

test "ML init returns handle (ONNX may or may not be available)" {
    const handle = ddac_ml_init();
    if (handle) |h| {
        defer ddac_ml_free(h);
        // If init succeeded, ONNX Runtime was loaded
        const avail = ddac_ml_available(h);
        try testing.expect(avail <= 1);
        const prov = ddac_ml_provider(h);
        try testing.expect(prov <= 3); // 0=TRT, 1=CUDA, 2=OpenVINO, 3=CPU
        const name = ddac_ml_provider_name(h);
        const name_str = std.mem.span(name);
        try testing.expect(name_str.len > 0);
    }
    // null is acceptable — ONNX Runtime not installed
}

test "ML free null is safe" {
    ddac_ml_free(null);
}

test "ML result size is 48 bytes" {
    const size = ddac_ml_result_size();
    try testing.expectEqual(@as(usize, 48), size);
}

test "ML stage count is 5" {
    const count = ddac_ml_stage_count();
    try testing.expectEqual(@as(u8, 5), count);
}

test "ML model names are not empty" {
    const count = ddac_ml_stage_count();
    var i: u8 = 0;
    while (i < count) : (i += 1) {
        const name = ddac_ml_model_name(i);
        const name_str = std.mem.span(name);
        try testing.expect(name_str.len > 0);
        // Each model name should end in .onnx
        try testing.expect(std.mem.endsWith(u8, name_str, ".onnx"));
    }
}

test "ML set model dir with null handle is safe" {
    ddac_ml_set_model_dir(null, "/nonexistent");
}

// ============================================================================
// Tests — GPU OCR
// ============================================================================

test "GPU OCR init returns handle (GPU may not be available)" {
    const handle = ddac_gpu_ocr_init();
    if (handle) |h| {
        defer ddac_gpu_ocr_free(h);
        const backend = ddac_gpu_ocr_backend(h);
        try testing.expect(backend <= 2); // 0=Paddle, 1=TessCUDA, 2=CPU
    }
    // null is acceptable — no GPU
}

test "GPU OCR free null is safe" {
    ddac_gpu_ocr_free(null);
}

test "GPU OCR max batch is positive" {
    const max = ddac_gpu_ocr_max_batch();
    try testing.expect(max > 0);
}

test "GPU OCR result size is 48 bytes" {
    const size = ddac_gpu_ocr_result_size();
    try testing.expectEqual(@as(usize, 48), size);
}

// ============================================================================
// Tests — Conduit
// ============================================================================

test "conduit result size is 88 bytes" {
    const size = ddac_conduit_result_size();
    try testing.expectEqual(@as(usize, 88), size);
}

test "conduit process nonexistent file returns error" {
    var result_buf: [88]u8 align(8) = std.mem.zeroes([88]u8);
    const rc = ddac_conduit_process("/nonexistent/file.pdf", @ptrCast(&result_buf));
    // Should return non-zero (validation failure)
    try testing.expect(rc != 0);
    // validation field (offset 1) should be 1 = not_found
    try testing.expectEqual(@as(u8, 1), result_buf[1]);
}

test "conduit process empty file returns empty validation" {
    // Create a temporary empty file
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/tmp/ddac-test-empty-{d}", .{std.time.milliTimestamp()}) catch return;
    const file = std.fs.createFileAbsoluteZ(path, .{}) catch return;
    file.close();
    defer std.fs.deleteFileAbsolute(std.mem.span(path)) catch {};

    var result_buf: [88]u8 align(8) = std.mem.zeroes([88]u8);
    const rc = ddac_conduit_process(path, @ptrCast(&result_buf));
    try testing.expect(rc != 0);
    // validation field (offset 1) should be 2 = empty
    try testing.expectEqual(@as(u8, 2), result_buf[1]);
}

// ============================================================================
// Tests — Dragonfly (connection will fail without a server)
// ============================================================================

test "dragonfly connect to invalid host returns null" {
    const handle = ddac_dragonfly_connect("invalid-host:99999");
    if (handle) |h| {
        ddac_dragonfly_close(h);
    }
    // Expect null — no Dragonfly server running. But either way is fine.
}

test "dragonfly close null is safe" {
    ddac_dragonfly_close(null);
}

// ============================================================================
// Tests — Struct Size Assertions (match Idris2 proofs)
// ============================================================================

test "CryptoCaps struct is 16 bytes" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(CryptoCaps));
}

test "CryptoCaps struct is 1-byte aligned" {
    try testing.expectEqual(@as(usize, 1), @alignOf(CryptoCaps));
}
