// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Docudactyl — Extraction Quality Statistics Dashboard
//
// Aggregates extraction quality metrics across a batch run:
// - Per-stage success/failure/skip counts
// - OCR confidence distribution (histogram buckets)
// - Language detection distribution
// - Processing time per stage (p50, p95, p99)
// - Error categorization (file_not_found, parse_error, timeout, etc.)
// - Dedup hit rates (L1 cache, L2 cache, exact, near)
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

/// Maximum number of stages tracked (matches STAGE_COUNT from stages.zig).
pub const MAX_STAGES: usize = 24;

/// Number of OCR confidence histogram buckets (0-9, 10-19, ..., 90-100).
pub const OCR_HISTOGRAM_BUCKETS: usize = 10;

/// Maximum number of languages tracked.
pub const MAX_LANGUAGES: usize = 32;

/// Maximum language code length (e.g., "en", "zh-Hans").
pub const MAX_LANG_CODE: usize = 16;

/// Maximum timing samples stored per stage for percentile computation.
/// Beyond this, samples are merged via a streaming approximation.
pub const MAX_TIMING_SAMPLES: usize = 1024;

/// Maximum number of error categories.
pub const MAX_ERROR_CATEGORIES: usize = 16;

/// Maximum error category name length.
pub const MAX_ERROR_NAME: usize = 32;

// ============================================================================
// Public Types
// ============================================================================

/// Per-stage counters.
pub const StageCounter = extern struct {
    success: u64,
    failure: u64,
    skipped: u64,
    /// Total processing time in microseconds.
    total_time_us: u64,
};

/// Language distribution entry.
pub const LanguageEntry = extern struct {
    code: [MAX_LANG_CODE]u8,
    count: u64,
    total_confidence: f64,
};

/// Error category entry.
pub const ErrorCategory = extern struct {
    name: [MAX_ERROR_NAME]u8,
    count: u64,
};

/// Deduplication hit rate counters.
pub const DedupStats = extern struct {
    /// L1 cache hits (in-memory, same locale).
    l1_hits: u64,
    /// L2 cache hits (cross-locale or DragonflyDB).
    l2_hits: u64,
    /// Exact dedup hits (SHA-256 match).
    exact_hits: u64,
    /// Near dedup hits (perceptual hash similarity above threshold).
    near_hits: u64,
    /// Total documents checked.
    total_checked: u64,
};

/// Timing percentile results.
pub const TimingPercentiles = extern struct {
    p50_us: f64,
    p95_us: f64,
    p99_us: f64,
    min_us: f64,
    max_us: f64,
    mean_us: f64,
};

/// Complete quality statistics for a batch run.
pub const QualityStats = extern struct {
    /// Total documents processed.
    total_documents: u64,
    /// Documents with errors.
    error_documents: u64,
    /// Documents successfully processed.
    success_documents: u64,

    /// Per-stage counters.
    stages: [MAX_STAGES]StageCounter,

    /// OCR confidence histogram (bucket i covers confidence [i*10, (i+1)*10)).
    ocr_histogram: [OCR_HISTOGRAM_BUCKETS]u64,
    /// Total OCR documents.
    ocr_total: u64,
    /// Sum of OCR confidence for mean calculation.
    ocr_confidence_sum: f64,

    /// Language distribution.
    languages: [MAX_LANGUAGES]LanguageEntry,
    language_count: u32,
    _pad1: [4]u8,

    /// Error categorization.
    errors: [MAX_ERROR_CATEGORIES]ErrorCategory,
    error_category_count: u32,
    _pad2: [4]u8,

    /// Deduplication statistics.
    dedup: DedupStats,

    /// Per-stage timing samples (circular buffer).
    /// Stored as a flat array: stage_timing_samples[stage_idx * MAX_TIMING_SAMPLES + sample_idx].
    /// stage_timing_counts[stage_idx] = number of samples collected (may wrap).
    stage_timing_counts: [MAX_STAGES]u32,
    _pad3: [4]u8,

    /// Wall-clock start time (nanoseconds since epoch).
    start_time_ns: i128,
    /// Wall-clock end time (updated on each record call).
    end_time_ns: i128,

    /// Internal: timing sample storage. Stored separately to keep the
    /// extern struct a reasonable size for FFI. This field is NOT exported
    /// over FFI — it's an internal buffer managed by init/record/merge.
    /// We use a comptime-known fixed array for simplicity.
    stage_timings: [MAX_STAGES * MAX_TIMING_SAMPLES]f64,
};

// ============================================================================
// Initialisation
// ============================================================================

/// Initialise a QualityStats struct to zeroes with a start timestamp.
pub fn qualityStatsInit(stats: *QualityStats) void {
    @memset(std.mem.asBytes(stats), 0);
    stats.start_time_ns = std.time.nanoTimestamp();
    stats.end_time_ns = stats.start_time_ns;
}

// ============================================================================
// Recording
// ============================================================================

/// Record a single document's parse result into the aggregate statistics.
///
/// Arguments:
///   stats       — aggregate stats being built
///   status      — parse result status (0=success, nonzero=error)
///   stage_mask  — bitmask of stages that were enabled
///   parse_time_us — total parse time in microseconds
///   ocr_confidence — OCR confidence (0-100) or -1 if N/A
///   language    — detected language code (e.g., "en") or empty
///   lang_confidence — language detection confidence (0.0-1.0)
///   error_code  — error category string (e.g., "parse_error") or empty
pub fn qualityStatsRecord(
    stats: *QualityStats,
    status: c_int,
    stage_mask: u64,
    parse_time_us: f64,
    ocr_confidence: i32,
    language: []const u8,
    lang_confidence: f64,
    error_code: []const u8,
) void {
    stats.total_documents += 1;
    stats.end_time_ns = std.time.nanoTimestamp();

    if (status == 0) {
        stats.success_documents += 1;
    } else {
        stats.error_documents += 1;

        // Categorise the error
        if (error_code.len > 0) {
            recordError(stats, error_code);
        }
    }

    // Record per-stage stats
    for (0..MAX_STAGES) |stage_idx| {
        const bit: u64 = @as(u64, 1) << @as(u6, @intCast(stage_idx));
        if (stage_mask & bit != 0) {
            if (status == 0) {
                stats.stages[stage_idx].success += 1;
            } else {
                stats.stages[stage_idx].failure += 1;
            }
            // Record timing sample
            recordTiming(stats, stage_idx, parse_time_us);
        } else {
            stats.stages[stage_idx].skipped += 1;
        }
    }

    // OCR confidence histogram
    if (ocr_confidence >= 0) {
        stats.ocr_total += 1;
        stats.ocr_confidence_sum += @floatFromInt(ocr_confidence);
        const bucket: usize = @intCast(@min(@as(u32, @intCast(@max(ocr_confidence, 0))) / 10, OCR_HISTOGRAM_BUCKETS - 1));
        stats.ocr_histogram[bucket] += 1;
    }

    // Language distribution
    if (language.len > 0) {
        recordLanguage(stats, language, lang_confidence);
    }
}

/// Record a dedup event.
pub fn qualityStatsRecordDedup(
    stats: *QualityStats,
    l1_hit: bool,
    l2_hit: bool,
    exact_hit: bool,
    near_hit: bool,
) void {
    stats.dedup.total_checked += 1;
    if (l1_hit) stats.dedup.l1_hits += 1;
    if (l2_hit) stats.dedup.l2_hits += 1;
    if (exact_hit) stats.dedup.exact_hits += 1;
    if (near_hit) stats.dedup.near_hits += 1;
}

fn recordError(stats: *QualityStats, code: []const u8) void {
    // Find existing category
    for (0..stats.error_category_count) |idx| {
        const existing = std.mem.sliceTo(&stats.errors[idx].name, 0);
        if (std.mem.eql(u8, existing, code)) {
            stats.errors[idx].count += 1;
            return;
        }
    }
    // Add new category
    if (stats.error_category_count < MAX_ERROR_CATEGORIES) {
        const idx = stats.error_category_count;
        stats.error_category_count += 1;
        @memset(&stats.errors[idx].name, 0);
        const len = @min(code.len, MAX_ERROR_NAME - 1);
        @memcpy(stats.errors[idx].name[0..len], code[0..len]);
        stats.errors[idx].count = 1;
    }
}

fn recordLanguage(stats: *QualityStats, code: []const u8, confidence: f64) void {
    // Find existing language
    for (0..stats.language_count) |idx| {
        const existing = std.mem.sliceTo(&stats.languages[idx].code, 0);
        if (std.mem.eql(u8, existing, code)) {
            stats.languages[idx].count += 1;
            stats.languages[idx].total_confidence += confidence;
            return;
        }
    }
    // Add new language
    if (stats.language_count < MAX_LANGUAGES) {
        const idx = stats.language_count;
        stats.language_count += 1;
        @memset(&stats.languages[idx].code, 0);
        const len = @min(code.len, MAX_LANG_CODE - 1);
        @memcpy(stats.languages[idx].code[0..len], code[0..len]);
        stats.languages[idx].count = 1;
        stats.languages[idx].total_confidence = confidence;
    }
}

fn recordTiming(stats: *QualityStats, stage_idx: usize, time_us: f64) void {
    const base = stage_idx * MAX_TIMING_SAMPLES;
    const count = stats.stage_timing_counts[stage_idx];
    const idx = count % MAX_TIMING_SAMPLES;
    stats.stage_timings[base + idx] = time_us;
    stats.stage_timing_counts[stage_idx] = count +% 1;
    stats.stages[stage_idx].total_time_us +%= @intFromFloat(@max(time_us, 0.0));
}

// ============================================================================
// Merging (for cross-locale reduce in Chapel)
// ============================================================================

/// Merge src statistics into dst. Used for combining per-locale stats in Chapel.
pub fn qualityStatsMerge(dst: *QualityStats, src: *const QualityStats) void {
    dst.total_documents += src.total_documents;
    dst.error_documents += src.error_documents;
    dst.success_documents += src.success_documents;

    // Per-stage counters
    for (0..MAX_STAGES) |i| {
        dst.stages[i].success += src.stages[i].success;
        dst.stages[i].failure += src.stages[i].failure;
        dst.stages[i].skipped += src.stages[i].skipped;
        dst.stages[i].total_time_us +%= src.stages[i].total_time_us;
    }

    // OCR histogram
    for (0..OCR_HISTOGRAM_BUCKETS) |i| {
        dst.ocr_histogram[i] += src.ocr_histogram[i];
    }
    dst.ocr_total += src.ocr_total;
    dst.ocr_confidence_sum += src.ocr_confidence_sum;

    // Languages — merge by matching codes
    for (0..src.language_count) |si| {
        const src_code = std.mem.sliceTo(&src.languages[si].code, 0);
        if (src_code.len == 0) continue;

        var found = false;
        for (0..dst.language_count) |di| {
            const dst_code = std.mem.sliceTo(&dst.languages[di].code, 0);
            if (std.mem.eql(u8, dst_code, src_code)) {
                dst.languages[di].count += src.languages[si].count;
                dst.languages[di].total_confidence += src.languages[si].total_confidence;
                found = true;
                break;
            }
        }
        if (!found and dst.language_count < MAX_LANGUAGES) {
            dst.languages[dst.language_count] = src.languages[si];
            dst.language_count += 1;
        }
    }

    // Errors — merge by matching names
    for (0..src.error_category_count) |si| {
        const src_name = std.mem.sliceTo(&src.errors[si].name, 0);
        if (src_name.len == 0) continue;

        var found = false;
        for (0..dst.error_category_count) |di| {
            const dst_name = std.mem.sliceTo(&dst.errors[di].name, 0);
            if (std.mem.eql(u8, dst_name, src_name)) {
                dst.errors[di].count += src.errors[si].count;
                found = true;
                break;
            }
        }
        if (!found and dst.error_category_count < MAX_ERROR_CATEGORIES) {
            dst.errors[dst.error_category_count] = src.errors[si];
            dst.error_category_count += 1;
        }
    }

    // Dedup stats
    dst.dedup.l1_hits += src.dedup.l1_hits;
    dst.dedup.l2_hits += src.dedup.l2_hits;
    dst.dedup.exact_hits += src.dedup.exact_hits;
    dst.dedup.near_hits += src.dedup.near_hits;
    dst.dedup.total_checked += src.dedup.total_checked;

    // Time range
    if (src.start_time_ns < dst.start_time_ns or dst.total_documents == src.total_documents) {
        dst.start_time_ns = src.start_time_ns;
    }
    if (src.end_time_ns > dst.end_time_ns) {
        dst.end_time_ns = src.end_time_ns;
    }
}

// ============================================================================
// Percentile Computation
// ============================================================================

/// Compute timing percentiles for a given stage.
pub fn computeTimingPercentiles(stats: *const QualityStats, stage_idx: usize) TimingPercentiles {
    var result: TimingPercentiles = undefined;
    @memset(std.mem.asBytes(&result), 0);

    const count = stats.stage_timing_counts[stage_idx];
    if (count == 0) return result;

    const n = @min(@as(usize, count), MAX_TIMING_SAMPLES);
    const base = stage_idx * MAX_TIMING_SAMPLES;

    // Copy samples to sort
    var samples: [MAX_TIMING_SAMPLES]f64 = undefined;
    @memcpy(samples[0..n], stats.stage_timings[base .. base + n]);

    // Sort for percentile computation
    std.sort.block(f64, samples[0..n], {}, std.sort.asc(f64));

    result.min_us = samples[0];
    result.max_us = samples[n - 1];

    // Mean
    var sum: f64 = 0.0;
    for (0..n) |i| sum += samples[i];
    result.mean_us = sum / @as(f64, @floatFromInt(n));

    // Percentiles via nearest-rank method
    result.p50_us = samples[@min(n * 50 / 100, n - 1)];
    result.p95_us = samples[@min(n * 95 / 100, n - 1)];
    result.p99_us = samples[@min(n * 99 / 100, n - 1)];

    return result;
}

// ============================================================================
// JSON Serialisation
// ============================================================================

/// Serialise QualityStats to a JSON string in the provided buffer.
/// Returns the number of bytes written, or 0 on error.
pub fn qualityStatsToJson(stats: *const QualityStats, buf: []u8) usize {
    var stream = std.io.fixedBufferStream(buf);
    var w = stream.writer();

    w.writeAll("{") catch return 0;

    // Summary
    w.print("\"total_documents\":{d},", .{stats.total_documents}) catch return 0;
    w.print("\"success_documents\":{d},", .{stats.success_documents}) catch return 0;
    w.print("\"error_documents\":{d},", .{stats.error_documents}) catch return 0;

    // Duration
    const duration_ns = stats.end_time_ns - stats.start_time_ns;
    const duration_ms: f64 = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    w.print("\"duration_ms\":{d:.1},", .{duration_ms}) catch return 0;

    // Throughput
    if (duration_ms > 0.0) {
        const docs_per_sec = @as(f64, @floatFromInt(stats.total_documents)) / (duration_ms / 1000.0);
        w.print("\"documents_per_second\":{d:.2},", .{docs_per_sec}) catch return 0;
    }

    // Per-stage stats
    w.writeAll("\"stages\":{") catch return 0;
    var first_stage = true;
    for (0..MAX_STAGES) |si| {
        const s = stats.stages[si];
        if (s.success == 0 and s.failure == 0 and s.skipped == 0) continue;
        if (!first_stage) w.writeAll(",") catch return 0;
        first_stage = false;

        const percentiles = computeTimingPercentiles(stats, si);
        w.print("\"{d}\":{{\"success\":{d},\"failure\":{d},\"skipped\":{d},\"total_time_us\":{d},\"p50_us\":{d:.1},\"p95_us\":{d:.1},\"p99_us\":{d:.1}}}", .{
            si,
            s.success,
            s.failure,
            s.skipped,
            s.total_time_us,
            percentiles.p50_us,
            percentiles.p95_us,
            percentiles.p99_us,
        }) catch return 0;
    }
    w.writeAll("},") catch return 0;

    // OCR histogram
    w.writeAll("\"ocr_confidence\":{") catch return 0;
    if (stats.ocr_total > 0) {
        const mean_ocr = stats.ocr_confidence_sum / @as(f64, @floatFromInt(stats.ocr_total));
        w.print("\"total\":{d},\"mean\":{d:.1},\"histogram\":[", .{ stats.ocr_total, mean_ocr }) catch return 0;
        for (0..OCR_HISTOGRAM_BUCKETS) |bi| {
            if (bi > 0) w.writeAll(",") catch return 0;
            w.print("{d}", .{stats.ocr_histogram[bi]}) catch return 0;
        }
        w.writeAll("]") catch return 0;
    } else {
        w.writeAll("\"total\":0") catch return 0;
    }
    w.writeAll("},") catch return 0;

    // Language distribution
    w.writeAll("\"languages\":[") catch return 0;
    for (0..stats.language_count) |li| {
        if (li > 0) w.writeAll(",") catch return 0;
        const code = std.mem.sliceTo(&stats.languages[li].code, 0);
        const avg_conf = if (stats.languages[li].count > 0)
            stats.languages[li].total_confidence / @as(f64, @floatFromInt(stats.languages[li].count))
        else
            0.0;
        w.print("{{\"code\":\"{s}\",\"count\":{d},\"avg_confidence\":{d:.3}}}", .{
            code,
            stats.languages[li].count,
            avg_conf,
        }) catch return 0;
    }
    w.writeAll("],") catch return 0;

    // Error categories
    w.writeAll("\"errors\":[") catch return 0;
    for (0..stats.error_category_count) |ei| {
        if (ei > 0) w.writeAll(",") catch return 0;
        const name = std.mem.sliceTo(&stats.errors[ei].name, 0);
        w.print("{{\"category\":\"{s}\",\"count\":{d}}}", .{
            name,
            stats.errors[ei].count,
        }) catch return 0;
    }
    w.writeAll("],") catch return 0;

    // Dedup stats
    w.writeAll("\"dedup\":{") catch return 0;
    w.print("\"total_checked\":{d},", .{stats.dedup.total_checked}) catch return 0;
    w.print("\"l1_hits\":{d},", .{stats.dedup.l1_hits}) catch return 0;
    w.print("\"l2_hits\":{d},", .{stats.dedup.l2_hits}) catch return 0;
    w.print("\"exact_hits\":{d},", .{stats.dedup.exact_hits}) catch return 0;
    w.print("\"near_hits\":{d}", .{stats.dedup.near_hits}) catch return 0;
    if (stats.dedup.total_checked > 0) {
        const total_hits = stats.dedup.l1_hits + stats.dedup.l2_hits +
            stats.dedup.exact_hits + stats.dedup.near_hits;
        const hit_rate = @as(f64, @floatFromInt(total_hits)) /
            @as(f64, @floatFromInt(stats.dedup.total_checked));
        w.print(",\"hit_rate\":{d:.4}", .{hit_rate}) catch return 0;
    }
    w.writeAll("}") catch return 0;

    w.writeAll("}") catch return 0;

    return stream.pos;
}

// ============================================================================
// C-ABI Exports
// ============================================================================

/// Initialise a QualityStats struct. Caller provides the memory.
export fn ddac_quality_stats_init(stats: ?*QualityStats) void {
    if (stats) |s| qualityStatsInit(s);
}

/// Record a document result into aggregate statistics.
export fn ddac_quality_stats_record(
    stats: ?*QualityStats,
    status: c_int,
    stage_mask: u64,
    parse_time_us: f64,
    ocr_confidence: i32,
    language_ptr: ?[*]const u8,
    language_len: usize,
    lang_confidence: f64,
    error_ptr: ?[*]const u8,
    error_len: usize,
) void {
    const s = stats orelse return;
    const language = if (language_ptr) |p| p[0..language_len] else "";
    const error_code = if (error_ptr) |p| p[0..error_len] else "";
    qualityStatsRecord(s, status, stage_mask, parse_time_us, ocr_confidence, language, lang_confidence, error_code);
}

/// Record a dedup event.
export fn ddac_quality_stats_record_dedup(
    stats: ?*QualityStats,
    l1_hit: c_int,
    l2_hit: c_int,
    exact_hit: c_int,
    near_hit: c_int,
) void {
    const s = stats orelse return;
    qualityStatsRecordDedup(s, l1_hit != 0, l2_hit != 0, exact_hit != 0, near_hit != 0);
}

/// Merge src into dst for cross-locale reduce.
export fn ddac_quality_stats_merge(
    dst: ?*QualityStats,
    src: ?*const QualityStats,
) void {
    const d = dst orelse return;
    const s = src orelse return;
    qualityStatsMerge(d, s);
}

/// Serialise to JSON. Returns bytes written.
export fn ddac_quality_stats_to_json(
    stats: ?*const QualityStats,
    buf_ptr: ?[*]u8,
    buf_len: usize,
) usize {
    const s = stats orelse return 0;
    const buf = if (buf_ptr) |p| p[0..buf_len] else return 0;
    return qualityStatsToJson(s, buf);
}

// ============================================================================
// Tests
// ============================================================================

test "init sets start time" {
    var stats: QualityStats = undefined;
    qualityStatsInit(&stats);
    try std.testing.expect(stats.start_time_ns != 0);
    try std.testing.expect(stats.total_documents == 0);
}

test "record increments counters" {
    var stats: QualityStats = undefined;
    qualityStatsInit(&stats);

    qualityStatsRecord(&stats, 0, 0b111, 1500.0, 85, "en", 0.95, "");
    try std.testing.expect(stats.total_documents == 1);
    try std.testing.expect(stats.success_documents == 1);
    try std.testing.expect(stats.stages[0].success == 1);
    try std.testing.expect(stats.stages[1].success == 1);
    try std.testing.expect(stats.stages[2].success == 1);
    try std.testing.expect(stats.stages[3].skipped == 1);
    try std.testing.expect(stats.ocr_histogram[8] == 1); // confidence 85 → bucket 8
    try std.testing.expect(stats.language_count == 1);
}

test "record errors categorised" {
    var stats: QualityStats = undefined;
    qualityStatsInit(&stats);

    qualityStatsRecord(&stats, 2, 0b1, 0.0, -1, "", 0.0, "parse_error");
    qualityStatsRecord(&stats, 2, 0b1, 0.0, -1, "", 0.0, "parse_error");
    qualityStatsRecord(&stats, 1, 0b1, 0.0, -1, "", 0.0, "file_not_found");

    try std.testing.expect(stats.error_documents == 3);
    try std.testing.expect(stats.error_category_count == 2);
    // parse_error should have count 2
    const name = std.mem.sliceTo(&stats.errors[0].name, 0);
    try std.testing.expectEqualStrings("parse_error", name);
    try std.testing.expect(stats.errors[0].count == 2);
}

test "dedup recording" {
    var stats: QualityStats = undefined;
    qualityStatsInit(&stats);

    qualityStatsRecordDedup(&stats, true, false, false, false);
    qualityStatsRecordDedup(&stats, false, false, true, false);

    try std.testing.expect(stats.dedup.total_checked == 2);
    try std.testing.expect(stats.dedup.l1_hits == 1);
    try std.testing.expect(stats.dedup.exact_hits == 1);
}

test "merge combines stats" {
    var a: QualityStats = undefined;
    var b: QualityStats = undefined;
    qualityStatsInit(&a);
    qualityStatsInit(&b);

    qualityStatsRecord(&a, 0, 0b1, 100.0, 90, "en", 0.9, "");
    qualityStatsRecord(&b, 0, 0b1, 200.0, 80, "fr", 0.8, "");

    qualityStatsMerge(&a, &b);

    try std.testing.expect(a.total_documents == 2);
    try std.testing.expect(a.success_documents == 2);
    try std.testing.expect(a.language_count == 2);
    try std.testing.expect(a.ocr_total == 2);
}

test "timing percentiles computed correctly" {
    var stats: QualityStats = undefined;
    qualityStatsInit(&stats);

    // Record 100 samples with increasing times
    for (0..100) |i| {
        qualityStatsRecord(&stats, 0, 0b1, @as(f64, @floatFromInt(i)) * 10.0, -1, "", 0.0, "");
    }

    const p = computeTimingPercentiles(&stats, 0);
    try std.testing.expect(p.min_us >= 0.0);
    try std.testing.expect(p.max_us >= 990.0);
    try std.testing.expect(p.p50_us >= 400.0 and p.p50_us <= 600.0);
    try std.testing.expect(p.p95_us >= 900.0);
}

test "JSON serialisation produces valid output" {
    var stats: QualityStats = undefined;
    qualityStatsInit(&stats);

    qualityStatsRecord(&stats, 0, 0b111, 1500.0, 85, "en", 0.95, "");
    qualityStatsRecord(&stats, 2, 0b1, 0.0, -1, "", 0.0, "timeout");
    qualityStatsRecordDedup(&stats, true, false, false, false);

    var buf: [8192]u8 = undefined;
    const len = qualityStatsToJson(&stats, &buf);
    try std.testing.expect(len > 0);

    const json = buf[0..len];
    // Check for expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"total_documents\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"success_documents\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"error_documents\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dedup\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"languages\":[") != null);
}

test "empty stats produces valid JSON" {
    var stats: QualityStats = undefined;
    qualityStatsInit(&stats);

    var buf: [4096]u8 = undefined;
    const len = qualityStatsToJson(&stats, &buf);
    try std.testing.expect(len > 0);

    const json = buf[0..len];
    try std.testing.expect(json[0] == '{');
    try std.testing.expect(json[len - 1] == '}');
}
