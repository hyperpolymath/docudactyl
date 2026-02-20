// Docudactyl FFI Integration Tests
//
// Verify that the Zig FFI correctly implements the C ABI declared in
// ffi/zig/include/docudactyl_ffi.h and proven in src/abi/.
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

const std = @import("std");
const testing = std.testing;

// Import FFI functions via C ABI
extern fn ddac_init() ?*anyopaque;
extern fn ddac_free(?*anyopaque) void;
extern fn ddac_version() [*:0]const u8;

// ddac_parse returns a struct by value — for integration tests we test
// the simpler lifecycle/version functions. Full parse tests require
// real files on disk (see scale test via Chapel).

//==============================================================================
// Lifecycle Tests
//==============================================================================

test "create and destroy handle" {
    const handle = ddac_init() orelse return error.InitFailed;
    defer ddac_free(handle);

    try testing.expect(handle != null);
}

test "free null is safe" {
    ddac_free(null); // Must not crash
}

test "multiple handles are independent" {
    const h1 = ddac_init() orelse return error.InitFailed;
    defer ddac_free(h1);

    const h2 = ddac_init() orelse return error.InitFailed;
    defer ddac_free(h2);

    try testing.expect(h1 != h2);
}

//==============================================================================
// Version Tests
//==============================================================================

test "version string is not empty" {
    const ver = ddac_version();
    const ver_str = std.mem.span(ver);

    try testing.expect(ver_str.len > 0);
}

test "version string is semantic version format" {
    const ver = ddac_version();
    const ver_str = std.mem.span(ver);

    // Should be in format X.Y.Z (at least one dot)
    try testing.expect(std.mem.count(u8, ver_str, ".") >= 1);
}

test "version is 0.1.0" {
    const ver = ddac_version();
    const ver_str = std.mem.span(ver);

    try testing.expectEqualStrings("0.1.0", ver_str);
}
