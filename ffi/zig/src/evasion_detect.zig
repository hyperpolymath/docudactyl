// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Docudactyl — Evasion / Non-Answer Detection for Depositions
//
// Detects common evasive-answer patterns in deposition transcripts and
// interview records:
//   - "I don't recall" / "I do not recall"
//   - "I don't remember"
//   - "Not to my knowledge"
//   - "I'm not sure"
//   - "I have no recollection"
//   - "I couldn't say"
//   - "I'd have to check"
//   - "Asked and answered" (lawyer interjection)
//   - Fifth-Amendment invocations
//
// Output:
//   - Per-category counts
//   - Total evasion events
//   - Evasion rate (events per 1000 tokens) as a crude metric
//
// Rationale:
//   In Epstein-era depositions, evasive answers cluster around specific
//   topics (names of associates, specific dates, financial arrangements).
//   Surfacing the density of evasion lets investigators prioritise which
//   sections deserve close reading or cross-deposition comparison.
//
// Pattern-based — case-insensitive matching. Works on any extracted text.
//

const std = @import("std");

// ============================================================================
// Public Types
// ============================================================================

pub const EvasionStatus = enum(c_int) {
    ok = 0,
    no_text = 1,
};

pub const EvasionCategory = enum(u8) {
    no_recall = 0,
    no_memory = 1,
    not_sure = 2,
    no_knowledge = 3,
    would_check = 4,
    asked_answered = 5,
    fifth_amendment = 6,
    decline_answer = 7,
};

pub const CATEGORY_COUNT: usize = 8;

/// Evasion detection results — flat structure for C ABI stability.
pub const EvasionResult = extern struct {
    status: c_int,

    /// Counts indexed by EvasionCategory.
    category_counts: [CATEGORY_COUNT]u32,

    total_events: u32,
    total_tokens: u32,

    /// Evasion events per 1000 tokens, fixed-point (×1000). An "evasion
    /// rate" of 12500 means 12.5 events per 1000 tokens.
    events_per_1k_fixed: u32,

    summary: [512]u8,
};

// ============================================================================
// Patterns
// ============================================================================

/// Case-insensitive substring that marks an evasion. Short patterns
/// (e.g. "no recall") risk false positives; we keep phrases at 3+ words
/// to minimise noise.
const Pattern = struct {
    phrase: []const u8,
    category: EvasionCategory,
};

const patterns = [_]Pattern{
    // no_recall
    .{ .phrase = "i don't recall", .category = .no_recall },
    .{ .phrase = "i do not recall", .category = .no_recall },
    .{ .phrase = "i cannot recall", .category = .no_recall },
    .{ .phrase = "i can't recall", .category = .no_recall },
    .{ .phrase = "i have no recollection", .category = .no_recall },
    .{ .phrase = "i don't have any recollection", .category = .no_recall },
    .{ .phrase = "no recollection of", .category = .no_recall },

    // no_memory
    .{ .phrase = "i don't remember", .category = .no_memory },
    .{ .phrase = "i do not remember", .category = .no_memory },
    .{ .phrase = "i can't remember", .category = .no_memory },
    .{ .phrase = "i cannot remember", .category = .no_memory },
    .{ .phrase = "don't have a memory", .category = .no_memory },

    // not_sure
    .{ .phrase = "i'm not sure", .category = .not_sure },
    .{ .phrase = "i am not sure", .category = .not_sure },
    .{ .phrase = "i'm not certain", .category = .not_sure },
    .{ .phrase = "i am not certain", .category = .not_sure },
    .{ .phrase = "i couldn't say", .category = .not_sure },
    .{ .phrase = "i could not say", .category = .not_sure },

    // no_knowledge
    .{ .phrase = "not to my knowledge", .category = .no_knowledge },
    .{ .phrase = "i have no knowledge", .category = .no_knowledge },
    .{ .phrase = "i don't have any knowledge", .category = .no_knowledge },
    .{ .phrase = "i'm not aware", .category = .no_knowledge },
    .{ .phrase = "i am not aware", .category = .no_knowledge },

    // would_check
    .{ .phrase = "i'd have to check", .category = .would_check },
    .{ .phrase = "i would have to check", .category = .would_check },
    .{ .phrase = "i'd have to look", .category = .would_check },
    .{ .phrase = "i would need to check", .category = .would_check },

    // asked_answered (lawyer interjection)
    .{ .phrase = "asked and answered", .category = .asked_answered },

    // fifth_amendment
    .{ .phrase = "fifth amendment", .category = .fifth_amendment },
    .{ .phrase = "invoke the fifth", .category = .fifth_amendment },
    .{ .phrase = "on the advice of counsel", .category = .fifth_amendment },
    .{ .phrase = "i decline to answer", .category = .decline_answer },
    .{ .phrase = "decline to answer on", .category = .decline_answer },
    .{ .phrase = "refuse to answer", .category = .decline_answer },
};

// ============================================================================
// Helpers
// ============================================================================

fn toLowerAscii(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

/// Case-insensitive substring search. `needle` is assumed to be pre-lowered.
fn containsCI(haystack: []const u8, offset: usize, needle: []const u8) bool {
    if (needle.len > haystack.len - offset) return false;
    var i: usize = 0;
    while (i < needle.len) : (i += 1) {
        if (toLowerAscii(haystack[offset + i]) != needle[i]) return false;
    }
    return true;
}

fn countTokens(text: []const u8) u32 {
    var count: u32 = 0;
    var in_tok = false;
    for (text) |ch| {
        if (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t' or ch == ',' or ch == '.' or ch == ';') {
            if (in_tok) {
                count += 1;
                in_tok = false;
            }
        } else {
            in_tok = true;
        }
    }
    if (in_tok) count += 1;
    return count;
}

// ============================================================================
// Public API
// ============================================================================

pub fn evasionDetect(text: []const u8, result: *EvasionResult) EvasionStatus {
    @memset(std.mem.asBytes(result), 0);

    if (text.len == 0) {
        result.status = @intFromEnum(EvasionStatus.no_text);
        return .no_text;
    }

    result.total_tokens = countTokens(text);

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        inline for (patterns) |p| {
            if (containsCI(text, i, p.phrase)) {
                const cat = @intFromEnum(p.category);
                result.category_counts[cat] += 1;
                result.total_events += 1;
                i += p.phrase.len - 1; // skip past match (-1 to offset the loop += 1)
                break;
            }
        }
    }

    if (result.total_tokens > 0) {
        // events × 1000 / tokens × 1000 = events per 1k with 3-decimal fixed point.
        const num: u64 = @as(u64, result.total_events) * 1_000_000;
        result.events_per_1k_fixed = @intCast(num / @as(u64, result.total_tokens));
    }

    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf,
        "{d} evasion event(s) in {d} tokens (no_recall={d}, no_memory={d}, not_sure={d}, no_knowledge={d}, would_check={d}, asked_answered={d}, fifth={d}, declined={d})",
        .{
            result.total_events,
            result.total_tokens,
            result.category_counts[0],
            result.category_counts[1],
            result.category_counts[2],
            result.category_counts[3],
            result.category_counts[4],
            result.category_counts[5],
            result.category_counts[6],
            result.category_counts[7],
        },
    ) catch "Evasion detection complete";
    @memcpy(result.summary[0..s.len], s);
    result.summary[s.len] = 0;

    result.status = @intFromEnum(EvasionStatus.ok);
    return .ok;
}

// ============================================================================
// C-ABI Exports
// ============================================================================

export fn ddac_evasion_detect(
    text_ptr: ?[*]const u8,
    text_len: usize,
    result: ?*EvasionResult,
) c_int {
    const text = if (text_ptr) |p| p[0..text_len] else return 1;
    const res = result orelse return 1;
    return @intFromEnum(evasionDetect(text, res));
}

// ============================================================================
// Tests
// ============================================================================

test "detect no_recall patterns" {
    var r: EvasionResult = undefined;
    const text = "Q: Did you meet him? A: I don't recall. Q: Ever? A: I cannot recall that.";
    _ = evasionDetect(text, &r);
    try std.testing.expect(r.category_counts[@intFromEnum(EvasionCategory.no_recall)] >= 2);
}

test "detect mixed categories" {
    var r: EvasionResult = undefined;
    const text =
        \\Q: Did you see him on that day?
        \\A: I don't remember.
        \\Q: Not to your knowledge?
        \\A: Not to my knowledge.
        \\Q: Can you confirm?
        \\A: I'm not sure.
        \\A: I'd have to check my records.
    ;
    _ = evasionDetect(text, &r);
    try std.testing.expect(r.category_counts[@intFromEnum(EvasionCategory.no_memory)] >= 1);
    try std.testing.expect(r.category_counts[@intFromEnum(EvasionCategory.no_knowledge)] >= 1);
    try std.testing.expect(r.category_counts[@intFromEnum(EvasionCategory.not_sure)] >= 1);
    try std.testing.expect(r.category_counts[@intFromEnum(EvasionCategory.would_check)] >= 1);
    try std.testing.expect(r.total_events >= 4);
}

test "fifth amendment" {
    var r: EvasionResult = undefined;
    const text = "On the advice of counsel, I invoke the Fifth Amendment and decline to answer.";
    _ = evasionDetect(text, &r);
    try std.testing.expect(r.category_counts[@intFromEnum(EvasionCategory.fifth_amendment)] >= 1);
}

test "events per 1k tokens" {
    var r: EvasionResult = undefined;
    const text = "I don't recall anything about that meeting or those people or that topic at all.";
    _ = evasionDetect(text, &r);
    // One event, ~15 tokens → ~66 per 1k (in fixed × 1000 = 66000-ish).
    try std.testing.expect(r.events_per_1k_fixed > 0);
}

test "case insensitive" {
    var r1: EvasionResult = undefined;
    var r2: EvasionResult = undefined;
    _ = evasionDetect("I DON'T RECALL", &r1);
    _ = evasionDetect("i don't recall", &r2);
    try std.testing.expectEqual(r1.total_events, r2.total_events);
}

test "empty text returns no_text" {
    var r: EvasionResult = undefined;
    const status = evasionDetect("", &r);
    try std.testing.expect(status == .no_text);
}
