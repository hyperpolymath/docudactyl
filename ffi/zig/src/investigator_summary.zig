// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Docudactyl — Investigator-Friendly JSON Summary Writer
//
// The HPC pipeline emits Cap'n Proto binary per-document stage results
// (schema/stages.capnp). That format is excellent for machines but opaque
// to citizen journalists working with spreadsheets or text editors.
//
// This module builds a plain, self-contained, human-readable JSON summary
// from an in-memory `InvestigatorSummary` struct that callers populate
// directly (either from their own extraction pass or by transcoding the
// Cap'n Proto output). The JSON schema is intentionally flat and
// forgiving — any field can be absent/zero without breaking readers.
//
// Target schema (example):
//   {
//     "document_id": "sha256:abcd...",
//     "source_path": "/data/release_2024/doc_0042.pdf",
//     "content_kind": "pdf",
//     "page_count": 184,
//     "sha256": "abcd...",
//     "redactions": { "count": 12, "pages_affected": 4, "recoverable": true },
//     "entities": {
//        "persons": ["Jeffrey Epstein", "Ghislaine Maxwell"],
//        "tail_numbers": ["N908JE"],
//        "airports": ["TEB", "PBI", "KTEB"],
//        "phones": ["+1 212 555 1234"],
//        "addresses": ["9 East 71st Street"]
//     },
//     "financial": { "amounts": 3, "accounts": 1 },
//     "legal": { "case_citations": 5, "dockets": 2, "statutes": 1 },
//     "speakers": { "count": 2, "is_deposition": true },
//     "evasion": { "total": 17, "per_1k_tokens": 12.5 },
//     "flags": ["has_redactions", "has_recoverable_text", "deposition"]
//   }
//

const std = @import("std");

// ============================================================================
// Public Types
// ============================================================================

pub const SummaryStatus = enum(c_int) {
    ok = 0,
    write_error = 1,
    invalid_input = 2,
};

/// Maximum strings in an exported list.
pub const MAX_LIST_ITEMS: usize = 64;
pub const MAX_ITEM_LEN: usize = 128;
pub const MAX_PATH_LEN: usize = 1024;
pub const MAX_KIND_LEN: usize = 16;
pub const MAX_SHA_LEN: usize = 80;

/// Flat list of null-terminated strings in a fixed buffer (for C ABI).
pub const StringList = extern struct {
    count: u32,
    items: [MAX_LIST_ITEMS][MAX_ITEM_LEN]u8,
};

/// Complete summary for one document. Caller fills this in; the writer
/// emits JSON to a file or buffer.
pub const InvestigatorSummary = extern struct {
    // Identification
    source_path: [MAX_PATH_LEN]u8,
    content_kind: [MAX_KIND_LEN]u8,
    sha256: [MAX_SHA_LEN]u8,

    // Scalar metadata
    page_count: u32,
    word_count: u64,
    char_count: u64,
    duration_sec_x1000: u64, // fixed-point milliseconds for audio/video

    // Redactions (from stageRedactionDetect + redaction_recovery)
    redaction_count: u32,
    redacted_pages: u32,
    recoverable_pages: u32,

    // Financial (from stageFinancialExtract)
    financial_amounts: u32,
    financial_accounts: u32,

    // Legal NER (from stageLegalNer)
    legal_case_citations: u32,
    legal_dockets: u32,
    legal_statutes: u32,

    // Flight log (from flight_log)
    tail_number_count: u32,
    iata_count: u32,
    icao_count: u32,
    phone_count: u32,
    address_count: u32,

    // Entity lists
    persons: StringList,
    tail_numbers: StringList,
    airports: StringList,
    phones: StringList,
    addresses: StringList,

    // Deposition / speaker data
    speaker_count: u32,
    is_deposition: u8,
    _pad1: [3]u8,

    // Evasion detection
    evasion_total: u32,
    evasion_per_1k_x1000: u32, // fixed-point: rate × 1000
};

// ============================================================================
// Helpers
// ============================================================================

fn nullTerminated(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            0...7, 0x0B, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{ch}),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

fn writeList(writer: anytype, name: []const u8, list: *const StringList) !void {
    try writer.print("    \"{s}\": [", .{name});
    var i: u32 = 0;
    while (i < list.count and i < MAX_LIST_ITEMS) : (i += 1) {
        if (i != 0) try writer.writeAll(", ");
        const item = nullTerminated(&list.items[i]);
        try writeJsonString(writer, item);
    }
    try writer.writeAll("]");
}

fn writeFlags(writer: anytype, s: *const InvestigatorSummary) !void {
    try writer.writeAll("  \"flags\": [");
    var first = true;

    inline for (.{
        .{ "has_redactions", s.redaction_count > 0 },
        .{ "has_recoverable_text", s.recoverable_pages > 0 },
        .{ "has_financial_data", s.financial_amounts > 0 or s.financial_accounts > 0 },
        .{ "has_legal_refs", s.legal_case_citations > 0 or s.legal_dockets > 0 or s.legal_statutes > 0 },
        .{ "deposition", s.is_deposition == 1 },
        .{ "has_flight_data", s.tail_number_count > 0 or s.iata_count > 0 or s.icao_count > 0 },
        .{ "high_evasion", s.evasion_per_1k_x1000 > 20_000 },
    }) |entry| {
        if (entry[1]) {
            if (!first) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{entry[0]});
            first = false;
        }
    }
    try writer.writeAll("]");
}

// ============================================================================
// Public API
// ============================================================================

/// Write the summary as JSON to `writer`.
pub fn writeJson(writer: anytype, s: *const InvestigatorSummary) !void {
    const src_path = nullTerminated(&s.source_path);
    const kind = nullTerminated(&s.content_kind);
    const sha = nullTerminated(&s.sha256);

    try writer.writeAll("{\n");

    try writer.writeAll("  \"source_path\": ");
    try writeJsonString(writer, src_path);
    try writer.writeAll(",\n");

    try writer.writeAll("  \"content_kind\": ");
    try writeJsonString(writer, kind);
    try writer.writeAll(",\n");

    try writer.writeAll("  \"sha256\": ");
    try writeJsonString(writer, sha);
    try writer.writeAll(",\n");

    try writer.print("  \"page_count\": {d},\n", .{s.page_count});
    try writer.print("  \"word_count\": {d},\n", .{s.word_count});
    try writer.print("  \"char_count\": {d},\n", .{s.char_count});

    if (s.duration_sec_x1000 > 0) {
        const sec: f64 = @as(f64, @floatFromInt(s.duration_sec_x1000)) / 1000.0;
        try writer.print("  \"duration_sec\": {d:.3},\n", .{sec});
    }

    try writer.print(
        "  \"redactions\": {{\"count\": {d}, \"pages_affected\": {d}, \"recoverable_pages\": {d}}},\n",
        .{ s.redaction_count, s.redacted_pages, s.recoverable_pages },
    );

    try writer.print(
        "  \"financial\": {{\"amounts\": {d}, \"accounts\": {d}}},\n",
        .{ s.financial_amounts, s.financial_accounts },
    );

    try writer.print(
        "  \"legal\": {{\"case_citations\": {d}, \"dockets\": {d}, \"statutes\": {d}}},\n",
        .{ s.legal_case_citations, s.legal_dockets, s.legal_statutes },
    );

    try writer.print(
        "  \"speakers\": {{\"count\": {d}, \"is_deposition\": {s}}},\n",
        .{ s.speaker_count, if (s.is_deposition == 1) "true" else "false" },
    );

    const rate: f64 = @as(f64, @floatFromInt(s.evasion_per_1k_x1000)) / 1000.0;
    try writer.print(
        "  \"evasion\": {{\"total\": {d}, \"per_1k_tokens\": {d:.3}}},\n",
        .{ s.evasion_total, rate },
    );

    try writer.writeAll("  \"entities\": {\n");
    try writeList(writer, "persons", &s.persons);
    try writer.writeAll(",\n");
    try writeList(writer, "tail_numbers", &s.tail_numbers);
    try writer.writeAll(",\n");
    try writeList(writer, "airports", &s.airports);
    try writer.writeAll(",\n");
    try writeList(writer, "phones", &s.phones);
    try writer.writeAll(",\n");
    try writeList(writer, "addresses", &s.addresses);
    try writer.writeAll("\n  },\n");

    try writeFlags(writer, s);
    try writer.writeAll("\n}\n");
}

/// Write the summary to a file.
pub fn writeJsonFile(path: [*:0]const u8, s: *const InvestigatorSummary) SummaryStatus {
    // A fully-populated summary fits comfortably in 64 KB.
    var buf: [65536]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    writeJson(stream.writer(), s) catch return .write_error;

    const file = std.fs.createFileAbsoluteZ(path, .{ .truncate = true }) catch return .write_error;
    defer file.close();
    file.writeAll(stream.getWritten()) catch return .write_error;
    return .ok;
}

// ============================================================================
// C-ABI Exports
// ============================================================================

export fn ddac_investigator_summary_write(
    output_path: ?[*:0]const u8,
    summary: ?*const InvestigatorSummary,
) c_int {
    const path = output_path orelse return @intFromEnum(SummaryStatus.invalid_input);
    const s = summary orelse return @intFromEnum(SummaryStatus.invalid_input);
    return @intFromEnum(writeJsonFile(path, s));
}

/// Helper for callers that want to populate a StringList slot from C.
/// `idx` is the slot to write. Returns 0 on success, 1 on out-of-bounds.
export fn ddac_investigator_summary_set_list_item(
    list: ?*StringList,
    idx: u32,
    text_ptr: ?[*]const u8,
    text_len: usize,
) c_int {
    const l = list orelse return 1;
    if (idx >= MAX_LIST_ITEMS) return 1;
    const text = if (text_ptr) |p| p[0..text_len] else return 1;
    @memset(&l.items[idx], 0);
    const copy_len = @min(text.len, MAX_ITEM_LEN - 1);
    @memcpy(l.items[idx][0..copy_len], text[0..copy_len]);
    if (idx + 1 > l.count) l.count = idx + 1;
    return 0;
}

// ============================================================================
// Tests
// ============================================================================

test "emit minimal summary" {
    var s: InvestigatorSummary = std.mem.zeroes(InvestigatorSummary);
    const path = "/tmp/test_doc.pdf";
    @memcpy(s.source_path[0..path.len], path);
    const kind = "pdf";
    @memcpy(s.content_kind[0..kind.len], kind);
    const sha = "abcd1234";
    @memcpy(s.sha256[0..sha.len], sha);
    s.page_count = 42;
    s.redaction_count = 3;
    s.recoverable_pages = 1;

    var buf: [16384]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeJson(stream.writer(), &s);
    const written = stream.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, written, "\"page_count\": 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"has_redactions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"has_recoverable_text\"") != null);
}

test "set list item via C-ABI helper" {
    var list: StringList = std.mem.zeroes(StringList);
    const name = "Jeffrey Epstein";
    const rc = ddac_investigator_summary_set_list_item(&list, 0, name.ptr, name.len);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expectEqual(@as(u32, 1), list.count);
    const stored = nullTerminated(&list.items[0]);
    try std.testing.expectEqualStrings(name, stored);
}

test "json string escaping" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeJsonString(stream.writer(), "quote\"backslash\\newline\n");
    const written = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\\\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\\n") != null);
}

test "deposition flag emitted" {
    var s: InvestigatorSummary = std.mem.zeroes(InvestigatorSummary);
    s.is_deposition = 1;
    s.evasion_per_1k_x1000 = 30_000; // triggers high_evasion flag
    var buf: [16384]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeJson(stream.writer(), &s);
    const written = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"deposition\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"high_evasion\"") != null);
}
