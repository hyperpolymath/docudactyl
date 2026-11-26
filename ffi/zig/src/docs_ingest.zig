// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Docs ingest: parse AsciiDoc and Markdown prose into docmodel/v0 records,
// and bundle them as reconcile-input/v0 for the docs PR pipeline.
//
// This module is standalone: it needs no native libraries and no libc.
// It is a line-oriented reader, not a full renderer. It records headings,
// anchors, links, includes and inline path or command mentions with 1-based
// line and byte-column spans (end exclusive). It never writes files.
//
// Known limits (v0):
// - Heading ids follow Asciidoctor and GitHub slug rules closely, not exactly.
//   Inline markup inside a heading is stripped before the id is made.
// - Attribute references in link targets are expanded from attributes the
//   same file defines. A target that still holds `{...}` is skipped.
// - Conditional preprocessor directives (ifdef, ifeval) are not evaluated.

const std = @import("std");

pub const Format = enum { asciidoc, markdown };

pub const Pos = struct { line: u32, col: u32 };
pub const Span = struct { start: Pos, end: Pos };

pub const Heading = struct {
    level: u8,
    text: []const u8,
    id: ?[]const u8,
    span: Span,
};

pub const Anchor = struct { id: []const u8, span: Span };

pub const LinkKind = enum {
    internal_file,
    internal_anchor,
    external_url,
    include,

    pub fn name(k: LinkKind) []const u8 {
        return switch (k) {
            .internal_file => "internal-file",
            .internal_anchor => "internal-anchor",
            .external_url => "external-url",
            .include => "include",
        };
    }
};

pub const Link = struct {
    kind: LinkKind,
    target: []const u8,
    fragment: ?[]const u8,
    text: ?[]const u8,
    span: Span,
};

pub const RefKind = enum { path, command };

pub const Reference = struct { kind: RefKind, value: []const u8, span: Span };

pub const Doc = struct {
    path: []const u8,
    format: Format,
    sha256: [64]u8,
    spdx: ?[]const u8,
    title: ?[]const u8,
    headings: []const Heading,
    anchors: []const Anchor,
    links: []const Link,
    references: []const Reference,
};

pub const Error = error{ OutOfMemory, InvalidInput };

/// Prose format from a file extension, or null for files that are not prose.
pub fn formatOf(path: []const u8) ?Format {
    const exts_adoc = [_][]const u8{ ".adoc", ".asciidoc", ".asc" };
    const exts_md = [_][]const u8{ ".md", ".markdown" };
    for (exts_adoc) |e| if (std.ascii.endsWithIgnoreCase(path, e)) return .asciidoc;
    for (exts_md) |e| if (std.ascii.endsWithIgnoreCase(path, e)) return .markdown;
    return null;
}

// ── Shared helpers ──────────────────────────────────────────────────────

const Builder = struct {
    a: std.mem.Allocator,
    headings: std.ArrayList(Heading) = .empty,
    anchors: std.ArrayList(Anchor) = .empty,
    links: std.ArrayList(Link) = .empty,
    refs: std.ArrayList(Reference) = .empty,
    ids: std.StringHashMapUnmanaged(u32) = .empty,

    fn span(line: u32, s: usize, e: usize) Span {
        return .{
            .start = .{ .line = line, .col = @intCast(s + 1) },
            .end = .{ .line = line, .col = @intCast(e + 1) },
        };
    }

    /// Make an auto id unique the way each renderer does: Asciidoctor adds
    /// `_2`, `_3`; GitHub adds `-1`, `-2`.
    fn unique(b: *Builder, base: []const u8, fmt: Format, sep: []const u8) ![]const u8 {
        const gop = try b.ids.getOrPut(b.a, base);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
            return base;
        }
        gop.value_ptr.* += 1;
        const n = gop.value_ptr.*;
        const id = switch (fmt) {
            .asciidoc => try std.fmt.allocPrint(b.a, "{s}{s}{d}", .{ base, sep, n + 1 }),
            .markdown => try std.fmt.allocPrint(b.a, "{s}-{d}", .{ base, n }),
        };
        try b.ids.put(b.a, id, 0);
        return id;
    }

    fn claim(b: *Builder, id: []const u8) !void {
        try b.ids.put(b.a, id, 0);
    }
};

fn isSchemeStart(s: []const u8) ?usize {
    // RFC 3986 scheme followed by ':'. Returns the index of ':'.
    if (s.len < 2 or !std.ascii.isAlphabetic(s[0])) return null;
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == ':') return if (i >= 2) i else null; // single letter is a drive, not a scheme
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return null;
    }
    return null;
}

fn isExternal(t: []const u8) bool {
    if (std.mem.startsWith(u8, t, "//")) return true;
    return isSchemeStart(t) != null;
}

/// Classify a raw link target into kind, target and fragment.
fn classify(a: std.mem.Allocator, raw: []const u8) !?struct { kind: LinkKind, target: []const u8, fragment: ?[]const u8 } {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len == 0) return null;
    if (isExternal(t)) return .{ .kind = .external_url, .target = t, .fragment = null };
    if (t[0] == '#') return .{ .kind = .internal_anchor, .target = t, .fragment = null };
    var file = t;
    var frag: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, t, '#')) |k| {
        file = t[0..k];
        frag = t[k + 1 ..];
    }
    if (std.mem.indexOfScalar(u8, file, '?')) |k| file = file[0..k];
    if (file.len == 0) return .{ .kind = .internal_anchor, .target = try std.fmt.allocPrint(a, "#{s}", .{frag orelse ""}), .fragment = null };
    return .{ .kind = .internal_file, .target = file, .fragment = frag };
}

fn findSpdx(bytes: []const u8) ?[]const u8 {
    const key = "SPDX-License-Identifier:";
    var it = std.mem.splitScalar(u8, bytes, '\n');
    var n: usize = 0;
    while (it.next()) |line| : (n += 1) {
        if (n >= 12) break;
        const k = std.mem.indexOf(u8, line, key) orelse continue;
        var v = std.mem.trim(u8, line[k + key.len ..], " \t\r");
        if (std.mem.endsWith(u8, v, "-->")) v = std.mem.trimRight(u8, v[0 .. v.len - 3], " \t");
        if (std.mem.endsWith(u8, v, "*/")) v = std.mem.trimRight(u8, v[0 .. v.len - 2], " \t");
        return if (v.len == 0) null else v;
    }
    return null;
}

const command_words = [_][]const u8{
    "just", "zig",    "cargo", "bun",    "bunx",       "git",            "gh",        "make",
    "guix", "podman", "chpl",  "idris2", "dune",       "opam",           "julia",     "bash",
    "sh",   "jq",     "curl",  "plasma", "docudactyl", "docudactyl-hpc", "reconcile", "docs-ingest",
    "mise", "gleam",  "mix",   "rustc",  "nickel",     "sbatch",         "srun",      "pack",
};

fn isPathChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-' or c == '/';
}

/// Decide whether inline code looks like a repository path or a command.
/// Paths must contain '/', use only path characters, and not look like
/// `owner/repo` or a branch name (two segments with no extension).
pub fn classifyCode(v: []const u8) ?RefKind {
    const s = std.mem.trim(u8, v, " \t");
    if (s.len == 0) return null;
    if (std.mem.indexOfScalar(u8, s, ' ')) |k| {
        const first = s[0..k];
        for (command_words) |w| if (std.mem.eql(u8, first, w)) return .command;
        if (std.mem.startsWith(u8, first, "./") and first.len > 2) return .command;
        return null;
    }
    if (std.mem.indexOfScalar(u8, s, '/') == null) return null;
    if (s[0] == '/' or s[0] == '~' or s[0] == '-') return null;
    if (std.mem.indexOf(u8, s, "//") != null) return null;
    for (s) |c| if (!isPathChar(c)) return null;
    // a first segment like "cgr.dev" or "github.com" names a host, not a path
    const first_seg = s[0..std.mem.indexOfScalar(u8, s, '/').?];
    if (first_seg.len > 0 and first_seg[0] != '.' and std.mem.indexOfScalar(u8, first_seg, '.') != null) {
        const tld = first_seg[std.mem.lastIndexOfScalar(u8, first_seg, '.').? + 1 ..];
        var alpha = tld.len >= 2;
        for (tld) |c| alpha = alpha and std.ascii.isLower(c);
        if (alpha) return null;
    }
    var segs: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimRight(u8, s, "/"), '/');
    var last: []const u8 = "";
    while (it.next()) |seg| {
        if (seg.len == 0) return null;
        segs += 1;
        last = seg;
    }
    const has_ext = std.mem.lastIndexOfScalar(u8, last, '.') != null and last[0] != '.';
    const is_dir = s[s.len - 1] == '/';
    if (segs <= 2 and !has_ext and !is_dir) return null;
    return .path;
}

/// Mask inline code spans with spaces, keeping columns. Returns the masked
/// line and the code spans found, as (start, end) byte offsets of content.
fn maskCode(a: std.mem.Allocator, line: []const u8, spans: *std.ArrayList([2]usize)) ![]u8 {
    const out = try a.dupe(u8, line);
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] != '`') {
            i += 1;
            continue;
        }
        var n: usize = 0;
        while (i + n < line.len and line[i + n] == '`') n += 1;
        const open_end = i + n;
        // find a closing run of exactly n backticks
        var j = open_end;
        var close: ?usize = null;
        while (j < line.len) {
            if (line[j] == '`') {
                var m: usize = 0;
                while (j + m < line.len and line[j + m] == '`') m += 1;
                if (m == n) {
                    close = j;
                    break;
                }
                j += m;
            } else j += 1;
        }
        if (close) |c| {
            try spans.append(a, .{ open_end, c });
            @memset(out[i .. c + n], ' ');
            i = c + n;
        } else {
            i = open_end;
        }
    }
    return out;
}

fn addRefs(b: *Builder, line: []const u8, lineno: u32, spans: []const [2]usize) !void {
    for (spans) |sp| {
        const raw = line[sp[0]..sp[1]];
        const kind = classifyCode(raw) orelse continue;
        const lead = raw.len - std.mem.trimLeft(u8, raw, " ").len;
        const v = std.mem.trim(u8, raw, " \t");
        try b.refs.append(b.a, .{ .kind = kind, .value = v, .span = Builder.span(lineno, sp[0] + lead, sp[0] + lead + v.len) });
    }
}

fn linesOf(a: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |l| try out.append(a, std.mem.trimRight(u8, l, "\r"));
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0 and bytes.len > 0 and bytes[bytes.len - 1] == '\n') _ = out.pop();
    return out.items;
}

// ── AsciiDoc ────────────────────────────────────────────────────────────

const AdocState = struct {
    attrs: std.StringHashMapUnmanaged([]const u8) = .empty,
    sectids: bool = true,
    idprefix: []const u8 = "_",
    idseparator: []const u8 = "_",
};

fn adocSubst(a: std.mem.Allocator, st: *const AdocState, s: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, s, '{') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, '}')) |e| {
                if (st.attrs.get(s[i + 1 .. e])) |v| {
                    try out.appendSlice(a, v);
                    i = e + 1;
                    continue;
                }
                return null; // unresolved attribute: cannot judge this target
            }
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

/// Strip common inline markup from heading text before making an id.
fn stripInline(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '<') { // drop html-ish tags
            if (std.mem.indexOfScalarPos(u8, s, i, '>')) |e| {
                i = e;
                continue;
            }
        }
        if (c == '*' or c == '`' or c == '#') continue;
        try out.append(a, c);
    }
    return out.items;
}

/// Asciidoctor-style section id: lowercase, drop characters that are not
/// word characters, space, '-' or '.', then join runs of space, '.', '-'
/// (and the separator) with the separator, trim it, and add the prefix.
pub fn adocId(a: std.mem.Allocator, text: []const u8, prefix: []const u8, sep: []const u8) ![]const u8 {
    const plain = try stripInline(a, text);
    var kept: std.ArrayList(u8) = .empty;
    for (plain) |c| {
        const lc = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lc) or lc == '_' or lc == ' ' or lc == '-' or lc == '.' or lc >= 0x80)
            try kept.append(a, lc);
    }
    var out: std.ArrayList(u8) = .empty;
    var run = false;
    for (kept.items) |c| {
        const is_sep_char = c == ' ' or c == '.' or c == '-' or (sep.len == 1 and c == sep[0]);
        if (is_sep_char) {
            run = true;
            continue;
        }
        if (run and out.items.len > 0) try out.appendSlice(a, sep);
        run = false;
        try out.append(a, c);
    }
    return try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, out.items });
}

fn isDelimiter(line: []const u8) ?u8 {
    if (std.mem.startsWith(u8, line, "```")) return '`';
    if (line.len < 4) return null;
    const c = line[0];
    if (c != '-' and c != '.' and c != '+' and c != '/') return null;
    for (line) |x| if (x != c) return null;
    return c;
}

fn parseAnchorBody(body: []const u8) []const u8 {
    const id = if (std.mem.indexOfScalar(u8, body, ',')) |k| body[0..k] else body;
    return std.mem.trim(u8, id, " ");
}

/// Block anchor line `[[id]]`, `[[id,label]]` or `[#id]` / `[#id.role]`.
fn adocBlockAnchor(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t");
    if (std.mem.startsWith(u8, t, "[[") and std.mem.endsWith(u8, t, "]]") and t.len > 4) {
        const inner = std.mem.trim(u8, t[2 .. t.len - 2], "[]");
        const id = parseAnchorBody(inner);
        return if (id.len > 0) id else null;
    }
    if (std.mem.startsWith(u8, t, "[#") and std.mem.endsWith(u8, t, "]")) {
        var body = t[2 .. t.len - 1];
        for (body, 0..) |c, k| if (c == '.' or c == '%' or c == ',') {
            body = body[0..k];
            break;
        };
        return if (body.len > 0) body else null;
    }
    return null;
}

fn adocHeading(line: []const u8) ?struct { level: u8, text: []const u8, text_off: usize } {
    var n: usize = 0;
    while (n < line.len and line[n] == '=') n += 1;
    if (n == 0 or n > 6 or n >= line.len or line[n] != ' ') return null;
    var text = std.mem.trim(u8, line[n + 1 ..], " \t");
    // symmetric trailing marker: "== Title =="
    const tr = std.mem.trimRight(u8, text, "=");
    if (tr.len < text.len and tr.len > 0 and tr[tr.len - 1] == ' ') text = std.mem.trimRight(u8, tr, " ");
    if (text.len == 0) return null;
    const off = std.mem.indexOf(u8, line, text) orelse n + 1;
    return .{ .level = @intCast(n - 1), .text = text, .text_off = off };
}

fn adocAddTarget(b: *Builder, st: *const AdocState, raw: []const u8, text: ?[]const u8, lineno: u32, s: usize, e: usize, xref: bool) !void {
    const sub = (try adocSubst(b.a, st, raw)) orelse return;
    const t = std.mem.trim(u8, sub, " ");
    if (t.len == 0) return;
    if (xref and !isExternal(t)) {
        // xref / <<>>: "id", "file.adoc", "file.adoc#id", "file#id", "#id"
        if (std.mem.indexOfScalar(u8, t, '#')) |k| {
            var file = t[0..k];
            const frag = t[k + 1 ..];
            if (file.len == 0) {
                try b.links.append(b.a, .{ .kind = .internal_anchor, .target = try std.fmt.allocPrint(b.a, "#{s}", .{frag}), .fragment = null, .text = text, .span = Builder.span(lineno, s, e) });
                return;
            }
            if (std.mem.lastIndexOfScalar(u8, std.fs.path.basenamePosix(file), '.') == null)
                file = try std.fmt.allocPrint(b.a, "{s}.adoc", .{file});
            try b.links.append(b.a, .{ .kind = .internal_file, .target = file, .fragment = frag, .text = text, .span = Builder.span(lineno, s, e) });
            return;
        }
        if (formatOf(t) != null) {
            try b.links.append(b.a, .{ .kind = .internal_file, .target = t, .fragment = null, .text = text, .span = Builder.span(lineno, s, e) });
            return;
        }
        try b.links.append(b.a, .{ .kind = .internal_anchor, .target = try std.fmt.allocPrint(b.a, "#{s}", .{t}), .fragment = null, .text = text, .span = Builder.span(lineno, s, e) });
        return;
    }
    const c = (try classify(b.a, t)) orelse return;
    try b.links.append(b.a, .{ .kind = c.kind, .target = c.target, .fragment = c.fragment, .text = text, .span = Builder.span(lineno, s, e) });
}

fn urlEnd(line: []const u8, start: usize) usize {
    var j = start;
    while (j < line.len) : (j += 1) {
        const c = line[j];
        if (c == ' ' or c == '\t' or c == '[' or c == '<' or c == '>' or c == '"' or c == '\'' or c == ')') break;
    }
    // trailing punctuation is not part of a bare URL
    while (j > start and (line[j - 1] == '.' or line[j - 1] == ',' or line[j - 1] == ';' or line[j - 1] == ':')) j -= 1;
    return j;
}

fn bracketText(line: []const u8, open: usize) ?struct { text: []const u8, end: usize } {
    // line[open] == '['; return text and index after ']'
    var depth: usize = 0;
    var j = open;
    while (j < line.len) : (j += 1) {
        if (line[j] == '[') depth += 1;
        if (line[j] == ']') {
            depth -= 1;
            if (depth == 0) return .{ .text = line[open + 1 .. j], .end = j + 1 };
        }
    }
    return null;
}

fn adocLine(b: *Builder, st: *const AdocState, line: []const u8, m: []const u8, lineno: u32) !void {
    var i: usize = 0;
    while (i < m.len) {
        const rest = m[i..];
        // <<target,text>>
        if (std.mem.startsWith(u8, rest, "<<")) {
            if (std.mem.indexOfPos(u8, m, i + 2, ">>")) |e| {
                const body = m[i + 2 .. e];
                const comma = std.mem.indexOfScalar(u8, body, ',');
                const target = if (comma) |k| body[0..k] else body;
                const text: ?[]const u8 = if (comma) |k| std.mem.trim(u8, line[i + 2 + k + 1 .. e], " ") else null;
                try adocAddTarget(b, st, target, text, lineno, i, e + 2, true);
                i = e + 2;
                continue;
            }
        }
        // [[id]] inline anchor (also [[[bib]]])
        if (std.mem.startsWith(u8, rest, "[[")) {
            if (std.mem.indexOfPos(u8, m, i + 2, "]]")) |e| {
                const id = parseAnchorBody(std.mem.trim(u8, m[i + 2 .. e], "["));
                if (id.len > 0 and std.mem.indexOfScalar(u8, id, ' ') == null) {
                    try b.anchors.append(b.a, .{ .id = id, .span = Builder.span(lineno, i, e + 2) });
                    try b.claim(id);
                }
                i = e + 2;
                while (i < m.len and m[i] == ']') i += 1;
                continue;
            }
        }
        const macros = [_]struct { p: []const u8, kind: enum { xref, link, include, image, anchor } }{
            .{ .p = "include::", .kind = .include },
            .{ .p = "image::", .kind = .image },
            .{ .p = "image:", .kind = .image },
            .{ .p = "xref:", .kind = .xref },
            .{ .p = "link:", .kind = .link },
            .{ .p = "anchor:", .kind = .anchor },
        };
        var matched = false;
        for (macros) |mac| {
            if (!std.mem.startsWith(u8, rest, mac.p)) continue;
            if (i > 0 and (std.ascii.isAlphanumeric(m[i - 1]) or m[i - 1] == '_')) continue;
            const ts = i + mac.p.len;
            const ob = std.mem.indexOfScalarPos(u8, m, ts, '[') orelse continue;
            const target = m[ts..ob];
            if (target.len == 0 or std.mem.indexOfAny(u8, target, " \t") != null) continue;
            const bt = bracketText(line, ob) orelse continue;
            const text: ?[]const u8 = if (bt.text.len > 0) bt.text else null;
            switch (mac.kind) {
                .include => {
                    const sub = (try adocSubst(b.a, st, target)) orelse null;
                    if (sub) |t| {
                        if (isExternal(t))
                            try b.links.append(b.a, .{ .kind = .external_url, .target = t, .fragment = null, .text = null, .span = Builder.span(lineno, i, bt.end) })
                        else
                            try b.links.append(b.a, .{ .kind = .include, .target = t, .fragment = null, .text = null, .span = Builder.span(lineno, i, bt.end) });
                    }
                },
                .image => {
                    const sub = (try adocSubst(b.a, st, target)) orelse null;
                    if (sub) |t0| {
                        var t = t0;
                        if (!isExternal(t) and t[0] != '/') {
                            if (st.attrs.get("imagesdir")) |dir| {
                                if (dir.len > 0) t = try std.fmt.allocPrint(b.a, "{s}/{s}", .{ std.mem.trimRight(u8, dir, "/"), t });
                            }
                        }
                        if (!isExternal(t) or isExternal(t0)) try adocAddTarget(b, st, t, text, lineno, i, bt.end, false);
                    }
                },
                .xref => try adocAddTarget(b, st, target, text, lineno, i, bt.end, true),
                .link => try adocAddTarget(b, st, target, text, lineno, i, bt.end, false),
                .anchor => {
                    try b.anchors.append(b.a, .{ .id = target, .span = Builder.span(lineno, i, bt.end) });
                    try b.claim(target);
                },
            }
            i = bt.end;
            matched = true;
            break;
        }
        if (matched) continue;
        // bare URL, optionally followed by [text]
        if ((std.mem.startsWith(u8, rest, "https://") or std.mem.startsWith(u8, rest, "http://") or std.mem.startsWith(u8, rest, "mailto:")) and
            (i == 0 or !std.ascii.isAlphanumeric(m[i - 1])))
        {
            const e = urlEnd(m, i);
            var end = e;
            var text: ?[]const u8 = null;
            if (e < m.len and m[e] == '[') {
                if (bracketText(line, e)) |bt| {
                    text = if (bt.text.len > 0) bt.text else null;
                    end = bt.end;
                }
            }
            try b.links.append(b.a, .{ .kind = .external_url, .target = m[i..e], .fragment = null, .text = text, .span = Builder.span(lineno, i, end) });
            i = end;
            continue;
        }
        i += 1;
    }
}

fn parseAdoc(b: *Builder, lines: []const []const u8) !?[]const u8 {
    var st: AdocState = .{};
    var title: ?[]const u8 = null;
    var block: ?u8 = null;
    var block_len: usize = 0;
    var pending_id: ?[]const u8 = null;
    var code: std.ArrayList([2]usize) = .empty;

    for (lines, 0..) |line, idx| {
        const lineno: u32 = @intCast(idx + 1);
        if (block) |d| {
            if (isDelimiter(line) == d and (d == '`' or line.len == block_len)) block = null;
            continue;
        }
        if (isDelimiter(line)) |d| {
            block = d;
            block_len = line.len;
            pending_id = null;
            continue;
        }
        if (std.mem.startsWith(u8, line, "//")) continue; // line comment
        if (line.len > 1 and line[0] == ':') { // attribute entry
            if (std.mem.indexOfScalarPos(u8, line, 1, ':')) |e| {
                const nm = line[1..e];
                const val = std.mem.trim(u8, line[e + 1 ..], " \t");
                if (nm.len > 0 and nm[nm.len - 1] == '!') {
                    const base = nm[0 .. nm.len - 1];
                    if (std.mem.eql(u8, base, "sectids")) st.sectids = false;
                    _ = st.attrs.remove(base);
                } else if (nm.len > 0 and nm[0] == '!') {
                    if (std.mem.eql(u8, nm[1..], "sectids")) st.sectids = false;
                    _ = st.attrs.remove(nm[1..]);
                } else if (nm.len > 0) {
                    try st.attrs.put(b.a, nm, val);
                    if (std.mem.eql(u8, nm, "idprefix")) st.idprefix = val;
                    if (std.mem.eql(u8, nm, "idseparator")) st.idseparator = val;
                    if (std.mem.eql(u8, nm, "sectids")) st.sectids = true;
                }
                continue;
            }
        }
        if (adocBlockAnchor(line)) |id| {
            pending_id = id;
            try b.anchors.append(b.a, .{ .id = id, .span = Builder.span(lineno, 0, line.len) });
            try b.claim(id);
            continue;
        }
        if (line.len > 0 and line[0] == '[' and line[line.len - 1] == ']' and std.mem.indexOf(u8, line, "[[") == null) {
            continue; // block attribute line such as [source,zig]; keep pending id
        }
        code.clearRetainingCapacity();
        const masked = try maskCode(b.a, line, &code);
        if (adocHeading(line)) |h| {
            var text = h.text;
            var id: ?[]const u8 = pending_id;
            // inline anchor at the start of the title: == [[id]]Title
            if (std.mem.startsWith(u8, text, "[[")) {
                if (std.mem.indexOf(u8, text, "]]")) |e| {
                    id = parseAnchorBody(text[2..e]);
                    text = std.mem.trim(u8, text[e + 2 ..], " ");
                }
            }
            if (h.level == 0) {
                if (title == null) title = text;
            } else if (id == null and st.sectids) {
                const base = try adocId(b.a, text, st.idprefix, st.idseparator);
                id = try b.unique(base, .asciidoc, st.idseparator);
            } else if (id) |x| try b.claim(x);
            try b.headings.append(b.a, .{ .level = h.level, .text = text, .id = id, .span = Builder.span(lineno, 0, line.len) });
            pending_id = null;
            try adocLine(b, &st, line, masked, lineno);
            continue;
        }
        if (std.mem.trim(u8, line, " \t").len > 0) pending_id = null;
        try adocLine(b, &st, line, masked, lineno);
        try addRefs(b, line, lineno, code.items);
    }
    // Natural cross references: <<Section Title>> points at the section
    // whose title matches exactly. Map those to the section's id.
    for (b.links.items) |*l| {
        if (l.kind != .internal_anchor) continue;
        const want = l.target[1..];
        if (b.ids.contains(want)) continue;
        for (b.headings.items) |h| {
            if (h.id != null and std.mem.eql(u8, h.text, want)) {
                l.target = try std.fmt.allocPrint(b.a, "#{s}", .{h.id.?});
                break;
            }
        }
    }
    return title;
}

// ── Markdown ────────────────────────────────────────────────────────────

/// GitHub-style heading slug: lowercase, keep letters, digits, '-', '_'
/// and non-ASCII bytes, turn spaces into '-', drop everything else.
pub fn mdSlug(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const plain = try mdPlain(a, text);
    var out: std.ArrayList(u8) = .empty;
    for (plain) |c| {
        const lc = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lc) or lc == '-' or lc == '_' or lc >= 0x80) {
            try out.append(a, lc);
        } else if (lc == ' ') try out.append(a, '-');
    }
    return out.items;
}

/// Heading text as rendered: `[text](url)` becomes text, images and inline
/// html are dropped, emphasis and code markers are removed.
fn mdPlain(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '!' and i + 1 < s.len and s[i + 1] == '[') {
            if (bracketText(s, i + 1)) |bt| {
                var e = bt.end;
                if (e < s.len and s[e] == '(') e = (std.mem.indexOfScalarPos(u8, s, e, ')') orelse s.len - 1) + 1;
                i = e;
                continue;
            }
        }
        if (c == '[') {
            if (bracketText(s, i)) |bt| {
                if (bt.end < s.len and s[bt.end] == '(') {
                    try out.appendSlice(a, try mdPlain(a, bt.text));
                    i = (std.mem.indexOfScalarPos(u8, s, bt.end, ')') orelse s.len - 1) + 1;
                    continue;
                }
            }
        }
        if (c == '<') {
            if (std.mem.indexOfScalarPos(u8, s, i, '>')) |e| {
                i = e + 1;
                continue;
            }
        }
        if (c == '*' or c == '`') {
            i += 1;
            continue;
        }
        try out.append(a, c);
        i += 1;
    }
    return out.items;
}

fn mdFence(line: []const u8) ?struct { ch: u8, n: usize } {
    const t = std.mem.trimLeft(u8, line, " ");
    if (line.len - t.len > 3 or t.len < 3) return null;
    const c = t[0];
    if (c != '`' and c != '~') return null;
    var n: usize = 0;
    while (n < t.len and t[n] == c) n += 1;
    if (n < 3) return null;
    if (c == '`' and std.mem.indexOfScalarPos(u8, t, n, '`') != null) return null;
    return .{ .ch = c, .n = n };
}

fn mdAddTarget(b: *Builder, raw: []const u8, text: ?[]const u8, lineno: u32, s: usize, e: usize) !void {
    var t = std.mem.trim(u8, raw, " \t");
    if (t.len > 0 and t[0] == '<') {
        t = if (std.mem.indexOfScalar(u8, t, '>')) |k| t[1..k] else t[1..];
    } else if (std.mem.indexOfAny(u8, t, " \t")) |k| t = t[0..k]; // drop "title"
    const c = (try classify(b.a, t)) orelse return;
    try b.links.append(b.a, .{ .kind = c.kind, .target = c.target, .fragment = c.fragment, .text = text, .span = Builder.span(lineno, s, e) });
}

fn parenTarget(m: []const u8, open: usize) ?usize {
    // m[open] == '('; return index of matching ')'
    var depth: usize = 0;
    var j = open;
    while (j < m.len) : (j += 1) {
        if (m[j] == '(') depth += 1;
        if (m[j] == ')') {
            depth -= 1;
            if (depth == 0) return j;
        }
    }
    return null;
}

fn htmlAttr(m: []const u8, at: usize, name: []const u8) ?struct { v: []const u8, s: usize, e: usize } {
    if (!std.mem.startsWith(u8, m[at..], name)) return null;
    if (at > 0 and std.ascii.isAlphanumeric(m[at - 1])) return null;
    const q = at + name.len;
    if (q >= m.len or (m[q] != '"' and m[q] != '\'')) return null;
    const close = std.mem.indexOfScalarPos(u8, m, q + 1, m[q]) orelse return null;
    return .{ .v = m[q + 1 .. close], .s = at, .e = close + 1 };
}

fn mdLine(b: *Builder, line: []const u8, m: []const u8, lineno: u32) !void {
    var skips: std.ArrayList([2]usize) = .empty;
    var i: usize = 0;
    outer: while (i < m.len) {
        for (skips.items) |r| if (i == r[0]) {
            i = r[1];
            continue :outer;
        };
        const c = m[i];
        if (c == '\\') {
            i += 2;
            continue;
        }
        // [text](target) and ![alt](src)
        if (c == '[' or (c == '!' and i + 1 < m.len and m[i + 1] == '[')) {
            const ob = if (c == '!') i + 1 else i;
            if (bracketText(m, ob)) |bt| {
                if (bt.end < m.len and m[bt.end] == '(') {
                    if (parenTarget(m, bt.end)) |cp| {
                        const text: ?[]const u8 = if (bt.text.len > 0) line[ob + 1 .. bt.end - 1] else null;
                        try mdAddTarget(b, m[bt.end + 1 .. cp], text, lineno, i, cp + 1);
                        try skips.append(b.a, .{ bt.end, cp + 1 });
                        i = ob + 1; // scan the link text for nested images
                        continue;
                    }
                }
            }
        }
        // <https://...> autolink
        if (c == '<' and std.mem.indexOfScalarPos(u8, m, i, '>') != null) {
            const e = std.mem.indexOfScalarPos(u8, m, i, '>').?;
            const inner = m[i + 1 .. e];
            if (isSchemeStart(inner) != null and std.mem.indexOfAny(u8, inner, " \t") == null) {
                try b.links.append(b.a, .{ .kind = .external_url, .target = inner, .fragment = null, .text = null, .span = Builder.span(lineno, i, e + 1) });
                i = e + 1;
                continue;
            }
        }
        // html attributes: href, src, and anchors via id / name
        inline for (.{ "href=", "src=" }) |nm| {
            if (htmlAttr(m, i, nm)) |h| {
                try mdAddTarget(b, h.v, null, lineno, h.s, h.e);
                i = h.e;
                continue :outer;
            }
        }
        inline for (.{ "id=", "name=" }) |nm| {
            if (htmlAttr(m, i, nm)) |h| {
                if (h.v.len > 0) {
                    try b.anchors.append(b.a, .{ .id = h.v, .span = Builder.span(lineno, h.s, h.e) });
                    try b.claim(h.v);
                }
                i = h.e;
                continue :outer;
            }
        }
        // bare URL (GFM autolink extension)
        if ((std.mem.startsWith(u8, m[i..], "https://") or std.mem.startsWith(u8, m[i..], "http://")) and
            (i == 0 or !std.ascii.isAlphanumeric(m[i - 1])))
        {
            const e = urlEnd(m, i);
            try b.links.append(b.a, .{ .kind = .external_url, .target = m[i..e], .fragment = null, .text = null, .span = Builder.span(lineno, i, e) });
            i = e;
            continue;
        }
        i += 1;
    }
}

fn mdAtx(line: []const u8) ?struct { level: u8, text: []const u8 } {
    const t = std.mem.trimLeft(u8, line, " ");
    if (line.len - t.len > 3) return null;
    var n: usize = 0;
    while (n < t.len and t[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < t.len and t[n] != ' ' and t[n] != '\t') return null;
    var text = std.mem.trim(u8, t[n..], " \t");
    // closing sequence
    const tr = std.mem.trimRight(u8, text, "#");
    if (tr.len == 0) text = tr else if (tr.len < text.len and (tr[tr.len - 1] == ' ' or tr[tr.len - 1] == '\t')) text = std.mem.trimRight(u8, tr, " \t");
    return .{ .level = @intCast(n), .text = text };
}

fn mdExplicitId(text: []const u8) ?struct { text: []const u8, id: []const u8 } {
    if (!std.mem.endsWith(u8, text, "}")) return null;
    const k = std.mem.lastIndexOf(u8, text, "{#") orelse return null;
    const id = text[k + 2 .. text.len - 1];
    if (id.len == 0 or std.mem.indexOfAny(u8, id, " \t") != null) return null;
    return .{ .text = std.mem.trimRight(u8, text[0..k], " "), .id = id };
}

fn mdHeading(b: *Builder, level: u8, text0: []const u8, lineno: u32, span_end: usize, title: *?[]const u8) !void {
    var text = text0;
    var id: []const u8 = undefined;
    if (mdExplicitId(text)) |x| {
        text = x.text;
        id = x.id;
        try b.claim(id);
    } else {
        id = try b.unique(try mdSlug(b.a, text), .markdown, "-");
    }
    if (title.* == null and level == 1 and b.headings.items.len == 0) title.* = text;
    try b.headings.append(b.a, .{ .level = level, .text = text, .id = id, .span = Builder.span(lineno, 0, span_end) });
}

fn parseMd(b: *Builder, lines: []const []const u8) !?[]const u8 {
    var title: ?[]const u8 = null;
    var fence: ?struct { ch: u8, n: usize } = null;
    var in_comment = false;
    var prev_blank = true;
    var in_indented = false;
    var code: std.ArrayList([2]usize) = .empty;
    var start: usize = 0;

    // YAML front matter
    if (lines.len > 0 and std.mem.eql(u8, lines[0], "---")) {
        for (lines[1..], 1..) |l, k| if (std.mem.eql(u8, l, "---") or std.mem.eql(u8, l, "...")) {
            start = k + 1;
            break;
        };
    }

    var idx = start;
    while (idx < lines.len) : (idx += 1) {
        const line = lines[idx];
        const lineno: u32 = @intCast(idx + 1);
        const blank = std.mem.trim(u8, line, " \t").len == 0;
        if (fence) |f| {
            if (mdFence(line)) |g| if (g.ch == f.ch and g.n >= f.n and std.mem.trim(u8, std.mem.trimLeft(u8, line, " ")[g.n..], " \t").len == 0) {
                fence = null;
            };
            prev_blank = false;
            continue;
        }
        if (mdFence(line)) |f| {
            fence = .{ .ch = f.ch, .n = f.n };
            continue;
        }
        // HTML comments, possibly spanning lines
        var work = line;
        var masked_comment: ?[]u8 = null;
        if (in_comment or std.mem.indexOf(u8, line, "<!--") != null) {
            const mc = try b.a.dupe(u8, line);
            var j: usize = 0;
            while (j < mc.len) {
                if (in_comment) {
                    if (std.mem.indexOfPos(u8, line, j, "-->")) |e| {
                        @memset(mc[j .. e + 3], ' ');
                        j = e + 3;
                        in_comment = false;
                    } else {
                        @memset(mc[j..], ' ');
                        break;
                    }
                } else if (std.mem.indexOfPos(u8, line, j, "<!--")) |s| {
                    j = s;
                    in_comment = true;
                } else break;
            }
            masked_comment = mc;
            work = mc;
        }
        // indented code block
        const indented = std.mem.startsWith(u8, line, "    ") or std.mem.startsWith(u8, line, "\t");
        if (indented and !blank and (prev_blank or in_indented)) {
            in_indented = true;
            prev_blank = false;
            continue;
        }
        if (!blank) in_indented = false;

        code.clearRetainingCapacity();
        const masked = try maskCode(b.a, work, &code);
        if (mdAtx(work)) |h| {
            try mdHeading(b, h.level, h.text, lineno, line.len, &title);
            try mdLine(b, line, masked, lineno);
            prev_blank = false;
            continue;
        }
        // setext underline: applies to the previous non-blank line
        if (!prev_blank and idx > start and !blank) {
            const t = std.mem.trim(u8, work, " \t");
            const all_eq = t.len > 0 and std.mem.allEqual(u8, t, '=');
            const all_dash = t.len >= 2 and std.mem.allEqual(u8, t, '-');
            if (all_eq or all_dash) {
                const prev = lines[idx - 1];
                if (mdAtx(prev) == null and std.mem.trim(u8, prev, " \t").len > 0 and
                    !std.mem.startsWith(u8, std.mem.trimLeft(u8, prev, " "), "- ") and
                    !std.mem.startsWith(u8, std.mem.trimLeft(u8, prev, " "), "* ") and
                    !std.mem.startsWith(u8, std.mem.trimLeft(u8, prev, " "), "|"))
                {
                    try mdHeading(b, if (all_eq) 1 else 2, std.mem.trim(u8, prev, " \t"), lineno - 1, prev.len, &title);
                    prev_blank = false;
                    continue;
                }
            }
        }
        // reference definition: [label]: target
        const tl = std.mem.trimLeft(u8, work, " ");
        if (tl.len > 0 and tl[0] == '[' and work.len - tl.len <= 3) {
            if (std.mem.indexOf(u8, tl, "]:")) |k| {
                const off = work.len - tl.len;
                const tgt = std.mem.trim(u8, tl[k + 2 ..], " \t");
                if (tgt.len > 0 and tl[1] != '^') {
                    try mdAddTarget(b, tgt, tl[1..k], lineno, off, work.len);
                    prev_blank = false;
                    continue;
                }
            }
        }
        try mdLine(b, line, masked, lineno);
        try addRefs(b, line, lineno, code.items);
        prev_blank = blank;
    }
    return title;
}

// ── Entry point ─────────────────────────────────────────────────────────

/// Parse one prose file. The arena owns every slice in the result.
pub fn parse(arena: std.mem.Allocator, path: []const u8, bytes: []const u8, format: Format) Error!Doc {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var b: Builder = .{ .a = arena };
    const lines = try linesOf(arena, bytes);
    const title = switch (format) {
        .asciidoc => try parseAdoc(&b, lines),
        .markdown => try parseMd(&b, lines),
    };
    return .{
        .path = path,
        .format = format,
        .sha256 = std.fmt.bytesToHex(digest, .lower),
        .spdx = findSpdx(bytes),
        .title = title,
        .headings = b.headings.items,
        .anchors = b.anchors.items,
        .links = b.links.items,
        .references = b.refs.items,
    };
}

// ── JSON output ─────────────────────────────────────────────────────────

pub const Json = struct {
    a: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    pub fn raw(j: *Json, s: []const u8) !void {
        try j.out.appendSlice(j.a, s);
    }

    pub fn str(j: *Json, s: []const u8) !void {
        try j.out.append(j.a, '"');
        for (s) |c| switch (c) {
            '"' => try j.raw("\\\""),
            '\\' => try j.raw("\\\\"),
            '\n' => try j.raw("\\n"),
            '\r' => try j.raw("\\r"),
            '\t' => try j.raw("\\t"),
            0...8, 11, 12, 14...31, 127 => try j.raw(try std.fmt.allocPrint(j.a, "\\u{x:0>4}", .{c})),
            else => try j.out.append(j.a, c),
        };
        try j.out.append(j.a, '"');
    }

    pub fn optStr(j: *Json, s: ?[]const u8) !void {
        if (s) |v| try j.str(v) else try j.raw("null");
    }

    fn span(j: *Json, s: Span) !void {
        try j.raw(try std.fmt.allocPrint(j.a, "{{\"start\":{{\"line\":{d},\"col\":{d}}},\"end\":{{\"line\":{d},\"col\":{d}}}}}", .{ s.start.line, s.start.col, s.end.line, s.end.col }));
    }

    pub fn doc(j: *Json, d: Doc, repo: []const u8, rev: []const u8) !void {
        try j.raw("{\"schema\":\"docmodel/v0\",\"repo\":");
        try j.str(repo);
        try j.raw(",\"rev\":");
        try j.str(rev);
        try j.raw(",\"path\":");
        try j.str(d.path);
        try j.raw(",\"format\":");
        try j.str(@tagName(d.format));
        try j.raw(",\"sha256\":");
        try j.str(&d.sha256);
        try j.raw(",\"spdx\":");
        try j.optStr(d.spdx);
        try j.raw(",\"title\":");
        try j.optStr(d.title);
        try j.raw(",\"headings\":[");
        for (d.headings, 0..) |h, k| {
            if (k > 0) try j.raw(",");
            try j.raw(try std.fmt.allocPrint(j.a, "{{\"level\":{d},\"text\":", .{h.level}));
            try j.str(h.text);
            try j.raw(",\"id\":");
            try j.optStr(h.id);
            try j.raw(",\"span\":");
            try j.span(h.span);
            try j.raw("}");
        }
        try j.raw("],\"anchors\":[");
        for (d.anchors, 0..) |x, k| {
            if (k > 0) try j.raw(",");
            try j.raw("{\"id\":");
            try j.str(x.id);
            try j.raw(",\"span\":");
            try j.span(x.span);
            try j.raw("}");
        }
        try j.raw("],\"links\":[");
        for (d.links, 0..) |l, k| {
            if (k > 0) try j.raw(",");
            try j.raw("{\"kind\":");
            try j.str(l.kind.name());
            try j.raw(",\"target\":");
            try j.str(l.target);
            try j.raw(",\"fragment\":");
            try j.optStr(l.fragment);
            try j.raw(",\"text\":");
            try j.optStr(l.text);
            try j.raw(",\"span\":");
            try j.span(l.span);
            try j.raw("}");
        }
        try j.raw("],\"references\":[");
        for (d.references, 0..) |r, k| {
            if (k > 0) try j.raw(",");
            try j.raw("{\"kind\":");
            try j.str(@tagName(r.kind));
            try j.raw(",\"value\":");
            try j.str(r.value);
            try j.raw(",\"span\":");
            try j.span(r.span);
            try j.raw("}");
        }
        try j.raw("]}");
    }
};

/// Reject paths that are absolute, climb with "..", or hold odd bytes.
pub fn safeRepoPath(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/' or p.len > 4096) return false;
    for (p) |c| if (c < 0x20 or c == 0x7f or c == '\\') return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return false;
    }
    return true;
}

pub fn validRev(rev: []const u8) bool {
    if (rev.len != 40) return false;
    for (rev) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

pub fn validRepo(repo: []const u8) bool {
    const k = std.mem.indexOfScalar(u8, repo, '/') orelse return false;
    if (k == 0 or k == repo.len - 1 or std.mem.indexOfScalarPos(u8, repo, k + 1, '/') != null) return false;
    for (repo) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '/')) return false;
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────────

const tt = std.testing;

fn parseStr(a: std.mem.Allocator, path: []const u8, s: []const u8) !Doc {
    return parse(a, path, s, formatOf(path).?);
}

test "asciidoc headings, ids, title and spdx" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const d = try parseStr(arena.allocator(),
        \\README.adoc
    ,
        \\// SPDX-License-Identifier: CC-BY-SA-4.0
        \\= Docudactyl
        \\
        \\== Quick Start
        \\
        \\[[custom]]
        \\=== Build it now
        \\
        \\== Quick Start
        \\
        \\----
        \\== not a heading
        \\----
        \\
    );
    try tt.expectEqualStrings("CC-BY-SA-4.0", d.spdx.?);
    try tt.expectEqualStrings("Docudactyl", d.title.?);
    try tt.expectEqual(@as(usize, 4), d.headings.len);
    try tt.expectEqual(@as(u8, 0), d.headings[0].level);
    try tt.expect(d.headings[0].id == null);
    try tt.expectEqualStrings("_quick_start", d.headings[1].id.?);
    try tt.expectEqualStrings("custom", d.headings[2].id.?);
    try tt.expectEqualStrings("_quick_start_2", d.headings[3].id.?);
    try tt.expectEqual(@as(u32, 4), d.headings[1].span.start.line);
}

test "asciidoc idprefix and idseparator attributes" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const d = try parseStr(arena.allocator(), "a.adoc",
        \\= T
        \\:idprefix:
        \\:idseparator: -
        \\
        \\== 1. What the *tools* are today
    );
    try tt.expectEqualStrings("1-what-the-tools-are-today", d.headings[1].id.?);
}

test "asciidoc natural cross reference by section title" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const d = try parseStr(arena.allocator(), "a.adoc",
        \\See <<Getting Started>> and <<no such title>>.
        \\
        \\== Getting Started
    );
    try tt.expectEqualStrings("#_getting_started", d.links[0].target);
    try tt.expectEqualStrings("#no such title", d.links[1].target);
}

test "asciidoc links, xrefs, includes and anchors" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const d = try parseStr(arena.allocator(), "docs/guide.adoc",
        \\:base: ../src
        \\See <<setup>> and <<other.adoc#install,Install>> and xref:api/index.adoc[API].
        \\Read link:CHANGELOG.adoc[] or https://example.org/x[site] and xref:faq#q1[].
        \\include::{base}/part.adoc[]
        \\include::{missing}/part.adoc[]
        \\[[setup]]Setup text with anchor:here[] and `<<not-a-link>>`.
    );
    const L = d.links;
    try tt.expectEqual(@as(usize, 7), L.len);
    try tt.expectEqual(LinkKind.internal_anchor, L[0].kind);
    try tt.expectEqualStrings("#setup", L[0].target);
    try tt.expectEqual(LinkKind.internal_file, L[1].kind);
    try tt.expectEqualStrings("other.adoc", L[1].target);
    try tt.expectEqualStrings("install", L[1].fragment.?);
    try tt.expectEqualStrings("Install", L[1].text.?);
    try tt.expectEqualStrings("api/index.adoc", L[2].target);
    try tt.expectEqualStrings("CHANGELOG.adoc", L[3].target);
    try tt.expectEqual(LinkKind.external_url, L[4].kind);
    try tt.expectEqualStrings("https://example.org/x", L[4].target);
    try tt.expectEqualStrings("faq.adoc", L[5].target);
    try tt.expectEqualStrings("q1", L[5].fragment.?);
    try tt.expectEqual(LinkKind.include, L[6].kind);
    try tt.expectEqualStrings("../src/part.adoc", L[6].target);
    try tt.expectEqual(@as(usize, 2), d.anchors.len);
    try tt.expectEqualStrings("setup", d.anchors[0].id);
    try tt.expectEqualStrings("here", d.anchors[1].id);
    try tt.expectEqual(@as(u32, 5), L[0].span.start.col);
}

test "markdown headings, slugs, links and code" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const d = try parseStr(arena.allocator(), "README.md",
        \\<!-- SPDX-License-Identifier: MPL-2.0 -->
        \\# Plasma Tool
        \\
        \\[![CI](badge.svg)](https://ci.example/x) see [guide](docs/guide.md#set-up "Guide").
        \\
        \\## Set Up `zig` *now*!
        \\
        \\Run `just build` and edit `src/main.zig`; not `owner/repo`.
        \\
        \\```sh
        \\[no](link.md)
        \\```
        \\
        \\## Set Up `zig` *now*!
        \\Setext Title
        \\------------
        \\<a name="legacy"></a> [top](#plasma-tool) <https://example.org>
        \\
        \\[ref]: ./other.md
        \\<!-- [hidden](gone.md) -->
    );
    try tt.expectEqualStrings("MPL-2.0", d.spdx.?);
    try tt.expectEqualStrings("Plasma Tool", d.title.?);
    try tt.expectEqual(@as(usize, 4), d.headings.len);
    try tt.expectEqualStrings("plasma-tool", d.headings[0].id.?);
    try tt.expectEqualStrings("set-up-zig-now", d.headings[1].id.?);
    try tt.expectEqualStrings("set-up-zig-now-1", d.headings[2].id.?);
    try tt.expectEqualStrings("setext-title", d.headings[3].id.?);
    try tt.expectEqual(@as(u8, 2), d.headings[3].level);

    const L = d.links;
    try tt.expectEqual(@as(usize, 6), L.len);
    try tt.expectEqual(LinkKind.external_url, L[0].kind); // outer badge link
    try tt.expectEqualStrings("badge.svg", L[1].target); // nested image
    try tt.expectEqualStrings("docs/guide.md", L[2].target);
    try tt.expectEqualStrings("set-up", L[2].fragment.?);
    try tt.expectEqual(LinkKind.internal_anchor, L[3].kind);
    try tt.expectEqualStrings("https://example.org", L[4].target);
    try tt.expectEqualStrings("./other.md", L[5].target);
    try tt.expectEqual(@as(usize, 1), d.anchors.len);
    try tt.expectEqualStrings("legacy", d.anchors[0].id);

    try tt.expectEqual(@as(usize, 2), d.references.len);
    try tt.expectEqual(RefKind.command, d.references[0].kind);
    try tt.expectEqualStrings("just build", d.references[0].value);
    try tt.expectEqualStrings("src/main.zig", d.references[1].value);
}

test "code classification" {
    try tt.expectEqual(RefKind.path, classifyCode("src/main.zig").?);
    try tt.expectEqual(RefKind.path, classifyCode("docs/pipeline/").?);
    try tt.expectEqual(RefKind.path, classifyCode("a/b/c").?);
    try tt.expect(classifyCode("hyperpolymath/standards") == null);
    try tt.expect(classifyCode("README.adoc") == null);
    try tt.expect(classifyCode("/etc/passwd") == null);
    try tt.expect(classifyCode("https://x/y") == null);
    try tt.expect(classifyCode("a/*.zig") == null);
    try tt.expect(classifyCode("cgr.dev/chainguard/wolfi-base") == null);
    try tt.expectEqual(RefKind.path, classifyCode(".github/workflows/ci.yml").?);
    try tt.expectEqual(RefKind.path, classifyCode("ffi/zig/src/docs_ingest.zig").?);
    try tt.expectEqual(RefKind.command, classifyCode("zig build test").?);
    try tt.expect(classifyCode("some words here") == null);
}

test "input validation" {
    try tt.expect(safeRepoPath("docs/a.adoc"));
    try tt.expect(!safeRepoPath("../a"));
    try tt.expect(!safeRepoPath("/etc/x"));
    try tt.expect(!safeRepoPath("a//b"));
    try tt.expect(validRev("0123456789abcdef0123456789abcdef01234567"));
    try tt.expect(!validRev("0123"));
    try tt.expect(validRepo("hyperpolymath/docudactyl"));
    try tt.expect(!validRepo("a/b/c"));
}

test "json escaping and shape" {
    var arena = std.heap.ArenaAllocator.init(tt.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parseStr(a, "x.md", "# Say \"hi\"\n");
    var j: Json = .{ .a = a };
    try j.doc(d, "o/r", "0123456789abcdef0123456789abcdef01234567");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, j.out.items, .{});
    try tt.expectEqualStrings("Say \"hi\"", parsed.object.get("title").?.string);
    try tt.expectEqualStrings("docmodel/v0", parsed.object.get("schema").?.string);
}
