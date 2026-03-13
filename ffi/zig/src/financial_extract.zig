// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Docudactyl — Financial Data Extraction Stage
//
// Extracts financial data from documents:
// - Currency amounts (USD, GBP, EUR, CHF patterns)
// - Account numbers (IBAN, SWIFT/BIC, US routing+account)
// - Transaction descriptions
// - Date-amount pairs
// - Wire transfer references
// - Check numbers
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

const std = @import("std");

// ============================================================================
// Public Types
// ============================================================================

/// Maximum extracted items per category.
pub const MAX_ITEMS: usize = 512;

/// Maximum length of an extracted text span.
pub const MAX_SPAN_LEN: usize = 256;

/// Status codes returned by financial_extract_process.
pub const FinancialStatus = enum(c_int) {
    ok = 0,
    no_text = 1,
    text_too_short = 2,
};

/// A single extracted financial text span.
pub const FinancialSpan = extern struct {
    start: u32,
    len: u32,
    text: [MAX_SPAN_LEN]u8,
};

/// Currency amount with parsed value.
pub const CurrencyAmount = extern struct {
    /// Byte offset in source text.
    start: u32,
    /// Length of the matched span.
    len: u32,
    /// Matched text (null-terminated).
    text: [MAX_SPAN_LEN]u8,
    /// Parsed numeric value (best-effort, 0.0 if unparseable).
    value: f64,
    /// 3-letter currency code (null-terminated).
    currency: [4]u8,
};

/// Results from financial data extraction.
pub const FinancialResult = extern struct {
    status: c_int,

    // ── Currency Amounts ──────────────────────────────────────────────
    amount_count: u32,
    amounts: [MAX_ITEMS]CurrencyAmount,

    // ── Account Numbers (IBAN, SWIFT, routing) ────────────────────────
    account_count: u32,
    accounts: [MAX_ITEMS]FinancialSpan,

    // ── Wire Transfer References ──────────────────────────────────────
    wire_ref_count: u32,
    wire_refs: [MAX_ITEMS]FinancialSpan,

    // ── Check Numbers ─────────────────────────────────────────────────
    check_count: u32,
    checks: [MAX_ITEMS]FinancialSpan,

    // ── Date-Amount Pairs ─────────────────────────────────────────────
    date_amount_count: u32,
    date_amounts: [MAX_ITEMS]FinancialSpan,

    // ── Summary ───────────────────────────────────────────────────────
    total_items: u32,
    summary: [512]u8,
};

// ============================================================================
// Internal Helpers
// ============================================================================

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn isAlpha(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z');
}

fn isAlphaNum(ch: u8) bool {
    return isDigit(ch) or isAlpha(ch);
}

fn isUpper(ch: u8) bool {
    return ch >= 'A' and ch <= 'Z';
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn makeSpan(text: []const u8, start: usize, len: usize) FinancialSpan {
    var span: FinancialSpan = undefined;
    @memset(&span.text, 0);
    span.start = @intCast(start);
    span.len = @intCast(len);
    const copy_len = @min(len, MAX_SPAN_LEN - 1);
    @memcpy(span.text[0..copy_len], text[start .. start + copy_len]);
    span.text[copy_len] = 0;
    return span;
}

/// Parse a decimal number from text, ignoring commas. Returns (value, bytes_consumed).
fn parseDecimal(text: []const u8, pos: usize) struct { value: f64, end: usize } {
    var i = pos;
    var int_part: f64 = 0.0;
    var consumed = false;

    // Integer part (with commas as thousand separators)
    while (i < text.len and (isDigit(text[i]) or text[i] == ',')) : (i += 1) {
        if (isDigit(text[i])) {
            int_part = int_part * 10.0 + @as(f64, @floatFromInt(text[i] - '0'));
            consumed = true;
        }
    }

    if (!consumed) return .{ .value = 0.0, .end = pos };

    // Fractional part
    if (i < text.len and text[i] == '.') {
        i += 1;
        var frac: f64 = 0.0;
        var frac_div: f64 = 10.0;
        while (i < text.len and isDigit(text[i])) : (i += 1) {
            frac += @as(f64, @floatFromInt(text[i] - '0')) / frac_div;
            frac_div *= 10.0;
        }
        return .{ .value = int_part + frac, .end = i };
    }

    return .{ .value = int_part, .end = i };
}

fn setCurrency(dest: *[4]u8, code: []const u8) void {
    @memset(dest, 0);
    const copy_len = @min(code.len, 3);
    @memcpy(dest[0..copy_len], code[0..copy_len]);
}

// ============================================================================
// Pattern Extractors
// ============================================================================

/// Extract currency amounts: $1,234.56, £100, EUR 5000, etc.
fn extractCurrencyAmounts(text: []const u8, result: *FinancialResult) void {
    var i: usize = 0;

    while (i < text.len) : (i += 1) {
        // Pattern 1: Currency symbol ($, £, €) followed by digits
        if (text[i] == '$') {
            var j = i + 1;
            // Skip optional space
            while (j < text.len and text[j] == ' ') j += 1;
            if (j < text.len and isDigit(text[j])) {
                const parsed = parseDecimal(text, j);
                if (parsed.end > j and result.amount_count < MAX_ITEMS) {
                    var amt: CurrencyAmount = undefined;
                    @memset(&amt.text, 0);
                    amt.start = @intCast(i);
                    amt.len = @intCast(parsed.end - i);
                    const copy_len = @min(parsed.end - i, MAX_SPAN_LEN - 1);
                    @memcpy(amt.text[0..copy_len], text[i .. i + copy_len]);
                    amt.text[copy_len] = 0;
                    amt.value = parsed.value;
                    setCurrency(&amt.currency, "USD");
                    result.amounts[result.amount_count] = amt;
                    result.amount_count += 1;
                    i = parsed.end;
                    continue;
                }
            }
        }

        // £ (UTF-8: C2 A3)
        if (text[i] == 0xC2 and i + 1 < text.len and text[i + 1] == 0xA3) {
            var j = i + 2;
            while (j < text.len and text[j] == ' ') j += 1;
            if (j < text.len and isDigit(text[j])) {
                const parsed = parseDecimal(text, j);
                if (parsed.end > j and result.amount_count < MAX_ITEMS) {
                    var amt: CurrencyAmount = undefined;
                    @memset(&amt.text, 0);
                    amt.start = @intCast(i);
                    amt.len = @intCast(parsed.end - i);
                    const copy_len = @min(parsed.end - i, MAX_SPAN_LEN - 1);
                    @memcpy(amt.text[0..copy_len], text[i .. i + copy_len]);
                    amt.text[copy_len] = 0;
                    amt.value = parsed.value;
                    setCurrency(&amt.currency, "GBP");
                    result.amounts[result.amount_count] = amt;
                    result.amount_count += 1;
                    i = parsed.end;
                    continue;
                }
            }
        }

        // € (UTF-8: E2 82 AC)
        if (text[i] == 0xE2 and i + 2 < text.len and text[i + 1] == 0x82 and text[i + 2] == 0xAC) {
            var j = i + 3;
            while (j < text.len and text[j] == ' ') j += 1;
            if (j < text.len and isDigit(text[j])) {
                const parsed = parseDecimal(text, j);
                if (parsed.end > j and result.amount_count < MAX_ITEMS) {
                    var amt: CurrencyAmount = undefined;
                    @memset(&amt.text, 0);
                    amt.start = @intCast(i);
                    amt.len = @intCast(parsed.end - i);
                    const copy_len = @min(parsed.end - i, MAX_SPAN_LEN - 1);
                    @memcpy(amt.text[0..copy_len], text[i .. i + copy_len]);
                    amt.text[copy_len] = 0;
                    amt.value = parsed.value;
                    setCurrency(&amt.currency, "EUR");
                    result.amounts[result.amount_count] = amt;
                    result.amount_count += 1;
                    i = parsed.end;
                    continue;
                }
            }
        }

        // Pattern 2: Currency code followed by space and digits: "USD 1234.56"
        if (i + 4 < text.len and isUpper(text[i]) and isUpper(text[i + 1]) and isUpper(text[i + 2]) and text[i + 3] == ' ') {
            const code = text[i .. i + 3];
            const known_codes = [_][]const u8{
                "USD", "GBP", "EUR", "CHF", "JPY", "CAD", "AUD", "NZD",
                "SGD", "HKD", "SEK", "NOK", "DKK", "ZAR", "BRL", "MXN",
            };
            var is_currency = false;
            for (known_codes) |kc| {
                if (std.mem.eql(u8, code, kc)) {
                    is_currency = true;
                    break;
                }
            }
            if (is_currency) {
                var j = i + 4;
                if (j < text.len and isDigit(text[j])) {
                    const parsed = parseDecimal(text, j);
                    if (parsed.end > j and result.amount_count < MAX_ITEMS) {
                        var amt: CurrencyAmount = undefined;
                        @memset(&amt.text, 0);
                        amt.start = @intCast(i);
                        amt.len = @intCast(parsed.end - i);
                        const copy_len = @min(parsed.end - i, MAX_SPAN_LEN - 1);
                        @memcpy(amt.text[0..copy_len], text[i .. i + copy_len]);
                        amt.text[copy_len] = 0;
                        amt.value = parsed.value;
                        setCurrency(&amt.currency, code);
                        result.amounts[result.amount_count] = amt;
                        result.amount_count += 1;
                        i = parsed.end;
                        continue;
                    }
                }
            }
        }
    }
}

/// Validate IBAN checksum (ISO 13616). Returns true if check digits are valid.
fn validateIbanChecksum(iban: []const u8) bool {
    if (iban.len < 5 or iban.len > 34) return false;

    // Rearrange: move first 4 chars to end
    // Convert letters to numbers (A=10, B=11, ..., Z=35)
    // Compute modulo 97
    var digits: [128]u8 = undefined;
    var dlen: usize = 0;

    // Characters 4..end, then 0..3
    var idx: usize = 4;
    while (idx < iban.len) : (idx += 1) {
        const ch = iban[idx];
        if (isDigit(ch)) {
            if (dlen >= 127) return false;
            digits[dlen] = ch - '0';
            dlen += 1;
        } else if (isUpper(ch)) {
            const val = ch - 'A' + 10;
            if (dlen + 1 >= 127) return false;
            digits[dlen] = val / 10;
            digits[dlen + 1] = val % 10;
            dlen += 2;
        } else return false;
    }
    for (0..4) |ci| {
        const ch = iban[ci];
        if (isDigit(ch)) {
            if (dlen >= 127) return false;
            digits[dlen] = ch - '0';
            dlen += 1;
        } else if (isUpper(ch)) {
            const val = ch - 'A' + 10;
            if (dlen + 1 >= 127) return false;
            digits[dlen] = val / 10;
            digits[dlen + 1] = val % 10;
            dlen += 2;
        } else return false;
    }

    // Compute mod 97 of the digit sequence
    var remainder: u32 = 0;
    for (0..dlen) |di| {
        remainder = (remainder * 10 + digits[di]) % 97;
    }

    return remainder == 1;
}

/// Extract IBAN numbers: 2 letter country + 2 check digits + up to 30 alphanumeric.
fn extractIbans(text: []const u8, result: *FinancialResult) void {
    var i: usize = 0;

    while (i + 5 < text.len) : (i += 1) {
        // IBAN starts with two uppercase letters + two digits
        if (!isUpper(text[i]) or !isUpper(text[i + 1])) continue;
        if (!isDigit(text[i + 2]) or !isDigit(text[i + 3])) continue;

        // Must be at word boundary
        if (i > 0 and isAlphaNum(text[i - 1])) continue;

        // Scan alphanumeric characters (up to 34 total including country+check)
        var j = i + 4;
        while (j < text.len and isAlphaNum(text[j]) and (j - i) < 34) : (j += 1) {}

        const iban_len = j - i;
        if (iban_len < 15 or iban_len > 34) continue;

        // Validate checksum
        const iban_text = text[i..j];
        // Convert to uppercase for validation (already uppercase from our check)
        if (validateIbanChecksum(iban_text)) {
            if (result.account_count < MAX_ITEMS) {
                result.accounts[result.account_count] = makeSpan(text, i, iban_len);
                result.account_count += 1;
            }
            i = j;
        }
    }
}

/// Extract SWIFT/BIC codes: 8 or 11 uppercase alphanumeric characters.
/// Format: BBBBCCLL or BBBBCCLLBBB (bank, country, location, branch).
fn extractSwiftCodes(text: []const u8, result: *FinancialResult) void {
    var i: usize = 0;

    while (i + 8 <= text.len) : (i += 1) {
        // Must be at word boundary
        if (i > 0 and isAlphaNum(text[i - 1])) continue;

        // First 4: bank code (letters)
        if (!isUpper(text[i]) or !isUpper(text[i + 1]) or
            !isUpper(text[i + 2]) or !isUpper(text[i + 3]))
            continue;

        // Next 2: country code (letters)
        if (!isUpper(text[i + 4]) or !isUpper(text[i + 5])) continue;

        // Next 2: location code (alphanumeric)
        if (!isAlphaNum(text[i + 6]) or !isAlphaNum(text[i + 7])) continue;

        // Check for 11-character variant (with branch code)
        var code_len: usize = 8;
        if (i + 11 <= text.len and isAlphaNum(text[i + 8]) and
            isAlphaNum(text[i + 9]) and isAlphaNum(text[i + 10]))
        {
            // Check word boundary after 11 chars
            if (i + 11 < text.len and isAlphaNum(text[i + 11])) continue;
            code_len = 11;
        } else {
            // Check word boundary after 8 chars
            if (i + 8 < text.len and isAlphaNum(text[i + 8])) continue;
        }

        // Validate country code against known ISO 3166-1 alpha-2
        // (simplified: just check it's two uppercase letters, already guaranteed above)
        if (result.account_count < MAX_ITEMS) {
            result.accounts[result.account_count] = makeSpan(text, i, code_len);
            result.account_count += 1;
        }
        i += code_len;
    }
}

/// Extract US routing numbers (9 digits) and account numbers near them.
fn extractUsRoutingNumbers(text: []const u8, result: *FinancialResult) void {
    var i: usize = 0;

    while (i + 9 <= text.len) : (i += 1) {
        // Must be at word boundary and exactly 9 consecutive digits
        if (i > 0 and (isDigit(text[i - 1]) or isAlpha(text[i - 1]))) continue;

        var all_digits = true;
        for (0..9) |d| {
            if (!isDigit(text[i + d])) {
                all_digits = false;
                break;
            }
        }
        if (!all_digits) continue;

        // Must end at word boundary
        if (i + 9 < text.len and isDigit(text[i + 9])) continue;

        // Validate ABA routing number checksum (weighted mod 10)
        // Weights: 3, 7, 1, 3, 7, 1, 3, 7, 1
        const weights = [9]u32{ 3, 7, 1, 3, 7, 1, 3, 7, 1 };
        var checksum: u32 = 0;
        for (0..9) |d| {
            checksum += @as(u32, text[i + d] - '0') * weights[d];
        }
        if (checksum % 10 != 0) continue;

        if (result.account_count < MAX_ITEMS) {
            result.accounts[result.account_count] = makeSpan(text, i, 9);
            result.account_count += 1;
        }

        // Look for associated account number nearby (within 30 chars)
        var j = i + 9;
        while (j < text.len and j < i + 40 and !isDigit(text[j])) : (j += 1) {}
        if (j < text.len and j < i + 40 and isDigit(text[j])) {
            const acct_start = j;
            while (j < text.len and isDigit(text[j])) : (j += 1) {}
            const acct_len = j - acct_start;
            if (acct_len >= 6 and acct_len <= 17 and result.account_count < MAX_ITEMS) {
                result.accounts[result.account_count] = makeSpan(text, acct_start, acct_len);
                result.account_count += 1;
            }
        }

        i += 9;
    }
}

/// Extract wire transfer references (common patterns).
fn extractWireTransferRefs(text: []const u8, result: *FinancialResult) void {
    const wire_keywords = [_][]const u8{
        "Wire Transfer",
        "wire transfer",
        "WIRE TRANSFER",
        "Wire Ref",
        "wire ref",
        "Reference No",
        "reference no",
        "Ref No",
        "Ref #",
        "REF:",
        "SWIFT",
        "FedWire",
        "FEDWIRE",
    };

    for (wire_keywords) |keyword| {
        var i: usize = 0;
        while (i + keyword.len <= text.len) : (i += 1) {
            if (!std.mem.eql(u8, text[i .. i + keyword.len], keyword)) continue;

            // Capture the keyword and following reference number/text
            const start = i;
            var end = i + keyword.len;
            // Skip separator characters
            while (end < text.len and (text[end] == ':' or text[end] == '#' or
                text[end] == ' ' or text[end] == '.'))
            {
                end += 1;
            }
            // Capture reference number (alphanumeric + hyphens)
            const ref_start = end;
            while (end < text.len and (isAlphaNum(text[end]) or text[end] == '-' or text[end] == '/') and
                end < start + 80)
            {
                end += 1;
            }

            if (end > ref_start and result.wire_ref_count < MAX_ITEMS) {
                result.wire_refs[result.wire_ref_count] = makeSpan(text, start, end - start);
                result.wire_ref_count += 1;
            }
            i = end;
        }
    }
}

/// Extract check numbers.
fn extractCheckNumbers(text: []const u8, result: *FinancialResult) void {
    const check_keywords = [_][]const u8{
        "Check No",
        "Check #",
        "CHECK NO",
        "CHECK #",
        "check no",
        "check #",
        "Cheque No",
        "CHEQUE NO",
        "Chk No",
        "Chk #",
    };

    for (check_keywords) |keyword| {
        var i: usize = 0;
        while (i + keyword.len <= text.len) : (i += 1) {
            if (!std.mem.eql(u8, text[i .. i + keyword.len], keyword)) continue;

            const start = i;
            var end = i + keyword.len;
            // Skip separators
            while (end < text.len and (text[end] == ':' or text[end] == '.' or
                text[end] == ' ' or text[end] == '#'))
            {
                end += 1;
            }
            // Capture check number (digits)
            const num_start = end;
            while (end < text.len and isDigit(text[end])) : (end += 1) {}

            if (end > num_start and result.check_count < MAX_ITEMS) {
                result.checks[result.check_count] = makeSpan(text, start, end - start);
                result.check_count += 1;
            }
            i = end;
        }
    }
}

/// Extract date-amount pairs: dates appearing near monetary amounts.
/// This captures contextual pairs like "03/15/2024 $5,000.00".
fn extractDateAmountPairs(text: []const u8, result: *FinancialResult) void {
    var i: usize = 0;

    while (i + 10 < text.len) : (i += 1) {
        // Look for date patterns: MM/DD/YYYY
        if (!isDigit(text[i])) continue;

        var j = i;
        // MM
        while (j < text.len and isDigit(text[j])) j += 1;
        if (j >= text.len or text[j] != '/') continue;
        const mm_len = j - i;
        if (mm_len < 1 or mm_len > 2) continue;
        j += 1;

        // DD
        const dd_start = j;
        while (j < text.len and isDigit(text[j])) j += 1;
        if (j >= text.len or text[j] != '/') continue;
        const dd_len = j - dd_start;
        if (dd_len < 1 or dd_len > 2) continue;
        j += 1;

        // YYYY
        const yy_start = j;
        while (j < text.len and isDigit(text[j])) j += 1;
        const yy_len = j - yy_start;
        if (yy_len != 4 and yy_len != 2) continue;

        const date_end = j;

        // Look for amount within 50 chars of the date
        var k = date_end;
        while (k < text.len and k < date_end + 50) : (k += 1) {
            if (text[k] == '$' or
                (text[k] == 0xC2 and k + 1 < text.len and text[k + 1] == 0xA3) or
                (text[k] == 0xE2 and k + 2 < text.len and text[k + 1] == 0x82 and text[k + 2] == 0xAC))
            {
                // Found a currency symbol near the date
                var amt_end = k + 1;
                if (text[k] == 0xC2) amt_end = k + 2;
                if (text[k] == 0xE2) amt_end = k + 3;
                while (amt_end < text.len and amt_end < k + 30 and
                    (isDigit(text[amt_end]) or text[amt_end] == ',' or
                    text[amt_end] == '.' or text[amt_end] == ' '))
                {
                    amt_end += 1;
                }

                if (amt_end > k + 1 and result.date_amount_count < MAX_ITEMS) {
                    result.date_amounts[result.date_amount_count] = makeSpan(text, i, amt_end - i);
                    result.date_amount_count += 1;
                }
                break;
            }
        }

        i = date_end;
    }
}

// ============================================================================
// Public API
// ============================================================================

/// Process text through financial data extraction.
pub fn financialExtractProcess(text: []const u8, result: *FinancialResult) FinancialStatus {
    @memset(std.mem.asBytes(result), 0);

    if (text.len == 0) {
        result.status = @intFromEnum(FinancialStatus.no_text);
        return .no_text;
    }

    if (text.len < 5) {
        result.status = @intFromEnum(FinancialStatus.text_too_short);
        return .text_too_short;
    }

    // Run all extractors
    extractCurrencyAmounts(text, result);
    extractIbans(text, result);
    extractSwiftCodes(text, result);
    extractUsRoutingNumbers(text, result);
    extractWireTransferRefs(text, result);
    extractCheckNumbers(text, result);
    extractDateAmountPairs(text, result);

    // Tally
    result.total_items = result.amount_count + result.account_count +
        result.wire_ref_count + result.check_count + result.date_amount_count;

    // Summary
    var summary_buf: [512]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "{d} items: {d} amounts, {d} accounts, {d} wire refs, {d} checks, {d} date-amount pairs", .{
        result.total_items,
        result.amount_count,
        result.account_count,
        result.wire_ref_count,
        result.check_count,
        result.date_amount_count,
    }) catch "Financial extraction complete";
    @memcpy(result.summary[0..summary.len], summary);
    result.summary[summary.len] = 0;

    result.status = @intFromEnum(FinancialStatus.ok);
    return .ok;
}

// ============================================================================
// C-ABI Exports
// ============================================================================

/// C-ABI entry point for financial data extraction.
export fn ddac_financial_extract_process(
    text_ptr: ?[*]const u8,
    text_len: usize,
    result: ?*FinancialResult,
) c_int {
    const text = if (text_ptr) |p| p[0..text_len] else return 1;
    const res = result orelse return 1;
    const status = financialExtractProcess(text, res);
    return @intFromEnum(status);
}

// ============================================================================
// Tests
// ============================================================================

test "extract USD amounts" {
    var result: FinancialResult = undefined;
    const text = "The payment was $1,234.56 and another $500.";
    _ = financialExtractProcess(text, &result);
    try std.testing.expect(result.amount_count == 2);
    try std.testing.expect(result.amounts[0].value > 1234.0 and result.amounts[0].value < 1235.0);
    try std.testing.expectEqualStrings("USD", result.amounts[0].currency[0..3]);
}

test "extract currency code amounts" {
    var result: FinancialResult = undefined;
    const text = "Transfer of EUR 5000 and CHF 10000.50 completed.";
    _ = financialExtractProcess(text, &result);
    try std.testing.expect(result.amount_count == 2);
}

test "validate IBAN checksum" {
    // GB82 WEST 1234 5698 7654 32 (valid test IBAN)
    try std.testing.expect(validateIbanChecksum("GB82WEST12345698765432"));
    // Invalid checksum
    try std.testing.expect(!validateIbanChecksum("GB00WEST12345698765432"));
}

test "extract wire transfer references" {
    var result: FinancialResult = undefined;
    const text = "Wire Transfer REF: WT2024-03-15-001 was processed.";
    _ = financialExtractProcess(text, &result);
    try std.testing.expect(result.wire_ref_count >= 1);
}

test "extract check numbers" {
    var result: FinancialResult = undefined;
    const text = "Check No. 12345 and Check # 67890 were deposited.";
    _ = financialExtractProcess(text, &result);
    try std.testing.expect(result.check_count == 2);
}

test "empty text returns no_text" {
    var result: FinancialResult = undefined;
    const status = financialExtractProcess("", &result);
    try std.testing.expect(status == .no_text);
}

test "parseDecimal handles commas and decimals" {
    const r1 = parseDecimal("1,234,567.89", 0);
    try std.testing.expect(r1.value > 1234567.88 and r1.value < 1234567.90);
    try std.testing.expect(r1.end == 12);
}

test "ABA routing number checksum" {
    // 021000021 (Chase NY) — weights: 3*0 + 7*2 + 1*1 + 3*0 + 7*0 + 1*0 + 3*0 + 7*2 + 1*1 = 30
    // 30 % 10 == 0 → valid
    var result: FinancialResult = undefined;
    const text = "Routing: 021000021 Account: 123456789";
    _ = financialExtractProcess(text, &result);
    // The routing number should be detected
    try std.testing.expect(result.account_count >= 1);
}
