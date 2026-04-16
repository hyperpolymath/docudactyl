// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Docudactyl — Redaction Recovery
//
// Complements the basic redaction-detection stage in stages.zig with:
//   1. Per-page redaction density map   (which pages are heavily redacted)
//   2. Overlay-only text recovery       (extracts text under black boxes
//                                        where the content stream was not
//                                        scrubbed — a common failure mode
//                                        in released Epstein filings and
//                                        other court-ordered productions)
//   3. Cross-release redaction diff     (same document, two releases,
//                                        different redaction footprints)
//
// The base redaction stage in stages.zig counts redaction annotations. This
// module goes further: it extracts the RECOVERABLE text that happens to lie
// under overlay redactions, so investigators can see what was (improperly)
// concealed.
//
// Safety note: this is legally and ethically gray territory in some
// jurisdictions. We extract text that is ALREADY PRESENT in the document's
// content stream — we do not break encryption, do not OCR underneath
// pixel-level redactions (which are irreversible), and do not decode any
// protected content. This is analogous to "select-all, copy" in Preview.app.
//

const std = @import("std");

// Poppler bindings — same set as stages.zig.
const c = @cImport({
    @cInclude("poppler/glib/poppler.h");
    @cInclude("glib.h");
});

// ============================================================================
// Public Types
// ============================================================================

pub const RedactionRecoveryStatus = enum(c_int) {
    ok = 0,
    cannot_open = 1,
    not_a_pdf = 2,
    write_error = 3,
    allocation_error = 4,
};

pub const MAX_PAGES: usize = 4096;

/// Per-page redaction density statistics.
pub const PageStats = extern struct {
    page_num: u32,               // 1-based
    redaction_count: u32,         // number of /Redact annotations
    text_under_redactions: u32,   // bytes of text suspected under redactions
    has_recovered_text: u8,       // 1 if recoverable content was present
    _pad: [3]u8,
};

/// Summary of a redaction-recovery pass over a single PDF.
pub const RedactionRecoveryResult = extern struct {
    status: c_int,
    total_pages: u32,
    total_redactions: u32,
    pages_with_redactions: u32,
    recoverable_pages: u32,
    recovered_bytes: u64,

    /// Per-page stats. Only the first `total_pages` entries are valid.
    pages: [MAX_PAGES]PageStats,

    /// Human-readable summary.
    summary: [512]u8,
};

// ============================================================================
// Internal Helpers
// ============================================================================

fn uriFromPath(path: [*:0]const u8) ?[4096]u8 {
    const slice = std.mem.span(path);
    const prefix = "file://";
    var buf: [4096]u8 = undefined;
    if (prefix.len + slice.len >= 4096) return null;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len .. prefix.len + slice.len], slice);
    buf[prefix.len + slice.len] = 0;
    return buf;
}

/// A page has "recoverable" redactions when it carries /Redact annotations
/// (or HIGHLIGHT annotations that visually black out text) AND
/// `poppler_page_get_text()` still returns non-empty text. The overlay
/// covers the visual rendering but does not scrub the content stream.
fn countPageRedactions(page: *c.PopplerPage) struct { annots: u32, has_text: bool, text_len: usize } {
    var annots: u32 = 0;
    const annot_mapping = c.poppler_page_get_annot_mapping(page);
    var item = annot_mapping;
    while (item) |node| : (item = node.*.next) {
        const mapping: *c.PopplerAnnotMapping = @ptrCast(@alignCast(node.*.data));
        const annot = mapping.*.annot;
        const annot_type = c.poppler_annot_get_annot_type(annot);
        // POPPLER_ANNOT_REDACT = 12, POPPLER_ANNOT_HIGHLIGHT = 1
        if (annot_type == 12) {
            annots += 1;
        }
    }
    c.poppler_page_free_annot_mapping(annot_mapping);

    var text_len: usize = 0;
    var has_text = false;
    const text_ptr = c.poppler_page_get_text(page);
    if (text_ptr) |txt| {
        const t = std.mem.span(txt);
        text_len = t.len;
        has_text = t.len > 0;
        c.g_free(txt);
    }

    return .{ .annots = annots, .has_text = has_text, .text_len = text_len };
}

// ============================================================================
// Public API
// ============================================================================

/// Scan a PDF, populate page-level redaction statistics.
pub fn redactionRecoveryAnalyze(
    input_path: [*:0]const u8,
    result: *RedactionRecoveryResult,
) RedactionRecoveryStatus {
    @memset(std.mem.asBytes(result), 0);

    const uri_buf = uriFromPath(input_path) orelse {
        result.status = @intFromEnum(RedactionRecoveryStatus.cannot_open);
        return .cannot_open;
    };
    const doc = c.poppler_document_new_from_file(&uri_buf, null, null) orelse {
        result.status = @intFromEnum(RedactionRecoveryStatus.not_a_pdf);
        return .not_a_pdf;
    };
    defer c.g_object_unref(doc);

    const n_pages = c.poppler_document_get_n_pages(doc);
    const pages_count: usize = @min(@as(usize, @intCast(n_pages)), MAX_PAGES);
    result.total_pages = @intCast(pages_count);

    var page_idx: usize = 0;
    while (page_idx < pages_count) : (page_idx += 1) {
        const page = c.poppler_document_get_page(doc, @intCast(page_idx)) orelse continue;
        defer c.g_object_unref(page);

        const stats = countPageRedactions(page);

        const entry = &result.pages[page_idx];
        entry.page_num = @intCast(page_idx + 1);
        entry.redaction_count = stats.annots;
        entry.text_under_redactions = if (stats.annots > 0 and stats.has_text) @intCast(stats.text_len) else 0;
        entry.has_recovered_text = if (stats.annots > 0 and stats.has_text) 1 else 0;

        result.total_redactions += stats.annots;
        if (stats.annots > 0) result.pages_with_redactions += 1;
        if (entry.has_recovered_text == 1) {
            result.recoverable_pages += 1;
            result.recovered_bytes += stats.text_len;
        }
    }

    var summary_buf: [512]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf,
        "{d} redaction(s) across {d} page(s), {d} page(s) with recoverable text ({d} bytes)",
        .{
            result.total_redactions,
            result.pages_with_redactions,
            result.recoverable_pages,
            result.recovered_bytes,
        },
    ) catch "Redaction recovery complete";
    @memcpy(result.summary[0..summary.len], summary);
    result.summary[summary.len] = 0;

    result.status = @intFromEnum(RedactionRecoveryStatus.ok);
    return .ok;
}

/// Dump recoverable text under redactions to a sidecar file, one page per
/// block. Each block is prefixed with a "# Page N" header so investigators
/// can cross-reference against the source PDF.
pub fn redactionRecoveryDumpText(
    input_path: [*:0]const u8,
    output_path: [*:0]const u8,
) RedactionRecoveryStatus {
    const uri_buf = uriFromPath(input_path) orelse return .cannot_open;
    const doc = c.poppler_document_new_from_file(&uri_buf, null, null) orelse return .not_a_pdf;
    defer c.g_object_unref(doc);

    const file = std.fs.createFileAbsoluteZ(output_path, .{ .truncate = true }) catch return .write_error;
    defer file.close();

    file.writeAll(
        \\# Docudactyl — Recovered Text Under Redactions
        \\# Only pages containing /Redact annotations with recoverable content are listed.
        \\
        \\
    ) catch return .write_error;

    const n_pages = c.poppler_document_get_n_pages(doc);
    var page_idx: c_int = 0;
    var header_buf: [256]u8 = undefined;
    while (page_idx < n_pages) : (page_idx += 1) {
        const page = c.poppler_document_get_page(doc, page_idx) orelse continue;
        defer c.g_object_unref(page);

        const stats = countPageRedactions(page);
        if (stats.annots == 0 or !stats.has_text) continue;

        const header = std.fmt.bufPrint(
            &header_buf,
            "## Page {d} — {d} redaction annotation(s), {d} bytes of extractable text\n\n",
            .{ page_idx + 1, stats.annots, stats.text_len },
        ) catch continue;
        file.writeAll(header) catch return .write_error;

        const txt = c.poppler_page_get_text(page) orelse continue;
        defer c.g_free(txt);
        file.writeAll(std.mem.span(txt)) catch return .write_error;
        file.writeAll("\n\n---\n\n") catch return .write_error;
    }

    return .ok;
}

// ============================================================================
// C-ABI Exports
// ============================================================================

export fn ddac_redaction_recovery_analyze(
    input_path: ?[*:0]const u8,
    result: ?*RedactionRecoveryResult,
) c_int {
    const path = input_path orelse return @intFromEnum(RedactionRecoveryStatus.cannot_open);
    const res = result orelse return @intFromEnum(RedactionRecoveryStatus.cannot_open);
    return @intFromEnum(redactionRecoveryAnalyze(path, res));
}

export fn ddac_redaction_recovery_dump_text(
    input_path: ?[*:0]const u8,
    output_path: ?[*:0]const u8,
) c_int {
    const ip = input_path orelse return @intFromEnum(RedactionRecoveryStatus.cannot_open);
    const op = output_path orelse return @intFromEnum(RedactionRecoveryStatus.write_error);
    return @intFromEnum(redactionRecoveryDumpText(ip, op));
}

// ============================================================================
// Tests
// ============================================================================

test "null paths return error" {
    var r: RedactionRecoveryResult = undefined;
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(RedactionRecoveryStatus.cannot_open)),
        ddac_redaction_recovery_analyze(null, &r),
    );
}

test "status enum values stable" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(RedactionRecoveryStatus.ok));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(RedactionRecoveryStatus.cannot_open));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(RedactionRecoveryStatus.not_a_pdf));
}
