// Docudactyl FFI Build Configuration
//
// Builds libdocudactyl_ffi.so (shared) and libdocudactyl_ffi.a (static)
// Links against: poppler-glib, tesseract, FFmpeg, libxml2, GDAL, libvips
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Shared library (.so / .dylib / .dll) ────────────────────────────
    const lib = b.addSharedLibrary(.{
        .name = "docudactyl_ffi",
        .root_source_file = b.path("src/docudactyl_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.version = .{ .major = 0, .minor = 1, .patch = 0 };
    linkCLibraries(lib);

    // ── Static library (.a) ─────────────────────────────────────────────
    const lib_static = b.addStaticLibrary(.{
        .name = "docudactyl_ffi",
        .root_source_file = b.path("src/docudactyl_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkCLibraries(lib_static);

    // Install both artifacts
    b.installArtifact(lib);
    b.installArtifact(lib_static);

    // ── Unit tests ──────────────────────────────────────────────────────
    const lib_tests = b.addTest(.{
        .root_source_file = b.path("src/docudactyl_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkCLibraries(lib_tests);

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);

    // ── Integration tests ───────────────────────────────────────────────
    const integration_tests = b.addTest(.{
        .root_source_file = b.path("test/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests.linkLibrary(lib);
    linkCLibraries(integration_tests);

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // ── Documentation ───────────────────────────────────────────────────
    const docs = b.addTest(.{
        .root_source_file = b.path("src/docudactyl_ffi.zig"),
        .target = target,
        .optimize = .Debug,
    });
    linkCLibraries(docs);

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
}

/// Link all required C libraries against a compile step.
/// These are the native parsers that Zig wraps:
///   PDF:        poppler-glib (depends on glib-2.0, gobject-2.0, gio-2.0)
///   OCR:        tesseract, leptonica
///   Audio/Video: avformat, avcodec, avutil
///   EPUB/XML:   xml2
///   Geospatial: gdal
///   Images:     vips
fn linkCLibraries(step: *std.Build.Step.Compile) void {
    step.linkLibC();

    // Poppler (PDF)
    step.linkSystemLibrary("poppler-glib");
    step.linkSystemLibrary("glib-2.0");
    step.linkSystemLibrary("gobject-2.0");

    // Tesseract (OCR) + Leptonica (image I/O for Tesseract)
    step.linkSystemLibrary("tesseract");
    step.linkSystemLibrary("lept");

    // FFmpeg (audio/video)
    step.linkSystemLibrary("libavformat");
    step.linkSystemLibrary("libavcodec");
    step.linkSystemLibrary("libavutil");

    // libxml2 (EPUB/XHTML)
    step.linkSystemLibrary("libxml-2.0");

    // GDAL (geospatial)
    step.linkSystemLibrary("gdal");

    // libvips (image metadata)
    step.linkSystemLibrary("vips");
}
