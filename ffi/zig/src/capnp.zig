// Docudactyl — Minimal Cap'n Proto Single-Segment Message Builder
//
// Produces valid Cap'n Proto binary messages readable by any standard decoder.
// Single-segment only (sufficient for per-document stage results).
// No external dependencies — pure Zig implementation of the wire format.
//
// Wire format reference: https://capnproto.org/encoding.html
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

const std = @import("std");

// ============================================================================
// StageResults Layout Constants
// ============================================================================
//
// These match schema/stages.capnp field ordinals processed through Cap'n Proto's
// slot assignment algorithm. Data fields are assigned slots of their natural size;
// pointer fields get sequential pointer slots.
//
// Root struct: 23 data words (184 bytes) + 30 pointer words (240 bytes)

pub const DATA_WORDS: u16 = 23;
pub const PTR_WORDS: u16 = 30;

// ── Data section byte offsets (from start of data section) ────────────────

// 64-bit fields (8 bytes each, sequential)
pub const OFF_STAGES_MASK: usize = 0; // @0 UInt64
pub const OFF_LANG_CONFIDENCE: usize = 8; // @3 Float64
pub const OFF_READ_GRADE: usize = 16; // @4 Float64
pub const OFF_READ_EASE: usize = 24; // @5 Float64
pub const OFF_READ_SENTENCES: usize = 32; // @6 UInt64
pub const OFF_READ_WORDS: usize = 40; // @7 UInt64
pub const OFF_READ_SYLLABLES: usize = 48; // @8 UInt64

// 32-bit fields (4 bytes each, packed two per word after 64-bit region)
pub const OFF_KW_COUNT: usize = 56; // @9 UInt32
pub const OFF_KW_UNIQUE: usize = 60; // @10 UInt32
pub const OFF_CIT_TOTAL: usize = 64; // @12 UInt32
pub const OFF_CIT_DOI: usize = 68; // @13 UInt32
pub const OFF_CIT_ISBN: usize = 72; // @14 UInt32
pub const OFF_CIT_URL: usize = 76; // @15 UInt32
pub const OFF_CIT_YEAR: usize = 80; // @16 UInt32
pub const OFF_CIT_NUMREF: usize = 84; // @17 UInt32
pub const OFF_OCR_CONF: usize = 88; // @18 Int32
pub const OFF_MLANG_CONF: usize = 92; // @22 Int32

// More 64-bit fields (after 32-bit region)
pub const OFF_MLANG_WORDS: usize = 96; // @23 UInt64
pub const OFF_MLANG_CHARS: usize = 104; // @24 UInt64

// Mixed 32-bit fields
pub const OFF_SUB_COUNT: usize = 112; // @26 UInt32
pub const OFF_MERKLE_DEPTH: usize = 116; // @34 UInt32

// 64-bit field
pub const OFF_PREMIS_SIZE: usize = 120; // @29 Int64

// 32-bit field
pub const OFF_MERKLE_LEAVES: usize = 128; // @35 UInt32
// gap at 132-135 (padding)

// 64-bit coordinate fields
pub const OFF_COORD_MINX: usize = 136; // @41 Float64
pub const OFF_COORD_MINY: usize = 144; // @42 Float64
pub const OFF_COORD_MAXX: usize = 152; // @43 Float64
pub const OFF_COORD_MAXY: usize = 160; // @44 Float64
pub const OFF_COORD_RASTX: usize = 168; // @45 Float64
pub const OFF_COORD_RASTY: usize = 176; // @46 Float64

// ── Pointer section indices ───────────────────────────────────────────────

pub const PTR_LANG_SCRIPT: usize = 0; // @1
pub const PTR_LANG_LANGUAGE: usize = 1; // @2
pub const PTR_KW_WORDS: usize = 2; // @11 List(Text)
pub const PTR_PHASH_AHASH: usize = 3; // @19
pub const PTR_TOC_ENTRIES: usize = 4; // @20 List(TocEntry)
pub const PTR_MLANG_LANGS: usize = 5; // @21
pub const PTR_SUB_STREAMS: usize = 6; // @25 List(SubtitleStream)
pub const PTR_PREMIS_CAT: usize = 7; // @27
pub const PTR_PREMIS_FMT: usize = 8; // @28
pub const PTR_PREMIS_FIXALG: usize = 9; // @30
pub const PTR_PREMIS_FIXVAL: usize = 10; // @31
pub const PTR_PREMIS_FMTREG: usize = 11; // @32
pub const PTR_MERKLE_ROOT: usize = 12; // @33
pub const PTR_EXACT_SHA: usize = 13; // @36
pub const PTR_NEAR_AHASH: usize = 14; // @37
pub const PTR_NEAR_STATUS: usize = 15; // @38
pub const PTR_NEAR_REASON: usize = 16; // @39
pub const PTR_COORD_CRS: usize = 17; // @40
pub const PTR_NER_STATUS: usize = 18; // @47
pub const PTR_NER_REASON: usize = 19; // @48
pub const PTR_WHISPER_STATUS: usize = 20; // @49
pub const PTR_WHISPER_REASON: usize = 21; // @50
pub const PTR_IMGCLASS_STATUS: usize = 22; // @51
pub const PTR_IMGCLASS_REASON: usize = 23; // @52
pub const PTR_LAYOUT_STATUS: usize = 24; // @53
pub const PTR_LAYOUT_REASON: usize = 25; // @54
pub const PTR_HWOCR_STATUS: usize = 26; // @55
pub const PTR_HWOCR_REASON: usize = 27; // @56
pub const PTR_FMTCONV_STATUS: usize = 28; // @57
pub const PTR_FMTCONV_REASON: usize = 29; // @58

// ── TocEntry layout (1 data word, 1 pointer) ─────────────────────────────
pub const TOC_DW: u16 = 1;
pub const TOC_PW: u16 = 1;
pub const TOC_OFF_DEPTH: usize = 0; // UInt32

// ── SubtitleStream layout (1 data word, 2 pointers) ──────────────────────
pub const SUB_DW: u16 = 1;
pub const SUB_PW: u16 = 2;
pub const SUB_OFF_INDEX: usize = 0; // UInt32

// ============================================================================
// Cap'n Proto Wire Format Constants
// ============================================================================

const LIST_BYTE: u3 = 2;
const LIST_POINTER: u3 = 6;
const LIST_COMPOSITE: u3 = 7;

// ============================================================================
// Single-Segment Message Builder
// ============================================================================

/// Builds a Cap'n Proto single-segment message in a caller-provided buffer.
///
/// Usage:
///   var buf: [65536]u8 align(8) = undefined;
///   var b = Builder.init(&buf);
///   b.initRoot();
///   b.setU64(OFF_STAGES_MASK, mask);
///   b.setText(PTR_LANG_SCRIPT, "Latin");
///   try b.writeMessage(file);
pub const Builder = struct {
    buf: [*]u8,
    cap: usize,
    pos: usize, // next free byte (always 8-byte aligned)
    data_start: usize, // byte offset of root struct data section
    ptr_start: usize, // byte offset of root struct pointer section

    /// Initialise a builder with a zeroed buffer.
    pub fn init(buffer: []align(8) u8) Builder {
        @memset(buffer, 0);
        return .{
            .buf = buffer.ptr,
            .cap = buffer.len,
            .pos = 0,
            .data_start = 0,
            .ptr_start = 0,
        };
    }

    /// Set up the root struct. Must be called before setting any fields.
    /// Allocates: 1 root pointer word + DATA_WORDS + PTR_WORDS.
    pub fn initRoot(self: *Builder) void {
        self.pos = 8; // skip root pointer at word 0
        self.data_start = 8;
        self.pos += @as(usize, DATA_WORDS) * 8;
        self.ptr_start = self.pos;
        self.pos += @as(usize, PTR_WORDS) * 8;

        // Root struct pointer: type=struct(0), offset=0, dw=DATA_WORDS, pw=PTR_WORDS
        // Offset 0 means struct data immediately follows the pointer word.
        const val: u64 = (@as(u64, DATA_WORDS) << 32) | (@as(u64, PTR_WORDS) << 48);
        self.wr64(0, val);
    }

    // ── Data section setters ──────────────────────────────────────────

    pub fn setU64(self: *Builder, off: usize, val: u64) void {
        self.wr64(self.data_start + off, val);
    }

    pub fn setU32(self: *Builder, off: usize, val: u32) void {
        self.wr32(self.data_start + off, val);
    }

    pub fn setI32(self: *Builder, off: usize, val: i32) void {
        self.wr32(self.data_start + off, @bitCast(val));
    }

    pub fn setI64(self: *Builder, off: usize, val: i64) void {
        self.wr64(self.data_start + off, @bitCast(val));
    }

    pub fn setF64(self: *Builder, off: usize, val: f64) void {
        self.wr64(self.data_start + off, @bitCast(val));
    }

    // ── Text field (allocate + link pointer) ──────────────────────────

    /// Allocate a text string and write the list pointer at the given
    /// root pointer slot. Cap'n Proto Text = List(UInt8) with null terminator.
    pub fn setText(self: *Builder, ptr_idx: usize, text: []const u8) void {
        if (text.len == 0) return;
        const ptr_off = self.ptr_start + ptr_idx * 8;
        self.allocAndLinkText(ptr_off, text);
    }

    // ── List(Text) (list of pointers to text) ─────────────────────────

    /// Allocate a list of text strings and write the list pointer at the
    /// given root pointer slot.
    pub fn setTextList(self: *Builder, ptr_idx: usize, texts: []const []const u8) void {
        if (texts.len == 0) return;

        // Allocate N pointer words for the list body
        const list_off = self.allocWords(texts.len) orelse return;

        // Write list pointer: type=list, element_size=pointer
        const ptr_off = self.ptr_start + ptr_idx * 8;
        self.writeListPtr(ptr_off, list_off, LIST_POINTER, @intCast(texts.len));

        // Each list element is a pointer to a text allocation
        for (texts, 0..) |text, i| {
            if (text.len == 0) continue;
            const elem_ptr_off = list_off + i * 8;
            self.allocAndLinkText(elem_ptr_off, text);
        }
    }

    // ── Composite List (list of structs) ──────────────────────────────

    /// Allocate a composite list at the given root pointer slot.
    /// Returns a CompositeList handle for setting per-element fields,
    /// or null if allocation fails or count is zero.
    pub fn allocCompositeList(
        self: *Builder,
        ptr_idx: usize,
        count: usize,
        dw: u16,
        pw: u16,
    ) ?CompositeList {
        if (count == 0) return null;

        const elem_words = @as(usize, dw) + @as(usize, pw);
        const total_words = 1 + count * elem_words; // 1 tag word + elements
        const list_off = self.allocWords(total_words) orelse return null;

        // Tag word: struct pointer with offset = element count
        const tag: u64 = (@as(u64, @intCast(count)) << 2) |
            (@as(u64, dw) << 32) |
            (@as(u64, pw) << 48);
        self.wr64(list_off, tag);

        // List pointer at parent: type=list, element_size=composite, count=total_element_words
        const ptr_off = self.ptr_start + ptr_idx * 8;
        const word_count: u29 = @intCast(count * elem_words);
        self.writeListPtr(ptr_off, list_off, LIST_COMPOSITE, word_count);

        return .{
            .builder = self,
            .start = list_off + 8, // elements begin after tag word
            .dw = dw,
            .pw = pw,
            .stride = elem_words * 8,
            .count = count,
        };
    }

    // ── Message serialisation ─────────────────────────────────────────

    /// Write the complete Cap'n Proto message (header + segment) to a file.
    pub fn writeMessage(self: *Builder, file: std.fs.File) !void {
        const segment_words: u32 = @intCast(self.pos / 8);

        // Message header: segment_count-1 (0 = one segment), segment_size_in_words
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], 0, .little);
        std.mem.writeInt(u32, header[4..8], segment_words, .little);

        try file.writeAll(&header);
        try file.writeAll(self.buf[0..self.pos]);
    }

    // ── Internal helpers ──────────────────────────────────────────────

    fn allocWords(self: *Builder, n: usize) ?usize {
        const bytes = n * 8;
        if (self.pos + bytes > self.cap) return null;
        const off = self.pos;
        self.pos += bytes;
        return off;
    }

    fn wr64(self: *Builder, off: usize, val: u64) void {
        if (off + 8 > self.cap) return;
        @as(*align(1) u64, @ptrCast(self.buf + off)).* = std.mem.nativeToLittle(u64, val);
    }

    fn wr32(self: *Builder, off: usize, val: u32) void {
        if (off + 4 > self.cap) return;
        @as(*align(1) u32, @ptrCast(self.buf + off)).* = std.mem.nativeToLittle(u32, val);
    }

    /// Allocate text in the segment and write a text pointer at ptr_off.
    fn allocAndLinkText(self: *Builder, ptr_off: usize, text: []const u8) void {
        // Cap'n Proto Text = List(UInt8) with null terminator included in count
        const len_with_null = text.len + 1;
        const words = (len_with_null + 7) / 8;
        const text_off = self.allocWords(words) orelse return;

        // Copy text bytes (null terminator already 0 from zeroed buffer)
        for (text, 0..) |byte, i| {
            self.buf[text_off + i] = byte;
        }

        // Write list pointer: type=list(1), element_size=byte(2), count=len_with_null
        self.writeListPtr(ptr_off, text_off, LIST_BYTE, @intCast(len_with_null));
    }

    /// Encode and write a Cap'n Proto list pointer.
    ///
    /// Layout (64 bits, little-endian):
    ///   bits 0-1:   1 (list type)
    ///   bits 2-31:  signed offset in words (from pointer+1 to list data)
    ///   bits 32-34: element size enum
    ///   bits 35-63: element count (or word count for composite)
    fn writeListPtr(self: *Builder, ptr_off: usize, target_off: usize, elem_size: u3, count: u29) void {
        const ptr_word = ptr_off / 8;
        const target_word = target_off / 8;
        const offset: i32 = @intCast(@as(i64, @intCast(target_word)) - @as(i64, @intCast(ptr_word)) - 1);

        // Lower 32 bits: (offset << 2) | type_bit
        const lower: u32 = @as(u32, @bitCast(offset *% 4)) | 1;
        // Upper 32 bits: elem_size | (count << 3)
        const upper: u32 = @as(u32, elem_size) | (@as(u32, count) << 3);

        self.wr64(ptr_off, @as(u64, lower) | (@as(u64, upper) << 32));
    }
};

// ============================================================================
// Composite List Element Access
// ============================================================================

/// Handle for accessing elements of a composite list (list of structs).
pub const CompositeList = struct {
    builder: *Builder,
    start: usize, // byte offset of first element in segment
    dw: u16, // data words per element
    pw: u16, // pointer words per element
    stride: usize, // bytes per element (dw+pw)*8
    count: usize,

    /// Byte offset of element i's data section.
    fn elemData(self: CompositeList, i: usize) usize {
        return self.start + i * self.stride;
    }

    /// Byte offset of element i's pointer section.
    fn elemPtrs(self: CompositeList, i: usize) usize {
        return self.start + i * self.stride + @as(usize, self.dw) * 8;
    }

    /// Set a UInt32 field on element i at the given byte offset within the data section.
    pub fn setElemU32(self: CompositeList, i: usize, byte_off: usize, val: u32) void {
        self.builder.wr32(self.elemData(i) + byte_off, val);
    }

    /// Set a Text pointer field on element i at the given pointer index.
    pub fn setElemText(self: CompositeList, i: usize, ptr_idx: usize, text: []const u8) void {
        if (text.len == 0) return;
        const ptr_off = self.elemPtrs(i) + ptr_idx * 8;
        self.builder.allocAndLinkText(ptr_off, text);
    }
};
