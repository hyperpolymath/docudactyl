// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Docudactyl — Flight Log & Travel Document Extraction Stage
//
// Extracts travel-related entities commonly found in flight logs, pilot
// manifests, and travel ledgers (e.g., the "Lolita Express" logs released
// during the Epstein civil and criminal proceedings).
//
// Extracts:
//   - Aircraft tail numbers  (e.g., N908JE, N212JE, G-EJES)
//   - IATA airport codes     (3 upper-case letters, e.g., TEB, PBI, JFK)
//   - ICAO airport codes     (4 upper-case letters, e.g., KTEB, KPBI, KJFK)
//   - Phone numbers          (US and international formats)
//   - Street addresses       (line-leading digits followed by road words)
//   - Passenger-list markers (lines beginning with "PAX", "PASSENGERS", etc.)
//
// Pattern-based (no ML dependency). Works on any text buffer extracted by
// the base parser. Results returned in a flat extern struct so callers
// across the C ABI (Chapel, Rust, Python ctypes, OCaml cstubs) see a
// stable layout.
//

const std = @import("std");

// ============================================================================
// Public Types
// ============================================================================

/// Maximum items stored per category. Sized for multi-page flight logs.
pub const MAX_ITEMS: usize = 256;

/// Maximum length of an extracted text span (null-terminated).
pub const MAX_SPAN_LEN: usize = 128;

/// Status codes returned by flight_log_process.
pub const FlightLogStatus = enum(c_int) {
    ok = 0,
    no_text = 1,
    text_too_short = 2,
};

/// Single extracted span with source offset.
pub const FlightSpan = extern struct {
    /// Start byte offset in original text.
    start: u32,
    /// Length in bytes.
    len: u32,
    /// Null-terminated matched text (truncated to MAX_SPAN_LEN-1).
    text: [MAX_SPAN_LEN]u8,
};

/// Results from flight-log / travel-document extraction.
pub const FlightLogResult = extern struct {
    status: c_int,

    tail_number_count: u32,
    tail_numbers: [MAX_ITEMS]FlightSpan,

    iata_code_count: u32,
    iata_codes: [MAX_ITEMS]FlightSpan,

    icao_code_count: u32,
    icao_codes: [MAX_ITEMS]FlightSpan,

    phone_count: u32,
    phones: [MAX_ITEMS]FlightSpan,

    address_count: u32,
    addresses: [MAX_ITEMS]FlightSpan,

    passenger_marker_count: u32,

    total_items: u32,
    summary: [512]u8,
};

// ============================================================================
// Internal Helpers
// ============================================================================

fn isUpperAscii(ch: u8) bool {
    return ch >= 'A' and ch <= 'Z';
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn isAlnum(ch: u8) bool {
    return isUpperAscii(ch) or isDigit(ch) or (ch >= 'a' and ch <= 'z');
}

fn isWordBoundary(text: []const u8, pos: usize) bool {
    if (pos == 0 or pos >= text.len) return true;
    const ch = text[pos];
    return !isAlnum(ch);
}

fn addSpan(
    buf: *[MAX_ITEMS]FlightSpan,
    count: *u32,
    start: usize,
    len: usize,
    text: []const u8,
) void {
    if (count.* >= MAX_ITEMS) return;
    const idx = count.*;
    count.* += 1;
    buf[idx].start = @intCast(start);
    buf[idx].len = @intCast(len);
    @memset(&buf[idx].text, 0);
    const copy_len = @min(len, MAX_SPAN_LEN - 1);
    if (start + copy_len <= text.len) {
        @memcpy(buf[idx].text[0..copy_len], text[start .. start + copy_len]);
    }
}

/// Known airport IATA/ICAO codes whitelisted to reduce false positives.
/// Focused on airports that appear in released Epstein flight logs and
/// common jurisdictions of interest.
const known_iata = std.StaticStringMap(void).initComptime(.{
    .{ "TEB", {} }, // Teterboro, NJ
    .{ "PBI", {} }, // Palm Beach, FL
    .{ "JFK", {} }, // New York JFK
    .{ "LGA", {} }, // New York LaGuardia
    .{ "EWR", {} }, // Newark
    .{ "MIA", {} }, // Miami
    .{ "FLL", {} }, // Fort Lauderdale
    .{ "BDL", {} }, // Hartford
    .{ "SAF", {} }, // Santa Fe
    .{ "ABQ", {} }, // Albuquerque
    .{ "STT", {} }, // St. Thomas, USVI
    .{ "SJU", {} }, // San Juan, PR
    .{ "LHR", {} }, // London Heathrow
    .{ "LGW", {} }, // London Gatwick
    .{ "FAB", {} }, // Farnborough
    .{ "LTN", {} }, // Luton
    .{ "CDG", {} }, // Paris CDG
    .{ "LBG", {} }, // Paris Le Bourget
    .{ "NCE", {} }, // Nice
    .{ "GVA", {} }, // Geneva
    .{ "ZRH", {} }, // Zurich
    .{ "VIE", {} }, // Vienna
    .{ "MAD", {} }, // Madrid
    .{ "BCN", {} }, // Barcelona
    .{ "FCO", {} }, // Rome Fiumicino
    .{ "DXB", {} }, // Dubai
    .{ "AUH", {} }, // Abu Dhabi
    .{ "RUH", {} }, // Riyadh
    .{ "DME", {} }, // Moscow Domodedovo
    .{ "SVO", {} }, // Moscow Sheremetyevo
    .{ "TLV", {} }, // Tel Aviv
    .{ "HKG", {} }, // Hong Kong
    .{ "SIN", {} }, // Singapore
    .{ "NRT", {} }, // Tokyo Narita
    .{ "HND", {} }, // Tokyo Haneda
});

const known_icao = std.StaticStringMap(void).initComptime(.{
    .{ "KTEB", {} },
    .{ "KPBI", {} },
    .{ "KJFK", {} },
    .{ "KLGA", {} },
    .{ "KEWR", {} },
    .{ "KMIA", {} },
    .{ "KFLL", {} },
    .{ "TIST", {} }, // St. Thomas
    .{ "TJSJ", {} }, // San Juan
    .{ "EGLL", {} }, // Heathrow
    .{ "EGKK", {} }, // Gatwick
    .{ "EGLF", {} }, // Farnborough
    .{ "LFPB", {} }, // Le Bourget
    .{ "LSGG", {} }, // Geneva
    .{ "LSZH", {} }, // Zurich
});

const passenger_markers = [_][]const u8{
    "PAX:",
    "PAX ",
    "PASSENGERS:",
    "PASSENGER:",
    "PASSENGER MANIFEST",
    "PASSENGER LIST",
    "MANIFEST:",
    "GUESTS:",
    "GUEST LIST",
};

const address_tokens = std.StaticStringMap(void).initComptime(.{
    .{ "STREET", {} }, .{ "ST", {} },   .{ "ST.", {} },
    .{ "AVENUE", {} }, .{ "AVE", {} },  .{ "AVE.", {} },
    .{ "ROAD", {} },   .{ "RD", {} },   .{ "RD.", {} },
    .{ "DRIVE", {} },  .{ "DR", {} },   .{ "DR.", {} },
    .{ "LANE", {} },   .{ "LN", {} },   .{ "LN.", {} },
    .{ "BOULEVARD", {} }, .{ "BLVD", {} }, .{ "BLVD.", {} },
    .{ "COURT", {} },  .{ "CT", {} },   .{ "CT.", {} },
    .{ "PLACE", {} },  .{ "PL", {} },   .{ "PL.", {} },
    .{ "WAY", {} },    .{ "HIGHWAY", {} }, .{ "HWY", {} },
    .{ "PARKWAY", {} }, .{ "PKWY", {} },
});

// ============================================================================
// Extractors
// ============================================================================

/// Tail numbers: FAA-registered aircraft begin with "N" followed by 1-5
/// alphanumerics (no O or I in the terminal characters per FAA rules, but
/// we accept slightly more liberally for OCR tolerance). UK/EU registrations
/// use prefixes like "G-", "D-", "F-", followed by 4 letters.
fn extractTailNumbers(text: []const u8, result: *FlightLogResult) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!isWordBoundary(text, i)) continue;
        const start = i + @as(usize, if (i == 0) 0 else 1);
        if (start >= text.len) break;

        // US pattern: N followed by 1-5 digits/letters.
        if (text[start] == 'N' and start + 2 < text.len and isDigit(text[start + 1])) {
            var end = start + 1;
            var alnum_count: usize = 0;
            while (end < text.len and isAlnum(text[end]) and alnum_count < 5) : (end += 1) {
                alnum_count += 1;
            }
            if (alnum_count >= 2 and alnum_count <= 5 and isWordBoundary(text, end)) {
                addSpan(&result.tail_numbers, &result.tail_number_count, start, end - start, text);
                i = end;
                continue;
            }
        }

        // Foreign pattern: LETTER-LETTERS (e.g. G-EJES, D-IIKA).
        if (isUpperAscii(text[start]) and start + 5 < text.len and text[start + 1] == '-') {
            var end = start + 2;
            var letter_count: usize = 0;
            while (end < text.len and isUpperAscii(text[end]) and letter_count < 5) : (end += 1) {
                letter_count += 1;
            }
            if (letter_count >= 3 and letter_count <= 5 and isWordBoundary(text, end)) {
                addSpan(&result.tail_numbers, &result.tail_number_count, start, end - start, text);
                i = end;
            }
        }
    }
}

/// IATA airport codes: three upper-case letters at word boundaries, cross-
/// referenced against a whitelist to reduce matches on unrelated acronyms.
fn extractAirportCodes(text: []const u8, result: *FlightLogResult) void {
    var i: usize = 0;
    while (i + 3 <= text.len) : (i += 1) {
        if (i != 0 and isAlnum(text[i - 1])) continue;

        // ICAO 4-letter check first (more specific).
        if (i + 4 <= text.len and
            isUpperAscii(text[i]) and isUpperAscii(text[i + 1]) and
            isUpperAscii(text[i + 2]) and isUpperAscii(text[i + 3]) and
            (i + 4 == text.len or !isAlnum(text[i + 4])))
        {
            const code = text[i .. i + 4];
            if (known_icao.has(code)) {
                addSpan(&result.icao_codes, &result.icao_code_count, i, 4, text);
                i += 3;
                continue;
            }
        }

        // IATA 3-letter check.
        if (isUpperAscii(text[i]) and isUpperAscii(text[i + 1]) and isUpperAscii(text[i + 2]) and
            (i + 3 == text.len or !isAlnum(text[i + 3])))
        {
            const code = text[i .. i + 3];
            if (known_iata.has(code)) {
                addSpan(&result.iata_codes, &result.iata_code_count, i, 3, text);
                i += 2;
            }
        }
    }
}

/// Phone numbers — accepts common US and international formats:
///   (212) 555-1234, 212-555-1234, 212.555.1234, +1 212 555 1234,
///   +44 20 7946 0958
fn extractPhones(text: []const u8, result: *FlightLogResult) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!isWordBoundary(text, i)) continue;
        const start = if (i == 0) i else i + 1;
        if (start >= text.len) break;

        var digit_count: usize = 0;
        var end = start;
        if (text[start] == '+') end += 1;
        if (end < text.len and text[end] == '(') end += 1;

        const scan_start = end;
        while (end < text.len and end - start < 20) : (end += 1) {
            const ch = text[end];
            if (isDigit(ch)) digit_count += 1
            else if (ch == ' ' or ch == '-' or ch == '.' or ch == '(' or ch == ')') {
                // separator
            } else break;
        }

        if (digit_count >= 10 and digit_count <= 15 and end > scan_start) {
            addSpan(&result.phones, &result.phone_count, start, end - start, text);
            i = end;
        }
    }
}

/// Street addresses — line-oriented heuristic: "<number> <words ending in
/// ROAD/STREET/AVENUE/etc.>".
fn extractAddresses(text: []const u8, result: *FlightLogResult) void {
    var line_start: usize = 0;
    while (line_start < text.len) {
        var line_end = line_start;
        while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
        const line = text[line_start..line_end];

        // Skip leading whitespace.
        var off: usize = 0;
        while (off < line.len and (line[off] == ' ' or line[off] == '\t')) : (off += 1) {}

        // Require the line to start with digits.
        if (off < line.len and isDigit(line[off])) {
            var scan = off;
            while (scan < line.len and isDigit(line[scan])) : (scan += 1) {}
            // At least one digit, followed by a space.
            if (scan > off and scan < line.len and line[scan] == ' ') {
                // Scan line for an address token (case-insensitive via upper-case compare).
                var word_start: usize = scan + 1;
                var j = word_start;
                var found = false;
                while (j <= line.len) : (j += 1) {
                    const at_end = (j == line.len) or (line[j] == ' ') or (line[j] == ',');
                    if (at_end and j > word_start) {
                        var upper_buf: [16]u8 = undefined;
                        const w = line[word_start..j];
                        if (w.len <= upper_buf.len) {
                            for (w, 0..) |ch, idx| {
                                upper_buf[idx] = if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
                            }
                            if (address_tokens.has(upper_buf[0..w.len])) {
                                found = true;
                                break;
                            }
                        }
                        word_start = j + 1;
                    }
                }
                if (found) {
                    addSpan(
                        &result.addresses,
                        &result.address_count,
                        line_start + off,
                        line.len - off,
                        text,
                    );
                }
            }
        }

        line_start = if (line_end < text.len) line_end + 1 else line_end;
    }
}

/// Passenger manifest markers: count lines that look like PAX blocks so the
/// investigator knows roughly how many discrete manifests are in a document.
fn countPassengerMarkers(text: []const u8, result: *FlightLogResult) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        for (passenger_markers) |marker| {
            if (i + marker.len <= text.len and std.mem.eql(u8, text[i .. i + marker.len], marker)) {
                result.passenger_marker_count += 1;
                i += marker.len - 1;
                break;
            }
        }
    }
}

// ============================================================================
// Public API
// ============================================================================

/// Process a text buffer, populating `result` with extracted entities.
pub fn flightLogProcess(text: []const u8, result: *FlightLogResult) FlightLogStatus {
    @memset(std.mem.asBytes(result), 0);

    if (text.len == 0) {
        result.status = @intFromEnum(FlightLogStatus.no_text);
        return .no_text;
    }
    if (text.len < 4) {
        result.status = @intFromEnum(FlightLogStatus.text_too_short);
        return .text_too_short;
    }

    extractTailNumbers(text, result);
    extractAirportCodes(text, result);
    extractPhones(text, result);
    extractAddresses(text, result);
    countPassengerMarkers(text, result);

    result.total_items =
        result.tail_number_count +
        result.iata_code_count +
        result.icao_code_count +
        result.phone_count +
        result.address_count +
        result.passenger_marker_count;

    var summary_buf: [512]u8 = undefined;
    const summary = std.fmt.bufPrint(
        &summary_buf,
        "{d} tail number(s), {d} IATA, {d} ICAO, {d} phone(s), {d} address(es), {d} manifest marker(s)",
        .{
            result.tail_number_count,
            result.iata_code_count,
            result.icao_code_count,
            result.phone_count,
            result.address_count,
            result.passenger_marker_count,
        },
    ) catch "Flight log extraction complete";
    @memcpy(result.summary[0..summary.len], summary);
    result.summary[summary.len] = 0;

    result.status = @intFromEnum(FlightLogStatus.ok);
    return .ok;
}

// ============================================================================
// C-ABI Exports
// ============================================================================

/// Process text for flight-log entities. Thread-safe: no shared state.
export fn ddac_flight_log_process(
    text_ptr: ?[*]const u8,
    text_len: usize,
    result: ?*FlightLogResult,
) c_int {
    const text = if (text_ptr) |p| p[0..text_len] else return 1;
    const res = result orelse return 1;
    return @intFromEnum(flightLogProcess(text, res));
}

// ============================================================================
// Tests
// ============================================================================

test "extract US tail numbers" {
    var result: FlightLogResult = undefined;
    const text = "Aircraft N908JE departed KTEB bound for KPBI. Also seen: N212JE, N724JE.";
    _ = flightLogProcess(text, &result);
    try std.testing.expect(result.tail_number_count >= 3);
}

test "extract IATA and ICAO codes" {
    var result: FlightLogResult = undefined;
    const text = "Departed TEB, arrived PBI via KJFK. Also: JFK, MIA, STT.";
    _ = flightLogProcess(text, &result);
    try std.testing.expect(result.iata_code_count >= 4);
    try std.testing.expect(result.icao_code_count >= 1);
}

test "extract phone numbers" {
    var result: FlightLogResult = undefined;
    const text = "Call (212) 555-1234 or +1 212 555 9999 for scheduling.";
    _ = flightLogProcess(text, &result);
    try std.testing.expect(result.phone_count >= 2);
}

test "extract addresses" {
    var result: FlightLogResult = undefined;
    const text =
        \\Property records:
        \\9 East 71st Street, New York
        \\358 El Brillo Way, Palm Beach
    ;
    _ = flightLogProcess(text, &result);
    try std.testing.expect(result.address_count >= 2);
}

test "passenger markers counted" {
    var result: FlightLogResult = undefined;
    const text =
        \\PAX: JE, GM, SK
        \\PASSENGERS: three
        \\MANIFEST: complete
    ;
    _ = flightLogProcess(text, &result);
    try std.testing.expect(result.passenger_marker_count >= 3);
}

test "empty input" {
    var result: FlightLogResult = undefined;
    const status = flightLogProcess("", &result);
    try std.testing.expect(status == .no_text);
}

test "rejects random 3-letter acronyms" {
    var result: FlightLogResult = undefined;
    const text = "The CEO of XYZ spoke with FBI and CIA.";
    _ = flightLogProcess(text, &result);
    // None of XYZ/CEO/FBI/CIA are in the IATA whitelist.
    try std.testing.expect(result.iata_code_count == 0);
}
