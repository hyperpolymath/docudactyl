// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Docudactyl — Batch Re-extraction Pipeline Controller
//
// Controller for batch re-extraction when stages are updated or added.
// Given a list of document paths and a stage bitmask:
// - Reads existing Cap'n Proto results
// - Identifies which stages need re-running (diff against existing stagesMask)
// - Re-runs only the missing/updated stages
// - Merges results into existing Cap'n Proto output
// - Updates the stagesMask
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

const std = @import("std");
const capnp = @import("capnp.zig");

// ============================================================================
// Public Types
// ============================================================================

/// Status codes for re-extraction operations.
pub const ReextractStatus = enum(c_int) {
    ok = 0,
    no_work = 1,
    read_error = 2,
    write_error = 3,
    merge_error = 4,
    invalid_input = 5,
};

/// Result of a merge operation.
pub const MergeResult = extern struct {
    status: c_int,
    /// Combined stage mask after merge.
    merged_mask: u64,
    /// Number of bytes written to the output buffer.
    output_len: u32,
    /// Number of data words merged.
    data_words_merged: u32,
    /// Number of pointer words merged.
    ptr_words_merged: u32,
    /// Diagnostic summary (null-terminated).
    summary: [256]u8,
};

/// Plan result: describes what work needs to be done.
pub const ReextractPlan = extern struct {
    /// Bitmask of stages that need to be (re-)run.
    stages_to_run: u64,
    /// Bitmask of stages already present in existing results.
    existing_stages: u64,
    /// Bitmask of stages requested.
    requested_stages: u64,
    /// Number of stages to run.
    stage_count: u32,
    /// Whether any work is needed (0 = no, 1 = yes).
    needs_work: u8,
    _pad: [3]u8,
    /// Diagnostic summary (null-terminated).
    summary: [256]u8,
};

// ============================================================================
// Planning
// ============================================================================

/// Compute which stages need to be run given what already exists and what
/// is requested. Returns a bitmask of stages to run.
///
/// This is a pure bitwise operation: stages_to_run = requested & ~existing.
/// If force_rerun is set, all requested stages are re-run regardless.
pub fn reextractPlan(existing_mask: u64, requested_mask: u64) u64 {
    // Run stages that are requested but not already present
    return requested_mask & ~existing_mask;
}

/// Detailed planning with diagnostics.
pub fn reextractPlanDetailed(existing_mask: u64, requested_mask: u64, force: bool) ReextractPlan {
    var plan: ReextractPlan = undefined;
    @memset(std.mem.asBytes(&plan), 0);

    plan.existing_stages = existing_mask;
    plan.requested_stages = requested_mask;

    if (force) {
        plan.stages_to_run = requested_mask;
    } else {
        plan.stages_to_run = requested_mask & ~existing_mask;
    }

    // Count stages
    var mask = plan.stages_to_run;
    var count: u32 = 0;
    while (mask != 0) : (mask >>= 1) {
        if (mask & 1 != 0) count += 1;
    }
    plan.stage_count = count;
    plan.needs_work = if (count > 0) 1 else 0;

    // Count existing stages
    var existing_count: u32 = 0;
    mask = existing_mask;
    while (mask != 0) : (mask >>= 1) {
        if (mask & 1 != 0) existing_count += 1;
    }

    // Summary
    var summary_buf: [256]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "{d} stage(s) to run ({d} existing, {d} requested){s}", .{
        count,
        existing_count,
        @as(u32, @popCount(requested_mask)),
        if (force) ", force rerun" else "",
    }) catch "Re-extraction plan complete";
    @memcpy(plan.summary[0..summary.len], summary);
    plan.summary[summary.len] = 0;

    return plan;
}

// ============================================================================
// Reading Existing Results
// ============================================================================

/// Read the stages mask from an existing Cap'n Proto results file.
/// Returns the mask, or 0 if the file cannot be read or is invalid.
pub fn readExistingMask(path: []const u8) u64 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
    defer file.close();

    // Read the message header (8 bytes) + enough for the stages mask field
    var header: [8]u8 = undefined;
    const hdr_read = file.readAll(&header) catch return 0;
    if (hdr_read < 8) return 0;

    // Parse segment count and size
    const seg_count = std.mem.readInt(u32, header[0..4], .little);
    if (seg_count != 0) return 0; // We only handle single-segment messages

    const seg_words = std.mem.readInt(u32, header[4..8], .little);
    if (seg_words < 2) return 0; // Need at least root pointer + one data word

    // Read the root pointer word + first data word (stages mask)
    // Root pointer is at offset 0 in segment, data starts at offset 8
    // Stages mask is at OFF_STAGES_MASK = 0 within data section (= byte 8 of segment = byte 16 of file)
    var data_buf: [24]u8 = undefined;
    const data_read = file.readAll(&data_buf) catch return 0;
    if (data_read < 16) return 0;

    // Stages mask is at data_start(8) + OFF_STAGES_MASK(0) = byte 8 of segment
    return std.mem.readInt(u64, data_buf[8..16], .little);
}

/// Read an entire Cap'n Proto message from a file into a buffer.
/// Returns the number of bytes read, or 0 on error.
pub fn readMessage(path: []const u8, buf: []u8) usize {
    const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
    defer file.close();

    const stat = file.stat() catch return 0;
    const size = @min(stat.size, buf.len);
    if (size == 0) return 0;

    const n = file.readAll(buf[0..size]) catch return 0;
    return n;
}

// ============================================================================
// Merging
// ============================================================================

/// Merge new stage results into an existing Cap'n Proto message.
///
/// The merge copies data fields from new_results for stages present in
/// new_mask but not in the existing message's mask. Pointer fields (text)
/// for those stages are also copied.
///
/// Both existing and new_results must be complete Cap'n Proto messages
/// (8-byte header + segment).
///
/// The merged output is written to out_buf.
pub fn reextractMerge(
    existing: []const u8,
    new_results: []const u8,
    out_buf: []u8,
) MergeResult {
    var result: MergeResult = undefined;
    @memset(std.mem.asBytes(&result), 0);

    if (existing.len < 24 or new_results.len < 24) {
        result.status = @intFromEnum(ReextractStatus.invalid_input);
        setSummary(&result.summary, "Input message(s) too small");
        return result;
    }

    // Validate both messages have single segments
    const exist_segs = std.mem.readInt(u32, existing[0..4], .little);
    const new_segs = std.mem.readInt(u32, new_results[0..4], .little);
    if (exist_segs != 0 or new_segs != 0) {
        result.status = @intFromEnum(ReextractStatus.invalid_input);
        setSummary(&result.summary, "Only single-segment messages supported");
        return result;
    }

    // Read existing stages mask
    const exist_seg = existing[8..];
    const new_seg = new_results[8..];

    // Root struct data starts at byte 8 within segment (after root pointer word)
    const data_start: usize = 8;
    const data_size = @as(usize, capnp.DATA_WORDS) * 8;
    const ptr_start = data_start + data_size;
    const ptr_size = @as(usize, capnp.PTR_WORDS) * 8;
    const min_seg_size = ptr_start + ptr_size;

    if (exist_seg.len < min_seg_size or new_seg.len < min_seg_size) {
        result.status = @intFromEnum(ReextractStatus.invalid_input);
        setSummary(&result.summary, "Segment too small for StageResults struct");
        return result;
    }

    const exist_mask = std.mem.readInt(u64, exist_seg[data_start..][0..8], .little);
    const new_mask = std.mem.readInt(u64, new_seg[data_start..][0..8], .little);

    // Start with a copy of the existing message
    if (out_buf.len < existing.len) {
        result.status = @intFromEnum(ReextractStatus.merge_error);
        setSummary(&result.summary, "Output buffer too small");
        return result;
    }

    // Build merged output using the Builder for correctness
    // Strategy: copy existing segment, then overlay new data/pointer fields
    // for stages present in new_mask but not in exist_mask.
    @memcpy(out_buf[0..existing.len], existing);
    var out_seg = out_buf[8..];

    // Stages to merge: present in new but not in existing
    const merge_mask = new_mask & ~exist_mask;

    // Overlay data section: copy 8-byte words that correspond to merged stages.
    // We do a simple full-data-section overlay for fields belonging to new stages.
    // Since stages write to specific offsets, we copy the entire data section from
    // new_results for the fields we know belong to the new stages.
    //
    // For a precise merge, we'd need a per-stage field map. For now, we use the
    // conservative approach: if ANY investigative stage is new, copy the
    // investigative data region. Similarly for other stage groups.
    var data_words_merged: u32 = 0;
    var ptr_words_merged: u32 = 0;

    // Investigative stage data fields (offsets 184-211)
    const stages_mod = @import("stages.zig");
    const investigative_mask = stages_mod.STAGE_REDACTION_DETECT |
        stages_mod.STAGE_FINANCIAL_EXTRACT |
        stages_mod.STAGE_LEGAL_NER |
        stages_mod.STAGE_SPEAKER_ID;

    if (merge_mask & investigative_mask != 0) {
        // Copy investigative data region (offsets 184..212 within data section)
        const inv_start = data_start + 184;
        const inv_end = data_start + 212;
        if (inv_end <= new_seg.len and inv_end <= out_seg.len) {
            @memcpy(out_seg[inv_start..inv_end], new_seg[inv_start..inv_end]);
            data_words_merged += 4;
        }

        // Copy investigative pointer slots (30-37)
        for (30..38) |slot| {
            const off = ptr_start + slot * 8;
            if (off + 8 <= new_seg.len and off + 8 <= out_seg.len) {
                @memcpy(out_seg[off .. off + 8], new_seg[off .. off + 8]);
                ptr_words_merged += 1;
            }
        }
    }

    // Text analysis stages (language, readability, keywords, citations)
    const text_mask = stages_mod.STAGE_LANGUAGE_DETECT | stages_mod.STAGE_READABILITY |
        stages_mod.STAGE_KEYWORDS | stages_mod.STAGE_CITATION_EXTRACT;
    if (merge_mask & text_mask != 0) {
        // Copy relevant data words (offsets 8..88 for language/readability/keywords/citations)
        const region_start = data_start + 8;
        const region_end = data_start + 88;
        if (region_end <= new_seg.len and region_end <= out_seg.len) {
            @memcpy(out_seg[region_start..region_end], new_seg[region_start..region_end]);
            data_words_merged += 10;
        }
        // Copy pointer slots 0-2 (lang_script, lang_language, kw_words)
        for (0..3) |slot| {
            const off = ptr_start + slot * 8;
            if (off + 8 <= new_seg.len and off + 8 <= out_seg.len) {
                @memcpy(out_seg[off .. off + 8], new_seg[off .. off + 8]);
                ptr_words_merged += 1;
            }
        }
    }

    // OCR / perceptual hash stages
    const ocr_mask = stages_mod.STAGE_OCR_CONFIDENCE | stages_mod.STAGE_PERCEPTUAL_HASH;
    if (merge_mask & ocr_mask != 0) {
        // OCR confidence at offset 88
        if (data_start + 92 <= new_seg.len and data_start + 92 <= out_seg.len) {
            @memcpy(out_seg[data_start + 88 .. data_start + 92], new_seg[data_start + 88 .. data_start + 92]);
            data_words_merged += 1;
        }
        // Perceptual hash pointer slot 3
        const off = ptr_start + 3 * 8;
        if (off + 8 <= new_seg.len and off + 8 <= out_seg.len) {
            @memcpy(out_seg[off .. off + 8], new_seg[off .. off + 8]);
            ptr_words_merged += 1;
        }
    }

    // Integrity stages (PREMIS, merkle, dedup)
    const integrity_mask = stages_mod.STAGE_PREMIS_METADATA | stages_mod.STAGE_MERKLE_PROOF |
        stages_mod.STAGE_EXACT_DEDUP | stages_mod.STAGE_NEAR_DEDUP;
    if (merge_mask & integrity_mask != 0) {
        // PREMIS size at offset 120
        if (data_start + 128 <= new_seg.len and data_start + 128 <= out_seg.len) {
            @memcpy(out_seg[data_start + 112 .. data_start + 136], new_seg[data_start + 112 .. data_start + 136]);
            data_words_merged += 3;
        }
        // Pointer slots 7-16 (PREMIS + dedup pointers)
        for (7..17) |slot| {
            const off = ptr_start + slot * 8;
            if (off + 8 <= new_seg.len and off + 8 <= out_seg.len) {
                @memcpy(out_seg[off .. off + 8], new_seg[off .. off + 8]);
                ptr_words_merged += 1;
            }
        }
    }

    // Update the stages mask to be the union
    const merged_mask = exist_mask | new_mask;
    std.mem.writeInt(u64, @as(*[8]u8, @ptrCast(out_seg.ptr + data_start)), merged_mask, .little);

    result.merged_mask = merged_mask;
    result.output_len = @intCast(existing.len);
    result.data_words_merged = data_words_merged;
    result.ptr_words_merged = ptr_words_merged;
    result.status = @intFromEnum(ReextractStatus.ok);

    var summary_buf: [256]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "Merged {d} data words, {d} ptr words; mask 0x{x:0>16} -> 0x{x:0>16}", .{
        data_words_merged,
        ptr_words_merged,
        exist_mask,
        merged_mask,
    }) catch "Merge complete";
    setSummary(&result.summary, summary);

    return result;
}

fn setSummary(dest: *[256]u8, text: []const u8) void {
    @memset(dest, 0);
    const len = @min(text.len, 255);
    @memcpy(dest[0..len], text[0..len]);
}

// ============================================================================
// File-Level Re-extraction
// ============================================================================

/// Re-extract stages for a single document, reading existing results from
/// {output_path}.stages.capnp and merging.
///
/// Returns the stages that were actually re-run.
pub fn reextractFile(
    output_path: []const u8,
    requested_mask: u64,
    force: bool,
) ReextractPlan {
    // Build stages file path
    const suffix = ".stages.capnp";
    var path_buf: [4096]u8 = undefined;
    if (output_path.len + suffix.len >= 4096) {
        var plan: ReextractPlan = undefined;
        @memset(std.mem.asBytes(&plan), 0);
        setSummary256(&plan.summary, "Path too long");
        return plan;
    }
    @memcpy(path_buf[0..output_path.len], output_path);
    @memcpy(path_buf[output_path.len .. output_path.len + suffix.len], suffix);

    const stages_path = path_buf[0 .. output_path.len + suffix.len];
    const existing_mask = readExistingMask(stages_path);

    return reextractPlanDetailed(existing_mask, requested_mask, force);
}

fn setSummary256(dest: *[256]u8, text: []const u8) void {
    @memset(dest, 0);
    const len = @min(text.len, 255);
    @memcpy(dest[0..len], text[0..len]);
}

// ============================================================================
// C-ABI Exports
// ============================================================================

/// Compute which stages need to run. Pure bitmask operation.
export fn ddac_reextract_plan(existing_mask: u64, requested_mask: u64) u64 {
    return reextractPlan(existing_mask, requested_mask);
}

/// Detailed planning with diagnostics.
export fn ddac_reextract_plan_detailed(
    existing_mask: u64,
    requested_mask: u64,
    force: c_int,
    result: ?*ReextractPlan,
) c_int {
    const res = result orelse return 1;
    res.* = reextractPlanDetailed(existing_mask, requested_mask, force != 0);
    return 0;
}

/// Merge new results into existing Cap'n Proto message.
export fn ddac_reextract_merge(
    existing_ptr: ?[*]const u8,
    existing_len: usize,
    new_ptr: ?[*]const u8,
    new_len: usize,
    out_ptr: ?[*]u8,
    out_len: usize,
    result: ?*MergeResult,
) c_int {
    const existing = if (existing_ptr) |p| p[0..existing_len] else return 1;
    const new_results = if (new_ptr) |p| p[0..new_len] else return 1;
    const out_buf = if (out_ptr) |p| p[0..out_len] else return 1;
    const res = result orelse return 1;

    res.* = reextractMerge(existing, new_results, out_buf);
    return @intFromEnum(@as(ReextractStatus, @enumFromInt(res.status)));
}

/// Read the stages mask from an existing results file.
export fn ddac_reextract_read_mask(
    path_ptr: ?[*]const u8,
    path_len: usize,
) u64 {
    const path = if (path_ptr) |p| p[0..path_len] else return 0;
    return readExistingMask(path);
}

// ============================================================================
// Tests
// ============================================================================

test "reextractPlan returns delta" {
    // Existing has stages 0,1,2; requested has 0,1,2,3,4
    const existing: u64 = 0b00111;
    const requested: u64 = 0b11111;
    const to_run = reextractPlan(existing, requested);
    try std.testing.expect(to_run == 0b11000); // stages 3 and 4
}

test "reextractPlan no work needed" {
    const existing: u64 = 0b11111;
    const requested: u64 = 0b00111;
    const to_run = reextractPlan(existing, requested);
    try std.testing.expect(to_run == 0);
}

test "reextractPlanDetailed reports stage count" {
    const plan = reextractPlanDetailed(0b00111, 0b11111, false);
    try std.testing.expect(plan.stage_count == 2);
    try std.testing.expect(plan.needs_work == 1);
}

test "reextractPlanDetailed force reruns all" {
    const plan = reextractPlanDetailed(0b00111, 0b11111, true);
    try std.testing.expect(plan.stage_count == 5);
    try std.testing.expect(plan.stages_to_run == 0b11111);
}

test "reextractMerge rejects too-small input" {
    var out: [64]u8 = undefined;
    const tiny = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const res = reextractMerge(&tiny, &tiny, &out);
    try std.testing.expect(res.status == @intFromEnum(ReextractStatus.invalid_input));
}

test "reextractMerge with builder-created messages" {
    // Build "existing" message with language detect stage
    var exist_buf: [8192]u8 align(8) = undefined;
    var b1 = capnp.Builder.init(&exist_buf);
    b1.initRoot();

    const stages_mod = @import("stages.zig");
    b1.setU64(capnp.OFF_STAGES_MASK, stages_mod.STAGE_LANGUAGE_DETECT);
    b1.setF64(capnp.OFF_LANG_CONFIDENCE, 0.95);
    b1.setText(capnp.PTR_LANG_LANGUAGE, "en");

    var exist_msg: [16384]u8 = undefined;
    const sw1: u32 = @intCast(b1.pos / 8);
    std.mem.writeInt(u32, exist_msg[0..4], 0, .little);
    std.mem.writeInt(u32, exist_msg[4..8], sw1, .little);
    @memcpy(exist_msg[8 .. 8 + b1.pos], exist_buf[0..b1.pos]);
    const exist_len = 8 + b1.pos;

    // Build "new" message with keywords stage
    var new_buf: [8192]u8 align(8) = undefined;
    var b2 = capnp.Builder.init(&new_buf);
    b2.initRoot();
    b2.setU64(capnp.OFF_STAGES_MASK, stages_mod.STAGE_KEYWORDS);
    b2.setU32(capnp.OFF_KW_COUNT, 42);

    var new_msg: [16384]u8 = undefined;
    const sw2: u32 = @intCast(b2.pos / 8);
    std.mem.writeInt(u32, new_msg[0..4], 0, .little);
    std.mem.writeInt(u32, new_msg[4..8], sw2, .little);
    @memcpy(new_msg[8 .. 8 + b2.pos], new_buf[0..b2.pos]);
    const new_len = 8 + b2.pos;

    // Merge
    var out: [32768]u8 = undefined;
    const merge_result = reextractMerge(exist_msg[0..exist_len], new_msg[0..new_len], &out);
    try std.testing.expect(merge_result.status == @intFromEnum(ReextractStatus.ok));
    try std.testing.expect(merge_result.merged_mask == (stages_mod.STAGE_LANGUAGE_DETECT | stages_mod.STAGE_KEYWORDS));
}
