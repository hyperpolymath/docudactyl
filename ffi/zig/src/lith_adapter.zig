// Docudactyl → Lithoglyph Ingest Adapter
//
// Reads a Cap'n Proto StageResults message buffer and converts it to a JSON
// evidence record compatible with Lithoglyph's bofig_evidence schema.
//
// The adapter extracts fields from the Cap'n Proto binary layout defined in
// capnp.zig, maps them to Lithoglyph schema fields, and computes auto-PROMPT
// epistemological scores from extraction metadata.
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

const std = @import("std");
const capnp = @import("capnp.zig");
const stages = @import("stages.zig");

// ============================================================================
// Cap'n Proto Reader — Zero-Copy Struct Access
// ============================================================================
//
// Reads fields directly from a Cap'n Proto single-segment message buffer.
// The message format is: 8-byte header + root struct pointer + data + pointers.

/// Reads a StageResults struct from a raw Cap'n Proto message buffer.
/// The buffer includes the 8-byte segment header followed by the segment data.
pub const Reader = struct {
    /// Pointer to the start of the segment data (after the 8-byte message header).
    seg: [*]const u8,
    /// Length of the segment in bytes.
    seg_len: usize,
    /// Byte offset of the root struct's data section within the segment.
    data_start: usize,
    /// Byte offset of the root struct's pointer section within the segment.
    ptr_start: usize,

    /// Initialise a reader from a complete Cap'n Proto message buffer
    /// (8-byte header + segment data).
    ///
    /// Returns null if the buffer is too small or the root pointer is invalid.
    pub fn init(msg: []const u8) ?Reader {
        // Minimum: 8 header + 8 root ptr + at least one data word
        if (msg.len < 24) return null;

        // Skip 8-byte message header (segment count + segment size).
        const seg = msg.ptr + 8;
        const seg_len = msg.len - 8;

        // Root struct pointer is at segment word 0.
        // For StageResults the root pointer has offset=0 (struct starts at word 1).
        // Data section starts immediately after the root pointer word.
        const data_start: usize = 8; // word 1 of segment
        const ptr_start: usize = data_start + @as(usize, capnp.DATA_WORDS) * 8;

        // Sanity: the pointer section must fit within the segment.
        const min_size = ptr_start + @as(usize, capnp.PTR_WORDS) * 8;
        if (seg_len < min_size) return null;

        return .{
            .seg = seg,
            .seg_len = seg_len,
            .data_start = data_start,
            .ptr_start = ptr_start,
        };
    }

    // ── Data section readers ────────────────────────────────────────────

    pub fn readU64(self: Reader, off: usize) u64 {
        const abs = self.data_start + off;
        if (abs + 8 > self.seg_len) return 0;
        return std.mem.readInt(u64, @as(*const [8]u8, @ptrCast(self.seg + abs)), .little);
    }

    pub fn readU32(self: Reader, off: usize) u32 {
        const abs = self.data_start + off;
        if (abs + 4 > self.seg_len) return 0;
        return std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(self.seg + abs)), .little);
    }

    pub fn readI32(self: Reader, off: usize) i32 {
        return @bitCast(self.readU32(off));
    }

    pub fn readF64(self: Reader, off: usize) f64 {
        return @bitCast(self.readU64(off));
    }

    // ── Pointer section readers ─────────────────────────────────────────

    /// Read a Text field from a pointer slot. Returns the text bytes (without
    /// the null terminator) or an empty slice if the pointer is null/invalid.
    pub fn readText(self: Reader, ptr_idx: usize) []const u8 {
        const ptr_off = self.ptr_start + ptr_idx * 8;
        if (ptr_off + 8 > self.seg_len) return &.{};

        const raw = std.mem.readInt(u64, @as(*const [8]u8, @ptrCast(self.seg + ptr_off)), .little);

        // Null pointer check.
        if (raw == 0) return &.{};

        // Decode list pointer: bits 0-1 must be 1 (list type).
        if (raw & 3 != 1) return &.{};

        // Offset (signed, in words) from pointer+1 to list data.
        const offset_raw: i32 = @bitCast(@as(u32, @truncate(raw >> 2)));
        const ptr_word = ptr_off / 8;
        const target_word: usize = @intCast(@as(i64, @intCast(ptr_word)) + 1 + @as(i64, offset_raw));
        const target_off = target_word * 8;

        // Element size (bits 32-34) must be 2 (byte list) for Text.
        const elem_size: u3 = @truncate(@as(u32, @truncate(raw >> 32)));
        if (elem_size != 2) return &.{};

        // Count includes null terminator.
        const count: u29 = @truncate(@as(u32, @truncate(raw >> 35)));
        if (count == 0) return &.{};
        const text_len = @as(usize, count) - 1; // exclude null terminator

        if (target_off + text_len > self.seg_len) return &.{};
        return self.seg[target_off .. target_off + text_len];
    }

    /// Read a List(Text) field from a pointer slot. Returns an iterator-style
    /// slice is not practical here, so we provide a callback-based approach
    /// via writeKeywordsJson.
    fn readListPtrRaw(self: Reader, ptr_idx: usize) struct { base: usize, count: usize } {
        const ptr_off = self.ptr_start + ptr_idx * 8;
        if (ptr_off + 8 > self.seg_len) return .{ .base = 0, .count = 0 };

        const raw = std.mem.readInt(u64, @as(*const [8]u8, @ptrCast(self.seg + ptr_off)), .little);
        if (raw == 0) return .{ .base = 0, .count = 0 };
        if (raw & 3 != 1) return .{ .base = 0, .count = 0 };

        const offset_raw: i32 = @bitCast(@as(u32, @truncate(raw >> 2)));
        const ptr_word = ptr_off / 8;
        const target_word: usize = @intCast(@as(i64, @intCast(ptr_word)) + 1 + @as(i64, offset_raw));
        const target_off = target_word * 8;

        const elem_size: u3 = @truncate(@as(u32, @truncate(raw >> 32)));

        // LIST_POINTER (6) = list of pointers (each element is a pointer to Text).
        if (elem_size != 6) return .{ .base = 0, .count = 0 };

        const count: u29 = @truncate(@as(u32, @truncate(raw >> 35)));
        return .{ .base = target_off, .count = @as(usize, count) };
    }

    /// Read a text element from within a List(Text). The list_base is the byte
    /// offset of the pointer list body; elem_idx is the element index.
    fn readTextFromList(self: Reader, list_base: usize, elem_idx: usize) []const u8 {
        const elem_ptr_off = list_base + elem_idx * 8;
        if (elem_ptr_off + 8 > self.seg_len) return &.{};

        const raw = std.mem.readInt(u64, @as(*const [8]u8, @ptrCast(self.seg + elem_ptr_off)), .little);
        if (raw == 0) return &.{};
        if (raw & 3 != 1) return &.{};

        const offset_raw: i32 = @bitCast(@as(u32, @truncate(raw >> 2)));
        const ptr_word = elem_ptr_off / 8;
        const target_word: usize = @intCast(@as(i64, @intCast(ptr_word)) + 1 + @as(i64, offset_raw));
        const target_off = target_word * 8;

        const elem_size: u3 = @truncate(@as(u32, @truncate(raw >> 32)));
        if (elem_size != 2) return &.{};

        const count: u29 = @truncate(@as(u32, @truncate(raw >> 35)));
        if (count == 0) return &.{};
        const text_len = @as(usize, count) - 1;

        if (target_off + text_len > self.seg_len) return &.{};
        return self.seg[target_off .. target_off + text_len];
    }
};

// ============================================================================
// Evidence Type Detection
// ============================================================================

/// Map PREMIS MIME type to a Lithoglyph bofig_evidence evidence_type value.
/// Covers all 15 evidence types defined in the Lithoglyph OpenAPI spec:
/// court_filing, deposition, testimony, flight_log, financial_record,
/// communication, photograph, video, official_statistics, news_report,
/// document, dataset, interview, affidavit, subpoena, other.
///
/// MIME-only detection is inherently limited — many types (deposition,
/// testimony, affidavit, subpoena, flight_log) share the same MIME as
/// generic documents. Callers should override via investigation context
/// or NER stage output when available.
fn detectEvidenceType(mime: []const u8) []const u8 {
    if (mime.len == 0) return "document";

    // PDF documents — default to "court_filing" as the most common
    // investigative PDF type; callers override via context.
    if (std.mem.startsWith(u8, mime, "application/pdf")) return "court_filing";

    // Images
    if (std.mem.startsWith(u8, mime, "image/")) return "photograph";

    // Video
    if (std.mem.startsWith(u8, mime, "video/")) return "video";

    // Audio (depositions, interviews, testimony recordings)
    if (std.mem.startsWith(u8, mime, "audio/")) return "interview";

    // Spreadsheets / CSV — financial records or datasets
    if (std.mem.startsWith(u8, mime, "text/csv") or
        std.mem.startsWith(u8, mime, "application/vnd.ms-excel") or
        std.mem.startsWith(u8, mime, "application/vnd.openxmlformats-officedocument.spreadsheetml"))
    {
        return "financial_record";
    }

    // Structured data formats — datasets
    if (std.mem.startsWith(u8, mime, "application/json") or
        std.mem.startsWith(u8, mime, "application/xml") or
        std.mem.startsWith(u8, mime, "text/xml") or
        std.mem.startsWith(u8, mime, "application/vnd.openxmlformats-officedocument.presentationml"))
    {
        return "dataset";
    }

    // HTML — news reports or general documents
    if (std.mem.eql(u8, mime, "text/html")) return "news_report";

    // Plain text
    if (std.mem.startsWith(u8, mime, "text/")) return "document";

    // Email / messaging
    if (std.mem.startsWith(u8, mime, "message/")) return "communication";

    return "document";
}

// ============================================================================
// Auto-PROMPT Score Computation
// ============================================================================
//
// PROMPT = Provenance, Replicability, Objectivity, Methodology, Publication, Timeliness
//
// These are heuristic scores derived from extraction metadata. They provide a
// starting point for human analysts to refine. Scores range 0-100.

const PromptScores = struct {
    provenance: u8,
    replicability: u8,
    objective: u8,
    methodology: u8,
    publication: u8,
    transparency: u8,
};

/// Compute auto-PROMPT scores from extraction metadata.
///
/// Arguments:
///   stages_mask  — which processing stages completed successfully
///   ocr_conf     — OCR mean confidence (0-100, or -1 if N/A)
///   evidence_type — detected evidence type string
///   lang_conf    — language detection confidence (0.0-1.0)
fn computePromptScores(
    stages_mask: u64,
    ocr_conf: i32,
    evidence_type: []const u8,
    lang_conf: f64,
) PromptScores {
    var scores: PromptScores = .{
        .provenance = 0,
        .replicability = 0,
        .objective = 50, // Default: requires human assessment
        .methodology = 0,
        .publication = 0,
        .transparency = 50, // Default: requires human assessment of method openness
    };

    // ── Provenance ──────────────────────────────────────────────────────
    // Based on extraction confidence and source type reliability.
    // Higher language confidence → more trustworthy text extraction.
    var prov: u16 = 40; // base score for having been processed at all
    if (lang_conf > 0.9) prov += 20;
    if (lang_conf > 0.7) prov += 10;
    // SHA-256 hash present (exact dedup ran) → integrity verified
    if (stages_mask & stages.STAGE_EXACT_DEDUP != 0) prov += 15;
    // Merkle proof present → tamper evidence
    if (stages_mask & stages.STAGE_MERKLE_PROOF != 0) prov += 10;
    // PREMIS metadata → preservation-grade provenance
    if (stages_mask & stages.STAGE_PREMIS_METADATA != 0) prov += 5;
    scores.provenance = @intCast(@min(prov, 100));

    // ── Replicability ───────────────────────────────────────────────────
    // Based on OCR quality — high confidence means the text extraction is
    // reproducible and verifiable.
    var repl: u16 = 30; // base
    if (ocr_conf >= 0) {
        // OCR ran: scale confidence to a 0-50 bonus
        repl += @intCast(@as(u16, @intCast(@as(u32, @bitCast(@as(i32, @max(ocr_conf, 0)))))) / 2);
    } else {
        // No OCR needed (native text) → highly replicable
        repl += 45;
    }
    // Perceptual hash enables visual comparison replication
    if (stages_mask & stages.STAGE_PERCEPTUAL_HASH != 0) repl += 10;
    scores.replicability = @intCast(@min(repl, 100));

    // ── Objective ──────────────────────────────────────────────────────
    // Default 50. This dimension genuinely requires human assessment of
    // bias and conflicts of interest. We leave it at the midpoint.
    scores.objective = 50;

    // ── Methodology ─────────────────────────────────────────────────────
    // Based on stage completeness. More stages run → better methodology
    // (more thorough extraction pipeline).
    var method: u16 = 20; // base
    var stage_count: u16 = 0;
    var mask = stages_mask;
    while (mask != 0) : (mask >>= 1) {
        if (mask & 1 != 0) stage_count += 1;
    }
    // Each stage adds ~3.3 points (24 stages max → 80 bonus)
    method += stage_count * 80 / stages.STAGE_COUNT;
    scores.methodology = @intCast(@min(method, 100));

    // ── Publication ─────────────────────────────────────────────────────
    // Based on evidence type. Court filings and depositions carry more
    // weight than photographs or general documents.
    if (std.mem.eql(u8, evidence_type, "court_filing")) {
        scores.publication = 95;
    } else if (std.mem.eql(u8, evidence_type, "deposition")) {
        scores.publication = 90;
    } else if (std.mem.eql(u8, evidence_type, "affidavit")) {
        scores.publication = 90;
    } else if (std.mem.eql(u8, evidence_type, "subpoena")) {
        scores.publication = 85;
    } else if (std.mem.eql(u8, evidence_type, "official_statistics")) {
        scores.publication = 85;
    } else if (std.mem.eql(u8, evidence_type, "financial_record")) {
        scores.publication = 75;
    } else if (std.mem.eql(u8, evidence_type, "flight_log")) {
        scores.publication = 70;
    } else if (std.mem.eql(u8, evidence_type, "news_report")) {
        scores.publication = 60;
    } else if (std.mem.eql(u8, evidence_type, "photograph")) {
        scores.publication = 50;
    } else if (std.mem.eql(u8, evidence_type, "video")) {
        scores.publication = 50;
    } else if (std.mem.eql(u8, evidence_type, "interview")) {
        scores.publication = 55;
    } else {
        scores.publication = 45;
    }

    // ── Transparency ──────────────────────────────────────────────────────
    // Default 50. Requires assessment of whether methods/data are openly
    // available. Human override expected.
    scores.transparency = 50;

    return scores;
}

// ============================================================================
// JSON Output Builder
// ============================================================================

/// Maximum output JSON size. bofig_evidence records are moderate-sized;
/// 32 KiB is generous even with long keyword lists.
pub const MAX_JSON_LEN: usize = 32768;

/// Convert a Cap'n Proto StageResults message to a Lithoglyph bofig_evidence
/// JSON record.
///
/// Arguments:
///   msg           — complete Cap'n Proto message buffer (header + segment)
///   source_filename — original document filename (used as title)
///   investigation_id — investigation this evidence belongs to
///   run_id        — Docudactyl pipeline run identifier
///   out_buf       — caller-provided output buffer (at least MAX_JSON_LEN bytes)
///
/// Returns the number of bytes written to out_buf, or null on error.
pub fn stageResultsToJson(
    msg: []const u8,
    source_filename: []const u8,
    investigation_id: []const u8,
    run_id: []const u8,
    out_buf: []u8,
) ?usize {
    const reader = Reader.init(msg) orelse return null;

    var stream = std.io.fixedBufferStream(out_buf);
    var w = stream.writer();

    const stages_mask = reader.readU64(capnp.OFF_STAGES_MASK);

    // ── Extract fields from Cap'n Proto ─────────────────────────────────

    // SHA-256 hash from exact dedup stage (bit 11, PTR index 13)
    const sha256 = reader.readText(capnp.PTR_EXACT_SHA);

    // Perceptual hash from perceptual hash stage (bit 5, PTR index 3)
    const phash = reader.readText(capnp.PTR_PHASH_AHASH);

    // OCR confidence from bit 4 (data word offset OFF_OCR_CONF)
    const ocr_conf = reader.readI32(capnp.OFF_OCR_CONF);

    // Language from language detection stage (bit 0, PTR index 1)
    const language = reader.readText(capnp.PTR_LANG_LANGUAGE);
    const lang_conf = reader.readF64(capnp.OFF_LANG_CONFIDENCE);

    // PREMIS MIME type for evidence type detection (PTR index 8)
    const premis_fmt = reader.readText(capnp.PTR_PREMIS_FMT);

    // Redaction detection (bit 20)
    const redact_status_text = reader.readText(capnp.PTR_REDACT_STATUS);
    const redact_count = reader.readU32(capnp.OFF_REDACT_COUNT);

    // Financial extraction (bit 21)
    const financial_amounts = reader.readU32(capnp.OFF_FINANCIAL_AMOUNTS);
    const financial_accounts = reader.readU32(capnp.OFF_FINANCIAL_ACCOUNTS);

    // Legal NER (bit 22)
    const legal_cases = reader.readU32(capnp.OFF_LEGAL_CASES);
    const legal_dockets = reader.readU32(capnp.OFF_LEGAL_DOCKETS);
    const legal_statutes = reader.readU32(capnp.OFF_LEGAL_STATUTES);

    // ── Derived values ──────────────────────────────────────────────────

    const evidence_type = detectEvidenceType(premis_fmt);

    const prompt = computePromptScores(stages_mask, ocr_conf, evidence_type, lang_conf);

    // Redaction status mapping: Cap'n Proto stores "clean"/"redacted"/"not_applicable"/"error".
    // Lithoglyph schema expects: "clean"/"redacted"/"partially_recovered"/"fully_recovered"/"not_applicable".
    // We pass through directly; "error" maps to "not_applicable" in the JSON.
    const redact_status = if (redact_status_text.len == 0)
        "clean"
    else if (std.mem.eql(u8, redact_status_text, "error"))
        "not_applicable"
    else
        redact_status_text;

    // ── Write JSON ──────────────────────────────────────────────────────

    w.writeAll("{") catch return null;

    writeJsonString(w, "investigation_id", investigation_id) catch return null;
    w.writeAll(",") catch return null;

    writeJsonString(w, "title", source_filename) catch return null;
    w.writeAll(",") catch return null;

    writeJsonString(w, "evidence_type", evidence_type) catch return null;
    w.writeAll(",") catch return null;

    writeJsonString(w, "sha256_hash", sha256) catch return null;
    w.writeAll(",") catch return null;

    if (phash.len > 0) {
        writeJsonString(w, "perceptual_hash", phash) catch return null;
        w.writeAll(",") catch return null;
    }

    if (stages_mask & stages.STAGE_OCR_CONFIDENCE != 0 and ocr_conf >= 0) {
        w.print("\"ocr_confidence\":{d},", .{ocr_conf}) catch return null;
    }

    if (language.len > 0) {
        writeJsonString(w, "language", language) catch return null;
        w.writeAll(",") catch return null;
    }

    writeJsonString(w, "redaction_status", redact_status) catch return null;
    w.writeAll(",") catch return null;

    w.print("\"redaction_count\":{d},", .{redact_count}) catch return null;

    writeJsonString(w, "extraction_run_id", run_id) catch return null;
    w.writeAll(",") catch return null;

    // Keywords from keyword extraction stage (bit 2, PTR index 2 = List(Text))
    w.writeAll("\"keywords\":[") catch return null;
    {
        const kw_list = reader.readListPtrRaw(capnp.PTR_KW_WORDS);
        var first = true;
        for (0..kw_list.count) |i| {
            const kw = reader.readTextFromList(kw_list.base, i);
            if (kw.len == 0) continue;
            if (!first) w.writeAll(",") catch return null;
            w.writeAll("\"") catch return null;
            writeJsonEscaped(w, kw) catch return null;
            w.writeAll("\"") catch return null;
            first = false;
        }
    }
    w.writeAll("],") catch return null;

    // Investigative metadata as a nested object for downstream enrichment
    w.writeAll("\"extraction_metadata\":{") catch return null;
    w.print("\"stages_mask\":{d},", .{stages_mask}) catch return null;
    w.print("\"financial_amounts\":{d},", .{financial_amounts}) catch return null;
    w.print("\"financial_accounts\":{d},", .{financial_accounts}) catch return null;
    w.print("\"legal_case_citations\":{d},", .{legal_cases}) catch return null;
    w.print("\"legal_docket_refs\":{d},", .{legal_dockets}) catch return null;
    w.print("\"legal_statute_refs\":{d}", .{legal_statutes}) catch return null;
    w.writeAll("},") catch return null;

    // PROMPT scores — nested object matching Lithoglyph PromptScoresInput schema
    w.writeAll("\"promptScores\":{") catch return null;
    w.print("\"provenance\":{d},", .{prompt.provenance}) catch return null;
    w.print("\"replicability\":{d},", .{prompt.replicability}) catch return null;
    w.print("\"objective\":{d},", .{prompt.objective}) catch return null;
    w.print("\"methodology\":{d},", .{prompt.methodology}) catch return null;
    w.print("\"publication\":{d},", .{prompt.publication}) catch return null;
    w.print("\"transparency\":{d}", .{prompt.transparency}) catch return null;
    w.writeAll("},") catch return null;

    // Sensitivity defaults to public for automated ingestion.
    writeJsonString(w, "sensitivity_level", "public") catch return null;

    w.writeAll("}") catch return null;

    return stream.pos;
}

// ── JSON Helpers ─────────────────────────────────────────────────────────

fn writeJsonString(w: anytype, key: []const u8, value: []const u8) !void {
    try w.writeAll("\"");
    try w.writeAll(key);
    try w.writeAll("\":\"");
    try writeJsonEscaped(w, value);
    try w.writeAll("\"");
}

fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

// ============================================================================
// FDQL INSERT Statement Generator
// ============================================================================

/// Generate a Lithoglyph FDQL INSERT statement from a StageResults message.
///
/// The generated statement includes provenance metadata for Lithoglyph's
/// audit journal. Returns the number of bytes written, or null on error.
pub fn stageResultsToFdql(
    msg: []const u8,
    source_filename: []const u8,
    investigation_id: []const u8,
    run_id: []const u8,
    out_buf: []u8,
) ?usize {
    // First generate the JSON record.
    var json_buf: [MAX_JSON_LEN]u8 = undefined;
    const json_len = stageResultsToJson(msg, source_filename, investigation_id, run_id, &json_buf) orelse return null;
    const json = json_buf[0..json_len];

    var stream = std.io.fixedBufferStream(out_buf);
    var w = stream.writer();

    w.writeAll("INSERT INTO bofig_evidence ") catch return null;
    w.writeAll(json) catch return null;
    w.writeAll("\nWITH PROVENANCE {\n  actor: \"docudactyl-pipeline\",\n  rationale: \"Batch extraction run ") catch return null;
    writeJsonEscaped(w, run_id) catch return null;
    w.writeAll("\"\n}") catch return null;

    return stream.pos;
}

// ============================================================================
// SHA-256 Deduplication Check Query
// ============================================================================

/// Generate an FDQL query to check if an evidence record with the given
/// SHA-256 hash already exists. Used for deduplication before insertion.
pub fn dedupCheckQuery(sha256: []const u8, out_buf: []u8) ?usize {
    var stream = std.io.fixedBufferStream(out_buf);
    var w = stream.writer();

    w.writeAll("SELECT sha256_hash FROM bofig_evidence WHERE sha256_hash = '") catch return null;
    writeJsonEscaped(w, sha256) catch return null;
    w.writeAll("' LIMIT 1") catch return null;

    return stream.pos;
}

// ============================================================================
// Tests
// ============================================================================

test "detectEvidenceType maps MIME types correctly" {
    try std.testing.expectEqualStrings("court_filing", detectEvidenceType("application/pdf"));
    try std.testing.expectEqualStrings("photograph", detectEvidenceType("image/jpeg"));
    try std.testing.expectEqualStrings("photograph", detectEvidenceType("image/png"));
    try std.testing.expectEqualStrings("video", detectEvidenceType("video/mp4"));
    try std.testing.expectEqualStrings("interview", detectEvidenceType("audio/mpeg"));
    try std.testing.expectEqualStrings("financial_record", detectEvidenceType("text/csv"));
    try std.testing.expectEqualStrings("document", detectEvidenceType("text/plain"));
    try std.testing.expectEqualStrings("communication", detectEvidenceType("message/rfc822"));
    try std.testing.expectEqualStrings("document", detectEvidenceType(""));
    try std.testing.expectEqualStrings("document", detectEvidenceType("application/octet-stream"));

    // New evidence type coverage
    try std.testing.expectEqualStrings("dataset", detectEvidenceType("application/json"));
    try std.testing.expectEqualStrings("dataset", detectEvidenceType("application/xml"));
    try std.testing.expectEqualStrings("dataset", detectEvidenceType("text/xml"));
    try std.testing.expectEqualStrings("news_report", detectEvidenceType("text/html"));
    try std.testing.expectEqualStrings("financial_record", detectEvidenceType("application/vnd.ms-excel"));
}

test "computePromptScores basic scoring" {
    // All stages, high OCR, court filing
    const all_stages = computePromptScores(
        stages.STAGE_ALL,
        95,
        "court_filing",
        0.98,
    );
    // Provenance: 40 + 20 + 10 + 15 + 10 + 5 = 100
    try std.testing.expect(all_stages.provenance == 100);
    // Publication: court_filing → 95
    try std.testing.expect(all_stages.publication == 95);
    // Objective always 50
    try std.testing.expect(all_stages.objective == 50);
    // Transparency always 50
    try std.testing.expect(all_stages.transparency == 50);
    // Methodology: 20 + (24 * 80 / 24) = 20 + 80 = 100
    try std.testing.expect(all_stages.methodology == 100);
    // Replicability: 30 + 47 + 10 = 87
    try std.testing.expect(all_stages.replicability == 87);

    // Minimal stages, no OCR
    const minimal = computePromptScores(
        stages.STAGE_LANGUAGE_DETECT,
        -1,
        "document",
        0.5,
    );
    // Provenance: 40 + 0 + 0 + 0 + 0 + 0 = 40
    try std.testing.expect(minimal.provenance == 40);
    // Replicability: 30 + 45 + 0 = 75 (no OCR → native text bonus)
    try std.testing.expect(minimal.replicability == 75);
    // Methodology: 20 + (1 * 80 / 24) = 20 + 3 = 23
    try std.testing.expect(minimal.methodology == 23);
    // Publication: document → 45
    try std.testing.expect(minimal.publication == 45);
}

test "Reader.init rejects too-small buffer" {
    const tiny = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(Reader.init(&tiny) == null);
}

test "stageResultsToJson produces valid output with builder-created message" {
    // Build a minimal StageResults message using the Builder.
    var buf: [8192]u8 align(8) = undefined;
    var b = capnp.Builder.init(&buf);
    b.initRoot();

    const mask = stages.STAGE_LANGUAGE_DETECT | stages.STAGE_EXACT_DEDUP |
        stages.STAGE_OCR_CONFIDENCE | stages.STAGE_KEYWORDS;
    b.setU64(capnp.OFF_STAGES_MASK, mask);
    b.setI32(capnp.OFF_OCR_CONF, 88);
    b.setF64(capnp.OFF_LANG_CONFIDENCE, 0.95);

    b.setText(capnp.PTR_LANG_LANGUAGE, "en");
    b.setText(capnp.PTR_EXACT_SHA, "abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234");
    b.setText(capnp.PTR_PREMIS_FMT, "application/pdf");

    const kw_texts = [_][]const u8{ "evidence", "court", "filing" };
    b.setTextList(capnp.PTR_KW_WORDS, &kw_texts);

    // Serialise to a message buffer (header + segment).
    const segment_words: u32 = @intCast(b.pos / 8);
    var msg_buf: [16384]u8 = undefined;
    std.mem.writeInt(u32, msg_buf[0..4], 0, .little); // 1 segment
    std.mem.writeInt(u32, msg_buf[4..8], segment_words, .little);
    @memcpy(msg_buf[8 .. 8 + b.pos], buf[0..b.pos]);
    const msg = msg_buf[0 .. 8 + b.pos];

    var out: [MAX_JSON_LEN]u8 = undefined;
    const len = stageResultsToJson(msg, "test-doc.pdf", "inv_001", "run-42", &out);

    try std.testing.expect(len != null);

    // Verify it contains expected fields.
    const json = out[0..len.?];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"investigation_id\":\"inv_001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"title\":\"test-doc.pdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"evidence_type\":\"court_filing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sha256_hash\":\"abcd1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"language\":\"en\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ocr_confidence\":88") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"extraction_run_id\":\"run-42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"evidence\"") != null); // keyword
    try std.testing.expect(std.mem.indexOf(u8, json, "\"prompt_provenance\":") != null);
}
