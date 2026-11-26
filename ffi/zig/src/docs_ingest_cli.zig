// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// docs-ingest: write a reconcile-input/v0 bundle for one repository revision.
//
// Usage:
//   docs-ingest --repo OWNER/NAME --rev SHA40 --root DIR --files LIST [--docs LIST]
//
// LIST files hold one repo-relative path per line (for example the output of
// `git ls-files`). --files is the full file list of the revision. --docs
// limits which prose files are parsed; by default every .adoc, .asciidoc,
// .asc, .md and .markdown file in --files is parsed. Docs are read from
// DIR/<path>. The bundle goes to stdout.
//
// Exit codes: 0 when the bundle was written, 2 on a usage or input error.
// The tool only reads; it never writes into DIR.

const std = @import("std");
const ing = @import("docs_ingest.zig");

const max_doc_bytes = 8 * 1024 * 1024;
const max_list_bytes = 64 * 1024 * 1024;

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("docs-ingest: " ++ fmt ++ "\n", args);
    return 2;
}

fn readList(a: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const bytes = try std.fs.cwd().readFileAlloc(a, path, max_list_bytes);
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |l| {
        const p = std.mem.trimRight(u8, l, "\r");
        if (p.len == 0) continue;
        if (!ing.safeRepoPath(p)) return error.InvalidInput;
        try out.append(a, p);
    }
    return out.items;
}

/// True when `real` names a path strictly inside the directory `root`.
/// Both are absolute, resolved paths. A root of "/" contains every path.
fn under(root: []const u8, real: []const u8) bool {
    if (std.mem.eql(u8, root, "/")) return real.len > 1 and real[0] == '/';
    return real.len > root.len and std.mem.startsWith(u8, real, root) and real[root.len] == '/';
}

/// Open `p` relative to `dir`, then check the file that was actually
/// opened: it must be a regular file whose resolved path lies under
/// `root_real`. Checking the open descriptor, not the name, closes the
/// window where a file or parent directory is swapped between the check
/// and the read. The open is non-blocking so a FIFO cannot hang it.
fn readBeneath(a: std.mem.Allocator, dir: std.fs.Dir, root_real: []const u8, p: []const u8) ![]u8 {
    const fd = try std.posix.openat(dir.fd, p, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
    const file: std.fs.File = .{ .handle = fd };
    defer file.close();
    const st = try std.posix.fstat(fd);
    if (!std.posix.S.ISREG(st.mode)) return error.NotRegularFile;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = try std.os.getFdPath(fd, &buf);
    if (!under(root_real, real)) return error.OutsideRoot;
    return file.readToEndAlloc(a, max_doc_bytes);
}

test "under handles a root of slash and sibling prefixes" {
    try std.testing.expect(under("/", "/a.md"));
    try std.testing.expect(!under("/", "/"));
    try std.testing.expect(under("/r", "/r/a.md"));
    try std.testing.expect(!under("/r", "/rx/a.md"));
    try std.testing.expect(!under("/r", "/r"));
}

pub fn main() u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    return run(a) catch |e| switch (e) {
        error.OutOfMemory => fail("out of memory", .{}),
        else => fail("{s}", .{@errorName(e)}),
    };
}

fn run(a: std.mem.Allocator) !u8 {
    const argv = try std.process.argsAlloc(a);
    var repo: ?[]const u8 = null;
    var rev: ?[]const u8 = null;
    var root: ?[]const u8 = null;
    var files_path: ?[]const u8 = null;
    var docs_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: docs-ingest --repo OWNER/NAME --rev SHA40 --root DIR --files LIST [--docs LIST]\n", .{});
            return 0;
        }
        if (i + 1 >= argv.len) return fail("missing value for {s}", .{arg});
        const val = argv[i + 1];
        i += 1;
        if (std.mem.eql(u8, arg, "--repo")) repo = val else if (std.mem.eql(u8, arg, "--rev")) rev = val else if (std.mem.eql(u8, arg, "--root")) root = val else if (std.mem.eql(u8, arg, "--files")) files_path = val else if (std.mem.eql(u8, arg, "--docs")) docs_path = val else return fail("unknown option {s}", .{arg});
    }
    if (repo == null or rev == null or root == null or files_path == null)
        return fail("--repo, --rev, --root and --files are required", .{});
    if (!ing.validRepo(repo.?)) return fail("--repo must be OWNER/NAME", .{});
    if (!ing.validRev(rev.?)) return fail("--rev must be a 40-character lowercase hex commit id", .{});

    const files = readList(a, files_path.?) catch |e| return fail("cannot read --files list: {s}", .{@errorName(e)});
    const wanted: []const []const u8 = if (docs_path) |p|
        readList(a, p) catch |e| return fail("cannot read --docs list: {s}", .{@errorName(e)})
    else
        files;

    var dir = std.fs.cwd().openDir(root.?, .{}) catch |e| return fail("cannot open --root: {s}", .{@errorName(e)});
    defer dir.close();
    const root_real = dir.realpathAlloc(a, ".") catch |e| return fail("cannot resolve --root: {s}", .{@errorName(e)});

    var j: ing.Json = .{ .a = a };
    try j.raw("{\"schema\":\"reconcile-input/v0\",\"repo\":");
    try j.str(repo.?);
    try j.raw(",\"rev\":");
    try j.str(rev.?);
    try j.raw(",\"files\":[");
    for (files, 0..) |f, k| {
        if (k > 0) try j.raw(",");
        try j.str(f);
    }
    try j.raw("],\"docs\":[");
    var n: usize = 0;
    for (wanted) |p| {
        const fmt = ing.formatOf(p) orelse continue;
        const bytes = readBeneath(a, dir, root_real, p) catch |e| switch (e) {
            error.OutsideRoot => return fail("{s} resolves outside --root", .{p}),
            error.NotRegularFile => return fail("{s} is not a regular file", .{p}),
            else => return fail("cannot read {s}: {s}", .{ p, @errorName(e) }),
        };
        const d = try ing.parse(a, p, bytes, fmt);
        if (n > 0) try j.raw(",");
        try j.doc(d, repo.?, rev.?);
        n += 1;
    }
    try j.raw("]}\n");
    // JSON must be UTF-8; a document or file name with invalid bytes fails.
    if (!std.unicode.utf8ValidateSlice(j.out.items)) return fail("input is not valid UTF-8", .{});
    try std.fs.File.stdout().writeAll(j.out.items);
    return 0;
}
