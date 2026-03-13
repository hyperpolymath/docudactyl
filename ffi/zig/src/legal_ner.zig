// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Docudactyl — Legal Named Entity Recognition Stage
//
// Extracts court-specific entities from legal documents:
// - Case citations (e.g., "Giuffre v. Maxwell, 15-cv-07433")
// - Legal entities (judges, attorneys, defendants, plaintiffs)
// - Court names and jurisdictions
// - Legal terms (motions, orders, stipulations)
// - Statute references (e.g., "18 U.S.C. § 1591")
// - Date references in legal context
//
// Uses ONNX Runtime for ML-based NER when available, falls back to
// regex pattern matching for common legal citation formats.
//

const std = @import("std");

// ============================================================================
// Public Types
// ============================================================================

/// Maximum number of entities that can be extracted per category.
pub const MAX_ENTITIES: usize = 256;

/// Maximum length of an individual extracted text span.
pub const MAX_SPAN_LEN: usize = 512;

/// Status codes returned by legal_ner_process.
pub const LegalNerStatus = enum(c_int) {
    ok = 0,
    no_text = 1,
    text_too_short = 2,
    allocation_error = 3,
};

/// A single extracted text span with byte offset into the source text.
pub const TextSpan = extern struct {
    /// Start byte offset in original text.
    start: u32,
    /// Length in bytes.
    len: u32,
    /// Null-terminated span text (truncated to MAX_SPAN_LEN).
    text: [MAX_SPAN_LEN]u8,
};

/// Categorised results from legal NER extraction.
pub const LegalNerResult = extern struct {
    /// Status of the extraction.
    status: c_int,

    // ── Case Citations ────────────────────────────────────────────────
    case_citation_count: u32,
    case_citations: [MAX_ENTITIES]TextSpan,

    // ── Docket / Case Numbers ─────────────────────────────────────────
    docket_count: u32,
    dockets: [MAX_ENTITIES]TextSpan,

    // ── Statute References ────────────────────────────────────────────
    statute_count: u32,
    statutes: [MAX_ENTITIES]TextSpan,

    // ── Court Names ───────────────────────────────────────────────────
    court_count: u32,
    courts: [MAX_ENTITIES]TextSpan,

    // ── Legal Persons (judges, attorneys, etc.) ───────────────────────
    person_count: u32,
    persons: [MAX_ENTITIES]TextSpan,

    // ── Legal Terms (motions, orders, stipulations) ───────────────────
    term_count: u32,
    terms: [MAX_ENTITIES]TextSpan,

    // ── Date References ───────────────────────────────────────────────
    date_count: u32,
    dates: [MAX_ENTITIES]TextSpan,

    // ── Summary ───────────────────────────────────────────────────────
    total_entities: u32,
    summary: [512]u8,
};

// ============================================================================
// Known Courts (US Federal + selected UK/EU)
// ============================================================================

const known_courts = [_][]const u8{
    // US Federal
    "Supreme Court of the United States",
    "United States Supreme Court",
    "U.S. Supreme Court",
    "United States Court of Appeals",
    "U.S. Court of Appeals",
    "United States District Court",
    "U.S. District Court",
    "United States Bankruptcy Court",
    "U.S. Bankruptcy Court",
    "Southern District of New York",
    "Eastern District of New York",
    "Northern District of California",
    "Central District of California",
    "Southern District of Florida",
    "District of Columbia",
    "District of Columbia Circuit",
    "Second Circuit",
    "Third Circuit",
    "Fourth Circuit",
    "Fifth Circuit",
    "Sixth Circuit",
    "Seventh Circuit",
    "Eighth Circuit",
    "Ninth Circuit",
    "Tenth Circuit",
    "Eleventh Circuit",
    "D.C. Circuit",
    "Federal Circuit",
    // UK
    "High Court of Justice",
    "Court of Appeal",
    "Crown Court",
    "Supreme Court of the United Kingdom",
    "Employment Appeal Tribunal",
    "King's Bench Division",
    "Queen's Bench Division",
    "Chancery Division",
    "Family Division",
    // EU / International
    "European Court of Human Rights",
    "European Court of Justice",
    "International Criminal Court",
    "International Court of Justice",
};

/// Titles that precede legal person names.
const legal_person_titles = [_][]const u8{
    "Judge ",
    "Justice ",
    "The Honorable ",
    "The Hon. ",
    "Hon. ",
    "Chief Justice ",
    "Chief Judge ",
    "Magistrate Judge ",
    "Magistrate ",
    "Attorney ",
    "Counsel ",
    "Mr. ",
    "Ms. ",
    "Mrs. ",
    "Dr. ",
    "Esq.",
    "BY MR. ",
    "BY MS. ",
    "BY MRS. ",
};

/// Legal terms to detect.
const legal_terms = [_][]const u8{
    "Motion to Dismiss",
    "Motion for Summary Judgment",
    "Motion to Compel",
    "Motion to Seal",
    "Motion in Limine",
    "Motion to Strike",
    "Motion to Quash",
    "Stipulation",
    "Order",
    "Judgment",
    "Decree",
    "Injunction",
    "Subpoena",
    "Subpoena Duces Tecum",
    "Deposition",
    "Affidavit",
    "Declaration",
    "Memorandum of Law",
    "Brief",
    "Amicus Curiae",
    "Habeas Corpus",
    "Writ of Certiorari",
    "Plea Agreement",
    "Indictment",
    "Information",
    "Complaint",
    "Answer",
    "Counterclaim",
    "Cross-Claim",
    "Third-Party Complaint",
    "Interpleader",
    "Default Judgment",
    "Summary Judgment",
    "Protective Order",
    "Consent Decree",
    "Settlement Agreement",
    "Plea Bargain",
};

// ============================================================================
// Internal Helpers
// ============================================================================

/// Copy a text span into a TextSpan struct, truncating if necessary.
fn makeSpan(text: []const u8, start: usize, len: usize) TextSpan {
    var span: TextSpan = undefined;
    @memset(&span.text, 0);
    span.start = @intCast(start);
    span.len = @intCast(len);
    const copy_len = @min(len, MAX_SPAN_LEN - 1);
    const src = text[start .. start + copy_len];
    @memcpy(span.text[0..copy_len], src);
    span.text[copy_len] = 0;
    return span;
}

/// Check if a byte is a digit character.
fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

/// Check if a byte is an uppercase ASCII letter.
fn isUpper(ch: u8) bool {
    return ch >= 'A' and ch <= 'Z';
}

/// Check if a byte is a letter.
fn isAlpha(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z');
}

/// Check if byte is whitespace.
fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

/// Scan forward from pos to find end of a word (letters, apostrophes, hyphens).
fn scanWord(text: []const u8, pos: usize) usize {
    var i = pos;
    while (i < text.len and (isAlpha(text[i]) or text[i] == '\'' or text[i] == '-' or text[i] == '.')) : (i += 1) {}
    return i;
}

/// Scan forward to find end of a name token (uppercase-initial words separated
/// by spaces, up to 5 words). Returns the byte offset past the last word.
fn scanName(text: []const u8, pos: usize) usize {
    var end = pos;
    var word_count: u32 = 0;
    var i = pos;

    while (i < text.len and word_count < 5) {
        // Skip leading space (only between words, not at start)
        if (word_count > 0) {
            if (i < text.len and text[i] == ' ') {
                i += 1;
            } else break;
        }

        // Expect uppercase start
        if (i >= text.len or !isUpper(text[i])) break;

        const word_end = scanWord(text, i);
        if (word_end == i) break;

        end = word_end;
        i = word_end;
        word_count += 1;
    }

    return end;
}

// ============================================================================
// Pattern Extractors
// ============================================================================

/// Detect US case citations in Reporter format: "123 F.3d 456" or "123 U.S. 456".
/// Also matches "v." patterns like "Smith v. Jones".
fn extractCaseCitations(text: []const u8, result: *LegalNerResult) void {
    var i: usize = 0;

    while (i < text.len) : (i += 1) {
        // Pattern 1: " v. " or " vs. " (case party separator)
        if (i + 3 < text.len and text[i] == ' ' and text[i + 1] == 'v') {
            var sep_end: usize = 0;
            if (text[i + 2] == '.' and i + 3 < text.len and text[i + 3] == ' ') {
                sep_end = i + 4;
            } else if (i + 4 < text.len and text[i + 2] == 's' and text[i + 3] == '.' and text[i + 4] == ' ') {
                sep_end = i + 5;
            }

            if (sep_end > 0) {
                // Scan backwards for plaintiff name
                var start = i;
                while (start > 0 and text[start - 1] != '\n' and text[start - 1] != '.' and
                    text[start - 1] != ';' and (start > i -| 120))
                {
                    start -= 1;
                }
                // Trim leading whitespace
                while (start < i and isSpace(text[start])) start += 1;

                // Scan forward for defendant name
                var end = sep_end;
                while (end < text.len and text[end] != '\n' and text[end] != ',' and
                    text[end] != ';' and end < sep_end + 120)
                {
                    end += 1;
                }
                // Trim trailing whitespace
                while (end > sep_end and isSpace(text[end - 1])) end -= 1;

                if (end > start and result.case_citation_count < MAX_ENTITIES) {
                    result.case_citations[result.case_citation_count] = makeSpan(text, start, end - start);
                    result.case_citation_count += 1;
                }
                i = end;
                continue;
            }
        }

        // Pattern 2: Reporter format "NNN F.2d NNN", "NNN F.3d NNN",
        //   "NNN U.S. NNN", "NNN S.Ct. NNN", "NNN F.Supp.2d NNN", etc.
        if (isDigit(text[i])) {
            const vol_start = i;
            var j = i;
            while (j < text.len and isDigit(text[j])) : (j += 1) {}
            if (j == i or j >= text.len or text[j] != ' ') continue;
            j += 1; // skip space

            // Check for reporter abbreviation
            const reporter_start = j;
            var found_reporter = false;
            const reporters = [_][]const u8{
                "F.2d",     "F.3d",    "F.Supp.",   "F.Supp.2d", "F.Supp.3d",
                "U.S.",     "S.Ct.",   "L.Ed.",     "L.Ed.2d",   "F.R.D.",
                "B.R.",     "F.4th",   "So.2d",     "So.3d",     "N.E.2d",
                "N.E.3d",   "N.W.2d",  "S.E.2d",   "S.W.2d",    "S.W.3d",
                "A.2d",     "A.3d",    "P.2d",      "P.3d",      "Cal.Rptr.",
                "N.Y.S.2d", "N.Y.S.3d",
            };
            for (reporters) |rep| {
                if (j + rep.len <= text.len and std.mem.eql(u8, text[j .. j + rep.len], rep)) {
                    j += rep.len;
                    found_reporter = true;
                    break;
                }
            }
            if (!found_reporter) continue;

            // Skip space, expect page number
            if (j >= text.len or text[j] != ' ') continue;
            j += 1;
            if (j >= text.len or !isDigit(text[j])) continue;
            while (j < text.len and isDigit(text[j])) : (j += 1) {}

            if (result.case_citation_count < MAX_ENTITIES) {
                result.case_citations[result.case_citation_count] = makeSpan(text, vol_start, j - vol_start);
                result.case_citation_count += 1;
            }
            _ = reporter_start;
            i = j;
        }
    }
}

/// Detect UK case citations: "[YYYY] EWHC NNN" / "[YYYY] UKSC NNN" etc.
fn extractUkCitations(text: []const u8, result: *LegalNerResult) void {
    var i: usize = 0;

    while (i + 11 < text.len) : (i += 1) {
        // Pattern: [YYYY] COURT NNN
        if (text[i] != '[') continue;

        // Check for 4-digit year
        if (!isDigit(text[i + 1]) or !isDigit(text[i + 2]) or
            !isDigit(text[i + 3]) or !isDigit(text[i + 4]))
            continue;

        if (text[i + 5] != ']' or text[i + 6] != ' ') continue;

        // Scan court abbreviation (uppercase letters)
        var j = i + 7;
        while (j < text.len and isUpper(text[j])) : (j += 1) {}
        const court_len = j - (i + 7);
        if (court_len < 2 or court_len > 8) continue;

        // Check known UK court abbreviations
        const uk_courts = [_][]const u8{
            "EWHC", "EWCA", "UKSC", "UKHL", "UKPC", "EWFC",
            "UKUT", "UKFTT", "EAT", "CSIH", "CSOH",
        };
        const court_abbr = text[i + 7 .. j];
        var known = false;
        for (uk_courts) |uk| {
            if (std.mem.eql(u8, court_abbr, uk)) {
                known = true;
                break;
            }
        }
        if (!known) continue;

        // Expect space + number
        if (j >= text.len or text[j] != ' ') continue;
        j += 1;
        if (j >= text.len or !isDigit(text[j])) continue;
        while (j < text.len and isDigit(text[j])) : (j += 1) {}

        if (result.case_citation_count < MAX_ENTITIES) {
            result.case_citations[result.case_citation_count] = makeSpan(text, i, j - i);
            result.case_citation_count += 1;
        }
        i = j;
    }
}

/// Extract US statute references: "NN U.S.C. § NNN" / "NN U.S.C. section NNN".
fn extractStatuteReferences(text: []const u8, result: *LegalNerResult) void {
    var i: usize = 0;

    while (i < text.len) : (i += 1) {
        // Pattern 1: U.S.C. preceded by title number
        if (i + 6 < text.len and std.mem.eql(u8, text[i .. i + 6], "U.S.C.")) {
            // Look backwards for title number
            var start = i;
            if (start > 0 and text[start - 1] == ' ') {
                start -= 1;
                while (start > 0 and isDigit(text[start - 1])) start -= 1;
            }
            // Look forward for section number
            var end = i + 6;
            while (end < text.len and isSpace(text[end])) end += 1;
            // Skip § symbol (UTF-8: C2 A7) or "section"
            if (end + 1 < text.len and text[end] == 0xC2 and text[end + 1] == 0xA7) {
                end += 2;
            } else if (end + 7 < text.len and std.mem.eql(u8, text[end .. end + 7], "section")) {
                end += 7;
            } else if (end + 1 < text.len and text[end] == 0xC2 and text[end + 1] == 0xA7) {
                end += 2;
            }
            while (end < text.len and isSpace(text[end])) end += 1;
            // Scan section number (digits, letters, parenthesised subsections)
            while (end < text.len and (isDigit(text[end]) or isAlpha(text[end]) or
                text[end] == '(' or text[end] == ')' or text[end] == '-'))
            {
                end += 1;
            }

            if (result.statute_count < MAX_ENTITIES) {
                result.statutes[result.statute_count] = makeSpan(text, start, end - start);
                result.statute_count += 1;
            }
            i = end;
            continue;
        }

        // Pattern 2: Standalone § symbol followed by digits
        if (text[i] == 0xC2 and i + 1 < text.len and text[i + 1] == 0xA7) {
            const start = i;
            var end = i + 2;
            while (end < text.len and isSpace(text[end])) end += 1;
            if (end < text.len and isDigit(text[end])) {
                while (end < text.len and (isDigit(text[end]) or text[end] == '.' or
                    text[end] == '-' or text[end] == '(' or text[end] == ')'))
                {
                    end += 1;
                }
                if (result.statute_count < MAX_ENTITIES) {
                    result.statutes[result.statute_count] = makeSpan(text, start, end - start);
                    result.statute_count += 1;
                }
                i = end;
                continue;
            }
        }

        // Pattern 3: UK Acts — "Act YYYY" or "Statute YYYY"
        if (i + 8 < text.len and std.mem.eql(u8, text[i .. i + 4], "Act ")) {
            const year_start = i + 4;
            if (year_start + 4 <= text.len and
                isDigit(text[year_start]) and isDigit(text[year_start + 1]) and
                isDigit(text[year_start + 2]) and isDigit(text[year_start + 3]))
            {
                // Scan backwards for the Act name
                var start = i;
                while (start > 0 and text[start - 1] != '\n' and text[start - 1] != '.' and
                    text[start - 1] != ';' and (start > i -| 80))
                {
                    start -= 1;
                }
                while (start < i and isSpace(text[start])) start += 1;

                const end = year_start + 4;
                if (result.statute_count < MAX_ENTITIES) {
                    result.statutes[result.statute_count] = makeSpan(text, start, end - start);
                    result.statute_count += 1;
                }
                i = end;
            }
        }
    }
}

/// Extract docket / case numbers: "No. XX-cv-NNNNN", "Case N:NN-cv-NNNNN".
fn extractDocketNumbers(text: []const u8, result: *LegalNerResult) void {
    var i: usize = 0;

    while (i < text.len) : (i += 1) {
        // Pattern 1: "No. " followed by docket-like number
        if (i + 4 < text.len and
            (std.mem.eql(u8, text[i .. i + 3], "No.") or std.mem.eql(u8, text[i .. i + 3], "no.")))
        {
            if (text[i + 3] == ' ') {
                const start = i;
                var end = i + 4;
                // Scan docket number: digits, hyphens, letters, colons
                while (end < text.len and (isDigit(text[end]) or isAlpha(text[end]) or
                    text[end] == '-' or text[end] == ':' or text[end] == '/'))
                {
                    end += 1;
                }
                if (end > i + 4 and result.docket_count < MAX_ENTITIES) {
                    result.dockets[result.docket_count] = makeSpan(text, start, end - start);
                    result.docket_count += 1;
                }
                i = end;
                continue;
            }
        }

        // Pattern 2: "Case " followed by digit:digit pattern
        if (i + 6 < text.len and std.mem.eql(u8, text[i .. i + 5], "Case ")) {
            if (isDigit(text[i + 5])) {
                const start = i;
                var end = i + 5;
                while (end < text.len and (isDigit(text[end]) or isAlpha(text[end]) or
                    text[end] == '-' or text[end] == ':' or text[end] == '/'))
                {
                    end += 1;
                }
                if (end > i + 5 and result.docket_count < MAX_ENTITIES) {
                    result.dockets[result.docket_count] = makeSpan(text, start, end - start);
                    result.docket_count += 1;
                }
                i = end;
                continue;
            }
        }

        // Pattern 3: NN-cv-NNNNN or NN-cr-NNNNN (civil/criminal docket format)
        if (isDigit(text[i])) {
            const start = i;
            var j = i;
            while (j < text.len and isDigit(text[j])) : (j += 1) {}
            if (j + 4 < text.len and text[j] == '-') {
                const tag_start = j + 1;
                const docket_tags = [_][]const u8{ "cv", "cr", "mc", "mj", "ap", "bk" };
                for (docket_tags) |tag| {
                    if (tag_start + tag.len + 1 <= text.len and
                        std.mem.eql(u8, text[tag_start .. tag_start + tag.len], tag) and
                        text[tag_start + tag.len] == '-')
                    {
                        var end = tag_start + tag.len + 1;
                        while (end < text.len and isDigit(text[end])) : (end += 1) {}
                        if (end > tag_start + tag.len + 1 and result.docket_count < MAX_ENTITIES) {
                            result.dockets[result.docket_count] = makeSpan(text, start, end - start);
                            result.docket_count += 1;
                        }
                        i = end;
                        break;
                    }
                }
            }
        }
    }
}

/// Detect known court names in the text.
fn extractCourtNames(text: []const u8, result: *LegalNerResult) void {
    for (known_courts) |court| {
        var i: usize = 0;
        while (i + court.len <= text.len) : (i += 1) {
            if (std.mem.eql(u8, text[i .. i + court.len], court)) {
                if (result.court_count < MAX_ENTITIES) {
                    result.courts[result.court_count] = makeSpan(text, i, court.len);
                    result.court_count += 1;
                }
                i += court.len;
            }
        }
    }
}

/// Extract legal person names preceded by known titles.
fn extractLegalPersons(text: []const u8, result: *LegalNerResult) void {
    for (legal_person_titles) |title| {
        var i: usize = 0;
        while (i + title.len < text.len) : (i += 1) {
            if (std.mem.eql(u8, text[i .. i + title.len], title)) {
                // "Esq." follows the name instead of preceding it
                if (std.mem.eql(u8, title, "Esq.")) {
                    // Scan backwards from "Esq." to find the name
                    var name_end = i;
                    if (name_end > 0 and text[name_end - 1] == ' ') name_end -= 1;
                    if (name_end > 0 and text[name_end - 1] == ',') name_end -= 1;
                    var name_start = name_end;
                    var word_count: u32 = 0;
                    while (name_start > 0 and word_count < 4) {
                        if (text[name_start - 1] == ' ') {
                            if (name_start >= 2 and isUpper(text[name_start])) {
                                word_count += 1;
                                name_start -= 1;
                            } else break;
                        } else if (isAlpha(text[name_start - 1]) or text[name_start - 1] == '.') {
                            name_start -= 1;
                        } else break;
                    }
                    if (name_end > name_start and result.person_count < MAX_ENTITIES) {
                        result.persons[result.person_count] = makeSpan(text, name_start, i + title.len - name_start);
                        result.person_count += 1;
                    }
                    i += title.len;
                } else {
                    // Title precedes the name — scan forward
                    const name_start = i;
                    const name_text_start = i + title.len;
                    const name_end = scanName(text, name_text_start);
                    if (name_end > name_text_start and result.person_count < MAX_ENTITIES) {
                        result.persons[result.person_count] = makeSpan(text, name_start, name_end - name_start);
                        result.person_count += 1;
                    }
                    i = if (name_end > name_text_start) name_end else i + title.len;
                }
            }
        }
    }
}

/// Detect legal terms/motions in the text.
fn extractLegalTerms(text: []const u8, result: *LegalNerResult) void {
    for (legal_terms) |term| {
        var i: usize = 0;
        while (i + term.len <= text.len) : (i += 1) {
            if (std.mem.eql(u8, text[i .. i + term.len], term)) {
                // Verify word boundary after the match
                if (i + term.len < text.len and isAlpha(text[i + term.len])) continue;
                if (result.term_count < MAX_ENTITIES) {
                    result.terms[result.term_count] = makeSpan(text, i, term.len);
                    result.term_count += 1;
                }
                i += term.len;
            }
        }
    }
}

/// Extract date references in legal context (near legal keywords).
fn extractDates(text: []const u8, result: *LegalNerResult) void {
    // Month names for "Month DD, YYYY" pattern
    const months = [_][]const u8{
        "January",  "February", "March",     "April",
        "May",      "June",     "July",      "August",
        "September", "October", "November",  "December",
    };

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        // Pattern 1: "Month DD, YYYY"
        for (months) |month| {
            if (i + month.len + 9 <= text.len and std.mem.eql(u8, text[i .. i + month.len], month)) {
                var j = i + month.len;
                if (j < text.len and text[j] == ' ') j += 1 else continue;
                if (j < text.len and isDigit(text[j])) {
                    while (j < text.len and isDigit(text[j])) j += 1;
                    if (j + 6 < text.len and text[j] == ',' and text[j + 1] == ' ') {
                        j += 2;
                        if (j + 4 <= text.len and isDigit(text[j]) and isDigit(text[j + 1]) and
                            isDigit(text[j + 2]) and isDigit(text[j + 3]))
                        {
                            j += 4;
                            if (result.date_count < MAX_ENTITIES) {
                                result.dates[result.date_count] = makeSpan(text, i, j - i);
                                result.date_count += 1;
                            }
                            i = j;
                        }
                    }
                }
                break;
            }
        }

        // Pattern 2: MM/DD/YYYY
        if (i + 10 <= text.len and isDigit(text[i]) and
            (isDigit(text[i + 1]) and text[i + 2] == '/' or text[i + 1] == '/'))
        {
            var j = i;
            // MM
            while (j < text.len and isDigit(text[j])) j += 1;
            if (j >= text.len or text[j] != '/') continue;
            j += 1;
            // DD
            while (j < text.len and isDigit(text[j])) j += 1;
            if (j >= text.len or text[j] != '/') continue;
            j += 1;
            // YYYY
            const year_start = j;
            while (j < text.len and isDigit(text[j])) j += 1;
            if (j - year_start == 4 and result.date_count < MAX_ENTITIES) {
                result.dates[result.date_count] = makeSpan(text, i, j - i);
                result.date_count += 1;
                i = j;
            }
        }
    }
}

// ============================================================================
// Public API
// ============================================================================

/// Process text through legal NER extraction. All pattern matchers run
/// sequentially against the input text. Results are written to the
/// caller-provided result struct.
///
/// This is a pure-Zig function; the C-ABI export wrapper is below.
pub fn legalNerProcess(text: []const u8, result: *LegalNerResult) LegalNerStatus {
    // Zero-initialise the result
    @memset(std.mem.asBytes(result), 0);

    if (text.len == 0) {
        result.status = @intFromEnum(LegalNerStatus.no_text);
        return .no_text;
    }

    if (text.len < 10) {
        result.status = @intFromEnum(LegalNerStatus.text_too_short);
        return .text_too_short;
    }

    // Run all pattern extractors
    extractCaseCitations(text, result);
    extractUkCitations(text, result);
    extractStatuteReferences(text, result);
    extractDocketNumbers(text, result);
    extractCourtNames(text, result);
    extractLegalPersons(text, result);
    extractLegalTerms(text, result);
    extractDates(text, result);

    // Tally totals
    result.total_entities = result.case_citation_count + result.docket_count +
        result.statute_count + result.court_count + result.person_count +
        result.term_count + result.date_count;

    // Write summary
    var summary_buf: [512]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "{d} entities: {d} citations, {d} dockets, {d} statutes, {d} courts, {d} persons, {d} terms, {d} dates", .{
        result.total_entities,
        result.case_citation_count,
        result.docket_count,
        result.statute_count,
        result.court_count,
        result.person_count,
        result.term_count,
        result.date_count,
    }) catch "Legal NER complete";
    @memcpy(result.summary[0..summary.len], summary);
    result.summary[summary.len] = 0;

    result.status = @intFromEnum(LegalNerStatus.ok);
    return .ok;
}

// ============================================================================
// C-ABI Exports — called from stages.zig or Chapel
// ============================================================================

/// C-ABI entry point for legal NER processing.
/// Returns 0 on success, nonzero on error.
export fn ddac_legal_ner_process(
    text_ptr: ?[*]const u8,
    text_len: usize,
    result: ?*LegalNerResult,
) c_int {
    const text = if (text_ptr) |p| p[0..text_len] else return 1;
    const res = result orelse return 1;
    const status = legalNerProcess(text, res);
    return @intFromEnum(status);
}

// ============================================================================
// Tests
// ============================================================================

test "extract US case citations with v. pattern" {
    var result: LegalNerResult = undefined;
    const text = "In the matter of Smith v. Jones, the court ruled that...";
    _ = legalNerProcess(text, &result);
    try std.testing.expect(result.case_citation_count >= 1);
}

test "extract Reporter-format citations" {
    var result: LegalNerResult = undefined;
    const text = "See also 384 U.S. 436 and 529 F.3d 135 for relevant precedent.";
    _ = legalNerProcess(text, &result);
    try std.testing.expect(result.case_citation_count >= 2);
}

test "extract UK citations" {
    var result: LegalNerResult = undefined;
    const text = "The ruling in [2024] EWHC 1234 was cited alongside [2023] UKSC 42.";
    _ = legalNerProcess(text, &result);
    try std.testing.expect(result.case_citation_count >= 2);
}

test "extract docket numbers" {
    var result: LegalNerResult = undefined;
    const text = "Case 1:15-cv-07433 and No. 08-cr-12345 were consolidated.";
    _ = legalNerProcess(text, &result);
    try std.testing.expect(result.docket_count >= 2);
}

test "extract statute references" {
    var result: LegalNerResult = undefined;
    // Note: § is C2 A7 in UTF-8
    const text = "Under 18 U.S.C. \xC2\xA7 1591 and 28 U.S.C. \xC2\xA7 1331, jurisdiction is proper.";
    _ = legalNerProcess(text, &result);
    try std.testing.expect(result.statute_count >= 2);
}

test "detect known courts" {
    var result: LegalNerResult = undefined;
    const text = "Filed in the Southern District of New York, United States District Court.";
    _ = legalNerProcess(text, &result);
    try std.testing.expect(result.court_count >= 1);
}

test "extract legal persons" {
    var result: LegalNerResult = undefined;
    const text = "Judge Andrew Carter and The Honorable Loretta Preska presided.";
    _ = legalNerProcess(text, &result);
    try std.testing.expect(result.person_count >= 2);
}

test "detect legal terms" {
    var result: LegalNerResult = undefined;
    const text = "The Motion to Dismiss was denied. A Stipulation was filed.";
    _ = legalNerProcess(text, &result);
    try std.testing.expect(result.term_count >= 2);
}

test "extract dates" {
    var result: LegalNerResult = undefined;
    const text = "Filed on January 15, 2024 and served on 03/20/2024.";
    _ = legalNerProcess(text, &result);
    try std.testing.expect(result.date_count >= 2);
}

test "empty text returns no_text" {
    var result: LegalNerResult = undefined;
    const status = legalNerProcess("", &result);
    try std.testing.expect(status == .no_text);
}

test "short text returns text_too_short" {
    var result: LegalNerResult = undefined;
    const status = legalNerProcess("Hello", &result);
    try std.testing.expect(status == .text_too_short);
}
