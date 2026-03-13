// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Docudactyl — Speaker Identification Stage
//
// Speaker identification for deposition and interview transcripts:
// - Detect Q/A patterns (depositions)
// - Track speaker turns ("MR. SMITH:", "THE WITNESS:", "BY MS. JONES:")
// - Count unique speakers
// - Calculate word count per speaker
// - Detect interruptions and cross-talk markers
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

const std = @import("std");

// ============================================================================
// Public Types
// ============================================================================

/// Maximum number of unique speakers tracked.
pub const MAX_SPEAKERS: usize = 64;

/// Maximum length of a speaker label.
pub const MAX_LABEL_LEN: usize = 128;

/// Status codes returned by speaker_id_process.
pub const SpeakerIdStatus = enum(c_int) {
    ok = 0,
    no_text = 1,
    text_too_short = 2,
    no_speakers_found = 3,
};

/// Per-speaker statistics.
pub const SpeakerStats = extern struct {
    /// Speaker label (null-terminated, e.g., "MR. SMITH" or "Q").
    label: [MAX_LABEL_LEN]u8,
    /// Number of turns (times this speaker spoke).
    turn_count: u32,
    /// Total words spoken.
    word_count: u32,
    /// Total characters spoken.
    char_count: u32,
    /// Whether this speaker is the examiner (Q/BY prefix).
    is_examiner: u8,
    /// Padding for alignment.
    _pad: [3]u8,
};

/// Results from speaker identification.
pub const SpeakerIdResult = extern struct {
    status: c_int,

    /// Number of unique speakers identified.
    speaker_count: u32,
    /// Per-speaker statistics.
    speakers: [MAX_SPEAKERS]SpeakerStats,

    /// Total number of speaker turns.
    total_turns: u32,
    /// Total words across all speakers.
    total_words: u32,

    /// Number of interruptions detected (lines with "--" or "...").
    interruption_count: u32,
    /// Number of cross-talk markers ("[simultaneous]", "[crosstalk]", etc.).
    crosstalk_count: u32,

    /// Whether Q/A deposition format was detected.
    is_deposition: u8,
    _pad: [3]u8,

    /// Summary text.
    summary: [512]u8,
};

// ============================================================================
// Internal Helpers
// ============================================================================

fn isAlpha(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z');
}

fn isUpper(ch: u8) bool {
    return ch >= 'A' and ch <= 'Z';
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r';
}

/// Count words in a text slice (whitespace-delimited).
fn countWords(text: []const u8) u32 {
    var count: u32 = 0;
    var in_word = false;
    for (text) |ch| {
        if (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t') {
            if (in_word) {
                count += 1;
                in_word = false;
            }
        } else {
            in_word = true;
        }
    }
    if (in_word) count += 1;
    return count;
}

/// Copy a label into a fixed buffer.
fn setLabel(dest: *[MAX_LABEL_LEN]u8, src: []const u8) void {
    @memset(dest, 0);
    const len = @min(src.len, MAX_LABEL_LEN - 1);
    @memcpy(dest[0..len], src[0..len]);
}

/// Known deposition speaker labels that appear at line beginnings.
const deposition_labels = [_][]const u8{
    "THE COURT:",
    "THE WITNESS:",
    "THE CLERK:",
    "THE REPORTER:",
    "THE INTERPRETER:",
    "THE VIDEOGRAPHER:",
    "THE BAILIFF:",
    "THE DEPONENT:",
    "A JUROR:",
    "THE FOREPERSON:",
};

/// Cross-talk markers.
const crosstalk_markers = [_][]const u8{
    "[simultaneous]",
    "[Simultaneous]",
    "[SIMULTANEOUS]",
    "[crosstalk]",
    "[Crosstalk]",
    "[CROSSTALK]",
    "[overlapping]",
    "[Overlapping]",
    "[OVERLAPPING]",
    "[speaking simultaneously]",
    "(simultaneous)",
    "(crosstalk)",
    "(overlapping)",
    "(speaking simultaneously)",
};

/// Find or create a speaker in the result. Returns the index, or null if full.
fn findOrAddSpeaker(result: *SpeakerIdResult, label: []const u8) ?usize {
    // Search existing speakers
    for (0..result.speaker_count) |idx| {
        const existing = std.mem.sliceTo(&result.speakers[idx].label, 0);
        if (std.mem.eql(u8, existing, label)) return idx;
    }

    // Add new speaker
    if (result.speaker_count >= MAX_SPEAKERS) return null;
    const idx = result.speaker_count;
    result.speaker_count += 1;
    @memset(std.mem.asBytes(&result.speakers[idx]), 0);
    setLabel(&result.speakers[idx].label, label);
    return idx;
}

/// Check if a line starts with "Q" or "Q." (examiner question) at the beginning.
fn isQLabel(line: []const u8) bool {
    if (line.len == 0) return false;
    if (line[0] != 'Q') return false;
    if (line.len == 1) return true;
    return line[1] == ':' or line[1] == '.' or line[1] == ' ';
}

/// Check if a line starts with "A" or "A." (witness answer) at the beginning.
fn isALabel(line: []const u8) bool {
    if (line.len == 0) return false;
    if (line[0] != 'A') return false;
    if (line.len == 1) return true;
    return line[1] == ':' or line[1] == '.' or line[1] == ' ';
}

/// Try to extract a speaker label from a line. Speaker labels are typically:
/// - "Q:" / "A:" (deposition format)
/// - "MR. SMITH:" / "MS. JONES:" / "DR. BROWN:"
/// - "THE WITNESS:" / "THE COURT:"
/// - "BY MR. SMITH:" / "BY MS. JONES:"
/// Returns the label text (without colon) and the offset past it, or null.
fn extractSpeakerLabel(line: []const u8) ?struct { label: []const u8, content_start: usize } {
    const trimmed = blk: {
        var start: usize = 0;
        while (start < line.len and isSpace(line[start])) start += 1;
        break :blk line[start..];
    };
    const trim_offset = line.len - trimmed.len;

    if (trimmed.len == 0) return null;

    // Q/A deposition pattern
    if (isQLabel(trimmed)) {
        var end: usize = 1;
        if (end < trimmed.len and (trimmed[end] == ':' or trimmed[end] == '.')) end += 1;
        while (end < trimmed.len and isSpace(trimmed[end])) end += 1;
        return .{ .label = "Q", .content_start = trim_offset + end };
    }
    if (isALabel(trimmed)) {
        var end: usize = 1;
        if (end < trimmed.len and (trimmed[end] == ':' or trimmed[end] == '.')) end += 1;
        while (end < trimmed.len and isSpace(trimmed[end])) end += 1;
        return .{ .label = "A", .content_start = trim_offset + end };
    }

    // Known deposition labels ("THE WITNESS:", "THE COURT:", etc.)
    for (deposition_labels) |dep_label| {
        if (trimmed.len >= dep_label.len and std.mem.eql(u8, trimmed[0..dep_label.len], dep_label)) {
            var end = dep_label.len;
            while (end < trimmed.len and isSpace(trimmed[end])) end += 1;
            // Remove trailing colon from label
            const label_end = dep_label.len - 1; // exclude ':'
            return .{ .label = trimmed[0..label_end], .content_start = trim_offset + end };
        }
    }

    // "BY MR./MS./MRS./DR. NAME:" pattern
    if (trimmed.len > 3 and std.mem.eql(u8, trimmed[0..3], "BY ")) {
        var end: usize = 3;
        // Scan to colon
        while (end < trimmed.len and end < 60 and trimmed[end] != ':') : (end += 1) {}
        if (end < trimmed.len and trimmed[end] == ':') {
            const label = trimmed[0..end]; // "BY MR. SMITH" (without colon)
            end += 1;
            while (end < trimmed.len and isSpace(trimmed[end])) end += 1;
            return .{ .label = label, .content_start = trim_offset + end };
        }
    }

    // "MR./MS./MRS./DR./JUDGE LASTNAME:" pattern
    const title_prefixes = [_][]const u8{
        "MR. ",  "MS. ",   "MRS. ", "DR. ",
        "Mr. ",  "Ms. ",   "Mrs. ", "Dr. ",
        "JUDGE ", "Judge ",
    };
    for (title_prefixes) |prefix| {
        if (trimmed.len > prefix.len and std.mem.eql(u8, trimmed[0..prefix.len], prefix)) {
            // Scan to colon
            var end = prefix.len;
            while (end < trimmed.len and end < 60 and trimmed[end] != ':' and trimmed[end] != '\n') : (end += 1) {}
            if (end < trimmed.len and trimmed[end] == ':') {
                const label = trimmed[0..end];
                end += 1;
                while (end < trimmed.len and isSpace(trimmed[end])) end += 1;
                return .{ .label = label, .content_start = trim_offset + end };
            }
        }
    }

    // Generic "UPPERCASE LABEL:" pattern (at least 2 chars, all caps + spaces/periods)
    {
        var end: usize = 0;
        var has_alpha = false;
        while (end < trimmed.len and end < 50 and trimmed[end] != ':') : (end += 1) {
            const ch = trimmed[end];
            if (isUpper(ch)) has_alpha = true
            else if (ch != ' ' and ch != '.' and ch != '-') break;
        }
        if (has_alpha and end >= 2 and end < trimmed.len and trimmed[end] == ':') {
            const label = trimmed[0..end];
            var skip = end + 1;
            while (skip < trimmed.len and isSpace(trimmed[skip])) skip += 1;
            return .{ .label = label, .content_start = trim_offset + skip };
        }
    }

    return null;
}

// ============================================================================
// Public API
// ============================================================================

/// Process text to identify speakers and compute per-speaker statistics.
pub fn speakerIdProcess(text: []const u8, result: *SpeakerIdResult) SpeakerIdStatus {
    @memset(std.mem.asBytes(result), 0);

    if (text.len == 0) {
        result.status = @intFromEnum(SpeakerIdStatus.no_text);
        return .no_text;
    }

    if (text.len < 5) {
        result.status = @intFromEnum(SpeakerIdStatus.text_too_short);
        return .text_too_short;
    }

    // Process line by line
    var current_speaker: ?usize = null;
    var has_q = false;
    var has_a = false;

    var line_start: usize = 0;
    while (line_start < text.len) {
        // Find end of line
        var line_end = line_start;
        while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
        const line = text[line_start..line_end];

        // Check for cross-talk markers
        for (crosstalk_markers) |marker| {
            if (line.len >= marker.len) {
                var search_pos: usize = 0;
                while (search_pos + marker.len <= line.len) : (search_pos += 1) {
                    if (std.mem.eql(u8, line[search_pos .. search_pos + marker.len], marker)) {
                        result.crosstalk_count += 1;
                        break;
                    }
                }
            }
        }

        // Check for interruption markers
        if (line.len >= 2) {
            // Check for "--" indicating interrupted speech
            var search_pos: usize = 0;
            while (search_pos + 2 <= line.len) : (search_pos += 1) {
                if (line[search_pos] == '-' and line[search_pos + 1] == '-') {
                    result.interruption_count += 1;
                    break;
                }
            }
        }

        // Try to extract a speaker label
        if (extractSpeakerLabel(line)) |extracted| {
            if (std.mem.eql(u8, extracted.label, "Q")) has_q = true;
            if (std.mem.eql(u8, extracted.label, "A")) has_a = true;

            if (findOrAddSpeaker(result, extracted.label)) |idx| {
                current_speaker = idx;
                result.speakers[idx].turn_count += 1;
                result.total_turns += 1;

                // Check if this is an examiner
                if (std.mem.eql(u8, extracted.label, "Q") or
                    (extracted.label.len > 3 and std.mem.eql(u8, extracted.label[0..3], "BY ")))
                {
                    result.speakers[idx].is_examiner = 1;
                }

                // Count words in the content portion of this line
                if (extracted.content_start < line.len) {
                    const content = line[extracted.content_start..];
                    const wc = countWords(content);
                    result.speakers[idx].word_count += wc;
                    result.speakers[idx].char_count += @intCast(content.len);
                    result.total_words += wc;
                }
            }
        } else {
            // Continuation line — attribute to current speaker
            if (current_speaker) |idx| {
                // Only count non-empty, non-whitespace lines
                var has_content = false;
                for (line) |ch| {
                    if (!isSpace(ch) and ch != '\n') {
                        has_content = true;
                        break;
                    }
                }
                if (has_content) {
                    const wc = countWords(line);
                    result.speakers[idx].word_count += wc;
                    result.speakers[idx].char_count += @intCast(line.len);
                    result.total_words += wc;
                }
            }
        }

        // Advance to next line
        line_start = if (line_end < text.len) line_end + 1 else line_end;
    }

    // Determine if this is a deposition format
    result.is_deposition = if (has_q and has_a) 1 else 0;

    if (result.speaker_count == 0) {
        result.status = @intFromEnum(SpeakerIdStatus.no_speakers_found);
        // Write summary even for no speakers
        const summary = "No speaker labels detected in text";
        @memcpy(result.summary[0..summary.len], summary);
        result.summary[summary.len] = 0;
        return .no_speakers_found;
    }

    // Write summary
    var summary_buf: [512]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "{d} speaker(s), {d} turns, {d} words, {d} interruptions, {d} crosstalk{s}", .{
        result.speaker_count,
        result.total_turns,
        result.total_words,
        result.interruption_count,
        result.crosstalk_count,
        if (result.is_deposition == 1) ", deposition format" else "",
    }) catch "Speaker identification complete";
    @memcpy(result.summary[0..summary.len], summary);
    result.summary[summary.len] = 0;

    result.status = @intFromEnum(SpeakerIdStatus.ok);
    return .ok;
}

// ============================================================================
// C-ABI Exports
// ============================================================================

/// C-ABI entry point for speaker identification.
export fn ddac_speaker_id_process(
    text_ptr: ?[*]const u8,
    text_len: usize,
    result: ?*SpeakerIdResult,
) c_int {
    const text = if (text_ptr) |p| p[0..text_len] else return 1;
    const res = result orelse return 1;
    const status = speakerIdProcess(text, res);
    return @intFromEnum(status);
}

// ============================================================================
// Tests
// ============================================================================

test "detect Q/A deposition format" {
    var result: SpeakerIdResult = undefined;
    const text =
        \\Q: State your name for the record.
        \\A: John Smith.
        \\Q: Where do you reside?
        \\A: New York, New York.
    ;
    _ = speakerIdProcess(text, &result);
    try std.testing.expect(result.is_deposition == 1);
    try std.testing.expect(result.speaker_count == 2);
    try std.testing.expect(result.total_turns == 4);
}

test "detect named speakers" {
    var result: SpeakerIdResult = undefined;
    const text =
        \\MR. SMITH: Good morning.
        \\THE WITNESS: Good morning.
        \\MR. SMITH: Please state your name.
        \\THE WITNESS: Jane Doe.
    ;
    _ = speakerIdProcess(text, &result);
    try std.testing.expect(result.speaker_count == 2);
    try std.testing.expect(result.total_turns == 4);
}

test "detect BY prefix examiner" {
    var result: SpeakerIdResult = undefined;
    const text =
        \\BY MR. JONES: Can you tell us what happened?
        \\THE WITNESS: I was at home.
        \\BY MR. JONES: And then?
        \\THE WITNESS: I heard a noise.
    ;
    _ = speakerIdProcess(text, &result);
    try std.testing.expect(result.speaker_count == 2);

    // Find the examiner
    var found_examiner = false;
    for (0..result.speaker_count) |idx| {
        if (result.speakers[idx].is_examiner == 1) {
            found_examiner = true;
            break;
        }
    }
    try std.testing.expect(found_examiner);
}

test "detect interruptions" {
    var result: SpeakerIdResult = undefined;
    const text =
        \\Q: Were you present when--
        \\A: Yes, I was there.
        \\Q: Let me finish. Were you present when the incident occurred?
        \\A: Yes.
    ;
    _ = speakerIdProcess(text, &result);
    try std.testing.expect(result.interruption_count >= 1);
}

test "detect crosstalk markers" {
    var result: SpeakerIdResult = undefined;
    const text =
        \\MR. SMITH: I object to this line--
        \\[simultaneous]
        \\THE COURT: Overruled.
    ;
    _ = speakerIdProcess(text, &result);
    try std.testing.expect(result.crosstalk_count >= 1);
}

test "word counting per speaker" {
    var result: SpeakerIdResult = undefined;
    const text =
        \\Q: Hello world.
        \\A: Good morning to you.
    ;
    _ = speakerIdProcess(text, &result);
    try std.testing.expect(result.total_words >= 7); // "Hello world" + "Good morning to you"
}

test "THE COURT label detection" {
    var result: SpeakerIdResult = undefined;
    const text =
        \\THE COURT: The motion is denied.
        \\MR. SMITH: Thank you, Your Honor.
    ;
    _ = speakerIdProcess(text, &result);
    try std.testing.expect(result.speaker_count == 2);
}

test "empty text returns no_text" {
    var result: SpeakerIdResult = undefined;
    const status = speakerIdProcess("", &result);
    try std.testing.expect(status == .no_text);
}

test "no speakers returns no_speakers_found" {
    var result: SpeakerIdResult = undefined;
    const text = "This is just a paragraph of text with no speaker labels at all.";
    const status = speakerIdProcess(text, &result);
    try std.testing.expect(status == .no_speakers_found);
}

test "continuation lines attributed to current speaker" {
    var result: SpeakerIdResult = undefined;
    const text =
        \\Q: Can you describe what
        \\happened on that day in
        \\full detail?
        \\A: Yes.
    ;
    _ = speakerIdProcess(text, &result);
    // Q should have words from all 3 lines
    for (0..result.speaker_count) |idx| {
        const label = std.mem.sliceTo(&result.speakers[idx].label, 0);
        if (std.mem.eql(u8, label, "Q")) {
            try std.testing.expect(result.speakers[idx].word_count >= 9);
            break;
        }
    }
}
