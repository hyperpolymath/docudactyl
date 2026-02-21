// Docudactyl FFI Build Configuration
//
// Builds libdocudactyl_ffi.so (shared) and libdocudactyl_ffi.a (static)
// Links against: poppler-glib, tesseract, FFmpeg, libxml2, GDAL, libvips, lmdb
//
// Requires Zig 0.15+
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Root module (shared between library and test builds) ────────
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/docudactyl_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkCLibrariesOnModule(root_module);

    // ── Shared library (.so / .dylib / .dll) ────────────────────────
    const lib = b.addLibrary(.{
        .name = "docudactyl_ffi",
        .root_module = root_module,
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 4, .patch = 0 },
    });
    b.installArtifact(lib);

    // ── Static library (.a) ─────────────────────────────────────────
    const static_module = b.createModule(.{
        .root_source_file = b.path("src/docudactyl_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkCLibrariesOnModule(static_module);

    const lib_static = b.addLibrary(.{
        .name = "docudactyl_ffi",
        .root_module = static_module,
        .linkage = .static,
    });
    b.installArtifact(lib_static);

    // ── Unit tests ──────────────────────────────────────────────────
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/docudactyl_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkCLibrariesOnModule(test_module);

    const lib_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);

    // ── Integration tests (test/integration_test.zig) ─────────────
    // These test the C ABI by calling exported ddac_* functions via
    // extern fn — they link against the built shared library.
    const integ_module = b.createModule(.{
        .root_source_file = b.path("test/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkCLibrariesOnModule(integ_module);
    // Link the FFI library itself so extern fn ddac_* symbols resolve
    integ_module.addLibraryPath(lib.getEmittedBinDirectory());
    integ_module.addRPath(lib.getEmittedBinDirectory());
    integ_module.linkLibrary(lib);

    const integ_tests = b.addTest(.{
        .root_module = integ_module,
    });

    const run_integ_tests = b.addRunArtifact(integ_tests);
    run_integ_tests.step.dependOn(&lib.step); // ensure lib is built first
    const integ_step = b.step("test-integration", "Run integration tests (C ABI)");
    integ_step.dependOn(&run_integ_tests.step);

    // Make `zig build test` run both unit and integration tests
    test_step.dependOn(&run_integ_tests.step);

    // ── Documentation ───────────────────────────────────────────────
    const docs_module = b.createModule(.{
        .root_source_file = b.path("src/docudactyl_ffi.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    linkCLibrariesOnModule(docs_module);

    const docs = b.addTest(.{
        .root_module = docs_module,
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
}

/// Link all required C libraries on a Module.
/// These are the native parsers that Zig wraps.
fn linkCLibrariesOnModule(module: *std.Build.Module) void {
    // Poppler (PDF)
    module.linkSystemLibrary("poppler-glib", .{});
    module.linkSystemLibrary("glib-2.0", .{});
    module.linkSystemLibrary("gobject-2.0", .{});

    // Tesseract (OCR) + Leptonica (image I/O for Tesseract)
    module.linkSystemLibrary("tesseract", .{});
    module.linkSystemLibrary("lept", .{});

    // FFmpeg (audio/video)
    module.linkSystemLibrary("libavformat", .{});
    module.linkSystemLibrary("libavcodec", .{});
    module.linkSystemLibrary("libavutil", .{});

    // libxml2 (EPUB/XHTML)
    module.linkSystemLibrary("libxml-2.0", .{});

    // GDAL (geospatial)
    module.linkSystemLibrary("gdal", .{});

    // libvips (image metadata)
    module.linkSystemLibrary("vips", .{});

    // LMDB (result cache — zero-copy reads, ACID, multi-reader)
    module.linkSystemLibrary("lmdb", .{});
}
