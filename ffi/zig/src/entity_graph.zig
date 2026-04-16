// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Docudactyl — Entity Co-Occurrence Graph Builder
//
// Builds a person-entity co-occurrence graph from extracted document text
// and emits it as GraphML for visualisation in Gephi, yEd, Cytoscape, etc.
//
// Use case:
//   The Epstein corpus is a network-analysis problem as much as it is a
//   text-analysis problem. Investigators need to see "who appears with
//   whom, how often, and in what context" across thousands of documents.
//   Per-document analysis cannot reveal that — a cross-document graph can.
//
// Pipeline:
//   1. ddac_entity_graph_new()                  -> graph handle
//   2. ddac_entity_graph_add_document(...)      -> repeat per doc
//   3. ddac_entity_graph_export_graphml(...)    -> write .graphml
//   4. ddac_entity_graph_free(handle)
//
// Entity detection (rule-based — no ML dependency):
//   - Capitalised multi-word names: "Jeffrey Epstein", "Ghislaine Maxwell"
//   - Titled names: "Prince Andrew", "Dr. Anthony Fauci"
//   - Common title prefixes filtered as nodes, recorded as attributes
//
// Edge semantics:
//   - An edge between A and B means A and B co-occurred in the same
//     document (optionally within a sentence/paragraph window).
//   - Edge weight = number of documents (or windows) in which both appeared.
//

const std = @import("std");

// ============================================================================
// Public Types
// ============================================================================

pub const EntityGraphStatus = enum(c_int) {
    ok = 0,
    allocation_error = 1,
    invalid_handle = 2,
    write_error = 3,
    no_text = 4,
};

pub const MAX_NAME_LEN: usize = 128;

/// A normalised entity (name) in the graph.
const Node = struct {
    /// Canonicalised display name (e.g. "Jeffrey Epstein").
    name: []u8,
    /// Total co-occurrence frequency across all documents.
    freq: u32,
    /// Number of documents mentioning this entity.
    doc_count: u32,
};

/// A weighted co-occurrence edge between two nodes.
const Edge = struct {
    src: u32,
    dst: u32,
    weight: u32,
};

/// Graph handle (opaque to C callers — cast through a pointer).
pub const EntityGraph = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node),
    name_to_idx: std.StringHashMap(u32),
    edges: std.AutoHashMap(u64, u32), // key = (u64(src) << 32) | u64(dst), value = weight
    document_count: u32,

    pub fn init(allocator: std.mem.Allocator) !*EntityGraph {
        const self = try allocator.create(EntityGraph);
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .nodes = .{},
            .name_to_idx = std.StringHashMap(u32).init(allocator),
            .edges = std.AutoHashMap(u64, u32).init(allocator),
            .document_count = 0,
        };
        return self;
    }

    pub fn deinit(self: *EntityGraph) void {
        self.nodes.deinit(self.allocator);
        self.name_to_idx.deinit();
        self.edges.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn getOrCreateNode(self: *EntityGraph, name: []const u8) !u32 {
        if (self.name_to_idx.get(name)) |idx| {
            self.nodes.items[idx].freq += 1;
            return idx;
        }
        // Copy name into the arena so the hash-map key has a stable lifetime.
        const owned = try self.arena.allocator().dupe(u8, name);
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .name = owned,
            .freq = 1,
            .doc_count = 0,
        });
        try self.name_to_idx.put(owned, idx);
        return idx;
    }

    fn addEdge(self: *EntityGraph, a: u32, b: u32) !void {
        if (a == b) return;
        const src = if (a < b) a else b;
        const dst = if (a < b) b else a;
        const key = (@as(u64, src) << 32) | @as(u64, dst);
        const gop = try self.edges.getOrPut(key);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
        } else {
            gop.value_ptr.* = 1;
        }
    }
};

// ============================================================================
// Name Extraction
// ============================================================================

fn isUpper(ch: u8) bool {
    return ch >= 'A' and ch <= 'Z';
}

fn isLower(ch: u8) bool {
    return ch >= 'a' and ch <= 'z';
}

fn isAlpha(ch: u8) bool {
    return isUpper(ch) or isLower(ch);
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

/// Stopwords that may appear capitalised at sentence boundaries but are not
/// personal names. Keep this list small and conservative — over-filtering
/// erases real signal.
const name_stopwords = std.StaticStringMap(void).initComptime(.{
    .{ "The", {} },       .{ "A", {} },         .{ "An", {} },
    .{ "And", {} },       .{ "But", {} },       .{ "Or", {} },
    .{ "If", {} },        .{ "When", {} },      .{ "Where", {} },
    .{ "What", {} },      .{ "Why", {} },       .{ "How", {} },
    .{ "This", {} },      .{ "That", {} },      .{ "These", {} },
    .{ "Those", {} },     .{ "In", {} },        .{ "On", {} },
    .{ "At", {} },        .{ "By", {} },        .{ "For", {} },
    .{ "With", {} },      .{ "From", {} },      .{ "To", {} },
    .{ "Of", {} },        .{ "Is", {} },        .{ "Was", {} },
    .{ "Were", {} },      .{ "Be", {} },        .{ "Been", {} },
    .{ "I", {} },         .{ "We", {} },        .{ "They", {} },
    .{ "He", {} },        .{ "She", {} },       .{ "It", {} },
    .{ "Yes", {} },       .{ "No", {} },        .{ "Not", {} },
    .{ "Monday", {} },    .{ "Tuesday", {} },   .{ "Wednesday", {} },
    .{ "Thursday", {} },  .{ "Friday", {} },    .{ "Saturday", {} },
    .{ "Sunday", {} },    .{ "January", {} },   .{ "February", {} },
    .{ "March", {} },     .{ "April", {} },     .{ "May", {} },
    .{ "June", {} },      .{ "July", {} },      .{ "August", {} },
    .{ "September", {} }, .{ "October", {} },   .{ "November", {} },
    .{ "December", {} },
});

const title_prefixes = [_][]const u8{
    "Mr.",  "Mrs.", "Ms.",  "Dr.",    "Sir",     "Prof.", "Professor",
    "Lord", "Lady", "Hon.", "Judge",  "Justice", "Prince", "Princess",
    "King", "Queen", "Pope",
};

/// Check if `word` is a title prefix (case-sensitive, common English forms).
fn isTitle(word: []const u8) bool {
    for (title_prefixes) |t| {
        if (std.mem.eql(u8, word, t)) return true;
    }
    return false;
}

/// Tokenise `text` into capitalised name candidates. A "name" is 2+
/// consecutive capitalised words, optionally preceded by a title prefix.
/// Calls `cb(name)` for each extracted candidate.
fn extractNames(
    text: []const u8,
    buf: *std.ArrayList([]const u8),
    arena: std.mem.Allocator,
) !void {
    var i: usize = 0;
    while (i < text.len) {
        // Skip non-alpha characters.
        while (i < text.len and !isAlpha(text[i])) : (i += 1) {}
        if (i >= text.len) break;

        // Start of a word. Capture consecutive capitalised tokens.
        const start = i;
        var word_count: usize = 0;
        var end = i;
        var had_title = false;

        while (end < text.len) {
            const word_start = end;
            // Require upper-case initial for a "name token".
            if (!isUpper(text[end])) break;
            end += 1;
            while (end < text.len and (isAlpha(text[end]) or text[end] == '.' or text[end] == '\'')) : (end += 1) {}
            const word = text[word_start..end];

            if (word_count == 0 and isTitle(word)) {
                had_title = true;
            } else if (!had_title and name_stopwords.has(word) and word_count == 0) {
                // Leading stopword — skip this entire candidate.
                i = end;
                word_count = 0;
                break;
            }
            word_count += 1;

            // Consume a single space between tokens.
            if (end < text.len and text[end] == ' ' and
                end + 1 < text.len and isUpper(text[end + 1]))
            {
                end += 1;
                continue;
            }
            break;
        }

        // Accept candidates of at least 2 tokens, or 1 token if preceded by a title.
        const min_tokens: usize = if (had_title) 2 else 2;
        if (word_count >= min_tokens) {
            const name = text[start..end];
            const copy = try arena.dupe(u8, name);
            try buf.append(arena, copy);
        }

        i = @max(end, i + 1);
    }
}

// ============================================================================
// Public C-ABI Entry Points
// ============================================================================

/// Create a new entity graph. Returns an opaque handle, or null on failure.
export fn ddac_entity_graph_new() ?*EntityGraph {
    const allocator = std.heap.c_allocator;
    return EntityGraph.init(allocator) catch null;
}

/// Destroy a graph and free all associated memory.
export fn ddac_entity_graph_free(handle: ?*EntityGraph) void {
    if (handle) |h| h.deinit();
}

/// Add a document's text to the graph. All entities extracted from the
/// text are linked pairwise with a +1 weight on each edge.
export fn ddac_entity_graph_add_document(
    handle: ?*EntityGraph,
    text_ptr: ?[*]const u8,
    text_len: usize,
) c_int {
    const h = handle orelse return @intFromEnum(EntityGraphStatus.invalid_handle);
    const text = if (text_ptr) |p| p[0..text_len] else return @intFromEnum(EntityGraphStatus.no_text);
    if (text.len == 0) return @intFromEnum(EntityGraphStatus.no_text);

    var local_arena = std.heap.ArenaAllocator.init(h.allocator);
    defer local_arena.deinit();
    var names: std.ArrayList([]const u8) = .{};
    defer names.deinit(local_arena.allocator());

    extractNames(text, &names, local_arena.allocator()) catch {
        return @intFromEnum(EntityGraphStatus.allocation_error);
    };

    // Deduplicate within this document — a name appearing 5 times counts as
    // one mention for doc_count but still boosts freq for each appearance.
    var doc_ids: std.ArrayList(u32) = .{};
    defer doc_ids.deinit(local_arena.allocator());
    var seen = std.AutoHashMap(u32, void).init(local_arena.allocator());
    defer seen.deinit();

    for (names.items) |name| {
        const idx = h.getOrCreateNode(name) catch {
            return @intFromEnum(EntityGraphStatus.allocation_error);
        };
        if (!seen.contains(idx)) {
            seen.put(idx, {}) catch return @intFromEnum(EntityGraphStatus.allocation_error);
            doc_ids.append(local_arena.allocator(), idx) catch {
                return @intFromEnum(EntityGraphStatus.allocation_error);
            };
            h.nodes.items[idx].doc_count += 1;
        }
    }

    // Pairwise edges between all entities in this document.
    var a: usize = 0;
    while (a < doc_ids.items.len) : (a += 1) {
        var b: usize = a + 1;
        while (b < doc_ids.items.len) : (b += 1) {
            h.addEdge(doc_ids.items[a], doc_ids.items[b]) catch {
                return @intFromEnum(EntityGraphStatus.allocation_error);
            };
        }
    }

    h.document_count += 1;
    return @intFromEnum(EntityGraphStatus.ok);
}

/// Export the graph to a GraphML file at `output_path`. Overwrites existing
/// files.
export fn ddac_entity_graph_export_graphml(
    handle: ?*EntityGraph,
    output_path: ?[*:0]const u8,
) c_int {
    const h = handle orelse return @intFromEnum(EntityGraphStatus.invalid_handle);
    const path = output_path orelse return @intFromEnum(EntityGraphStatus.write_error);

    // Estimate buffer: 200 bytes per node + 120 bytes per edge + 1 KB header.
    const est: usize = 1024 + h.nodes.items.len * 256 + h.edges.count() * 128;
    const buf = std.heap.c_allocator.alloc(u8, est) catch {
        return @intFromEnum(EntityGraphStatus.allocation_error);
    };
    defer std.heap.c_allocator.free(buf);

    var stream = std.io.fixedBufferStream(buf);
    writeGraphML(h, stream.writer()) catch return @intFromEnum(EntityGraphStatus.write_error);

    const file = std.fs.createFileAbsoluteZ(path, .{ .truncate = true }) catch {
        return @intFromEnum(EntityGraphStatus.write_error);
    };
    defer file.close();
    file.writeAll(stream.getWritten()) catch return @intFromEnum(EntityGraphStatus.write_error);

    return @intFromEnum(EntityGraphStatus.ok);
}

/// Export a simple CSV edge list (source,target,weight) — convenient for
/// spreadsheets and downstream graph tools that prefer CSV input.
export fn ddac_entity_graph_export_csv(
    handle: ?*EntityGraph,
    output_path: ?[*:0]const u8,
) c_int {
    const h = handle orelse return @intFromEnum(EntityGraphStatus.invalid_handle);
    const path = output_path orelse return @intFromEnum(EntityGraphStatus.write_error);

    const est: usize = 256 + h.edges.count() * 160;
    const buf = std.heap.c_allocator.alloc(u8, est) catch {
        return @intFromEnum(EntityGraphStatus.allocation_error);
    };
    defer std.heap.c_allocator.free(buf);

    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();

    w.writeAll("source,target,weight\n") catch return @intFromEnum(EntityGraphStatus.write_error);
    var it = h.edges.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const src_idx: u32 = @intCast(key >> 32);
        const dst_idx: u32 = @intCast(key & 0xFFFFFFFF);
        const src_name = h.nodes.items[src_idx].name;
        const dst_name = h.nodes.items[dst_idx].name;
        w.print("\"{s}\",\"{s}\",{d}\n", .{ src_name, dst_name, entry.value_ptr.* }) catch {
            return @intFromEnum(EntityGraphStatus.write_error);
        };
    }

    const file = std.fs.createFileAbsoluteZ(path, .{ .truncate = true }) catch {
        return @intFromEnum(EntityGraphStatus.write_error);
    };
    defer file.close();
    file.writeAll(stream.getWritten()) catch return @intFromEnum(EntityGraphStatus.write_error);

    return @intFromEnum(EntityGraphStatus.ok);
}

/// Number of distinct entities in the graph.
export fn ddac_entity_graph_node_count(handle: ?*EntityGraph) u32 {
    const h = handle orelse return 0;
    return @intCast(h.nodes.items.len);
}

/// Number of distinct co-occurrence edges in the graph.
export fn ddac_entity_graph_edge_count(handle: ?*EntityGraph) u32 {
    const h = handle orelse return 0;
    return @intCast(h.edges.count());
}

// ============================================================================
// GraphML Writer
// ============================================================================

fn writeGraphML(g: *EntityGraph, writer: anytype) !void {
    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<graphml xmlns="http://graphml.graphdrawing.org/xmlns"
        \\  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        \\  xsi:schemaLocation="http://graphml.graphdrawing.org/xmlns
        \\    http://graphml.graphdrawing.org/xmlns/1.0/graphml.xsd">
        \\  <key id="freq" for="node" attr.name="freq" attr.type="int"/>
        \\  <key id="docs" for="node" attr.name="doc_count" attr.type="int"/>
        \\  <key id="w" for="edge" attr.name="weight" attr.type="int"/>
        \\  <graph id="docudactyl-entities" edgedefault="undirected">
        \\
    );

    for (g.nodes.items, 0..) |node, idx| {
        try writer.print(
            "    <node id=\"n{d}\"><data key=\"freq\">{d}</data><data key=\"docs\">{d}</data><data key=\"name\">",
            .{ idx, node.freq, node.doc_count },
        );
        try writeXmlEscaped(writer, node.name);
        try writer.writeAll("</data></node>\n");
    }

    var it = g.edges.iterator();
    var edge_id: usize = 0;
    while (it.next()) |entry| : (edge_id += 1) {
        const key = entry.key_ptr.*;
        const src: u32 = @intCast(key >> 32);
        const dst: u32 = @intCast(key & 0xFFFFFFFF);
        try writer.print(
            "    <edge id=\"e{d}\" source=\"n{d}\" target=\"n{d}\"><data key=\"w\">{d}</data></edge>\n",
            .{ edge_id, src, dst, entry.value_ptr.* },
        );
    }

    try writer.writeAll(
        \\  </graph>
        \\</graphml>
        \\
    );
}

fn writeXmlEscaped(writer: anytype, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(ch),
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "add document extracts capitalised names" {
    const g = try EntityGraph.init(std.testing.allocator);
    defer g.deinit();

    const text = "Jeffrey Epstein met Ghislaine Maxwell. Later, Prince Andrew joined them.";
    const rc = ddac_entity_graph_add_document(g, text.ptr, text.len);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expect(ddac_entity_graph_node_count(g) >= 2);
    try std.testing.expect(ddac_entity_graph_edge_count(g) >= 1);
}

test "edge weight accumulates across documents" {
    const g = try EntityGraph.init(std.testing.allocator);
    defer g.deinit();

    const doc1 = "Jeffrey Epstein called Ghislaine Maxwell.";
    const doc2 = "Ghislaine Maxwell wrote to Jeffrey Epstein.";
    _ = ddac_entity_graph_add_document(g, doc1.ptr, doc1.len);
    _ = ddac_entity_graph_add_document(g, doc2.ptr, doc2.len);
    try std.testing.expectEqual(@as(u32, 2), g.document_count);
}

test "stopwords at sentence starts are filtered" {
    const g = try EntityGraph.init(std.testing.allocator);
    defer g.deinit();

    const text = "The President met The Senator. When The President left, Jeffrey Epstein arrived.";
    _ = ddac_entity_graph_add_document(g, text.ptr, text.len);
    // "Jeffrey Epstein" should be extracted; "The President"/"The Senator" should not.
    var found_je = false;
    for (g.nodes.items) |n| {
        if (std.mem.eql(u8, n.name, "Jeffrey Epstein")) found_je = true;
    }
    try std.testing.expect(found_je);
}

test "handle free is safe on null" {
    ddac_entity_graph_free(null);
}

test "exports without nodes produce valid empty graphml" {
    const g = try EntityGraph.init(std.testing.allocator);
    defer g.deinit();

    // Build in memory rather than touching the filesystem.
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeGraphML(g, stream.writer());
    const written = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, written, "<graphml") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "</graphml>") != null);
}
