// Docudactyl Cache — LMDB-Backed Result Cache
//
// Stores parsed document results keyed by file path. On cache hit
// (file mtime + size match), returns the cached ParseResult without
// re-parsing — skipping Tesseract/Poppler/FFmpeg calls entirely.
//
// LMDB properties that make this ideal for HPC:
//   - Zero-copy reads (memory-mapped, no malloc/memcpy)
//   - Multi-reader / single-writer (scales with Chapel forall)
//   - ACID transactions (crash-safe, no corruption on kill -9)
//   - B+ tree: O(log n) lookups even at 170M entries
//
// Cache layout per entry:
//   Key:   document path (variable-length string)
//   Value: [mtime: i64][file_size: i64][result_bytes: 952]
//          Total: 968 bytes per entry (fixed for ddac_parse_result_t)
//
// Each Chapel locale should have its own LMDB environment to avoid
// cross-locale write locking. Reads are fully concurrent.
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

const std = @import("std");

const lmdb = @cImport({
    @cInclude("lmdb.h");
});

// ============================================================================
// Constants
// ============================================================================

/// Size of the metadata prefix in each cache value (mtime + file_size).
const META_SIZE: usize = 16; // 8 + 8

/// Default maximum database size (10 GB — enough for ~10M entries).
const DEFAULT_MAX_SIZE_MB: u64 = 10240;

/// Maximum number of readers (one per Chapel task per locale).
const MAX_READERS: c_uint = 256;

// ============================================================================
// Cache Handle
// ============================================================================

const CacheState = struct {
    env: *lmdb.MDB_env,
    dbi: lmdb.MDB_dbi,
    allocator: std.mem.Allocator,
};

// ============================================================================
// Exported C API — Called from Chapel
// ============================================================================

/// Initialise LMDB cache at the given directory path.
/// The directory must exist. LMDB creates data.mdb and lock.mdb inside it.
/// Returns an opaque handle, or null on failure.
///
/// max_size_mb: maximum database size in MB (0 = use default 10GB).
export fn ddac_cache_init(
    dir_path: ?[*:0]const u8,
    max_size_mb: u64,
) ?*anyopaque {
    const path = dir_path orelse return null;
    const allocator = std.heap.c_allocator;

    var env: ?*lmdb.MDB_env = null;
    if (lmdb.mdb_env_create(&env) != 0) return null;
    const e = env.?;

    // Set map size
    const size_mb = if (max_size_mb == 0) DEFAULT_MAX_SIZE_MB else max_size_mb;
    _ = lmdb.mdb_env_set_mapsize(e, size_mb * 1024 * 1024);

    // Allow multiple concurrent readers
    _ = lmdb.mdb_env_set_maxreaders(e, MAX_READERS);

    // Open environment (directory mode)
    if (lmdb.mdb_env_open(e, path, 0, 0o644) != 0) {
        lmdb.mdb_env_close(e);
        return null;
    }

    // Open the default (unnamed) database
    var txn: ?*lmdb.MDB_txn = null;
    if (lmdb.mdb_txn_begin(e, null, 0, &txn) != 0) {
        lmdb.mdb_env_close(e);
        return null;
    }

    var dbi: lmdb.MDB_dbi = 0;
    if (lmdb.mdb_dbi_open(txn, null, 0, &dbi) != 0) {
        lmdb.mdb_txn_abort(txn);
        lmdb.mdb_env_close(e);
        return null;
    }
    if (lmdb.mdb_txn_commit(txn) != 0) {
        lmdb.mdb_env_close(e);
        return null;
    }

    const state = allocator.create(CacheState) catch {
        lmdb.mdb_env_close(e);
        return null;
    };
    state.* = .{
        .env = e,
        .dbi = dbi,
        .allocator = allocator,
    };

    return @ptrCast(state);
}

/// Free the LMDB cache. Safe to call with null.
export fn ddac_cache_free(handle: ?*anyopaque) void {
    const ptr = handle orelse return;
    const state: *CacheState = @ptrCast(@alignCast(ptr));

    lmdb.mdb_env_close(state.env);
    state.allocator.destroy(state);
}

/// Look up a cached result by document path.
/// If the cache has a matching entry (same mtime and file_size), copies
/// the cached ParseResult into result_out and returns 1 (hit).
/// Returns 0 on cache miss or error.
///
/// result_out: pointer to a 952-byte ParseResult struct.
/// result_size: must be 952 (sizeof ddac_parse_result_t).
export fn ddac_cache_lookup(
    handle: ?*anyopaque,
    doc_path: ?[*:0]const u8,
    mtime: i64,
    file_size: i64,
    result_out: ?[*]u8,
    result_size: usize,
) c_int {
    const ptr = handle orelse return 0;
    const state: *CacheState = @ptrCast(@alignCast(ptr));
    const path = doc_path orelse return 0;
    const out = result_out orelse return 0;

    // Begin read-only transaction (zero-copy, fully concurrent)
    var txn: ?*lmdb.MDB_txn = null;
    if (lmdb.mdb_txn_begin(state.env, null, lmdb.MDB_RDONLY, &txn) != 0) return 0;
    defer lmdb.mdb_txn_abort(txn);

    // Look up by path
    const path_slice = std.mem.span(path);
    var key = lmdb.MDB_val{ .mv_size = path_slice.len, .mv_data = @constCast(@ptrCast(path_slice.ptr)) };
    var data: lmdb.MDB_val = undefined;

    if (lmdb.mdb_get(txn, state.dbi, &key, &data) != 0) return 0;

    // Validate value size
    const expected_size = META_SIZE + result_size;
    if (data.mv_size < expected_size) return 0;

    // Check mtime and file_size
    const value_bytes: [*]const u8 = @ptrCast(data.mv_data);
    const cached_mtime = std.mem.readInt(i64, value_bytes[0..8], .little);
    const cached_size = std.mem.readInt(i64, value_bytes[8..16], .little);

    if (cached_mtime != mtime or cached_size != file_size) return 0;

    // Cache hit — copy result
    const copy_len = @min(result_size, data.mv_size - META_SIZE);
    @memcpy(out[0..copy_len], value_bytes[META_SIZE .. META_SIZE + copy_len]);

    return 1; // hit
}

/// Store a parse result in the cache, keyed by document path.
/// Overwrites any existing entry for the same path.
///
/// result: pointer to a 952-byte ParseResult struct.
/// result_size: must be 952 (sizeof ddac_parse_result_t).
export fn ddac_cache_store(
    handle: ?*anyopaque,
    doc_path: ?[*:0]const u8,
    mtime: i64,
    file_size: i64,
    result: ?[*]const u8,
    result_size: usize,
) void {
    const ptr = handle orelse return;
    const state: *CacheState = @ptrCast(@alignCast(ptr));
    const path = doc_path orelse return;
    const result_bytes = result orelse return;

    // Build value: [mtime][file_size][result_bytes]
    const value_size = META_SIZE + result_size;
    var value_buf: [META_SIZE + 1024]u8 = undefined; // 952 + 16 + slack
    if (value_size > value_buf.len) return;

    std.mem.writeInt(i64, value_buf[0..8], mtime, .little);
    std.mem.writeInt(i64, value_buf[8..16], file_size, .little);
    @memcpy(value_buf[META_SIZE .. META_SIZE + result_size], result_bytes[0..result_size]);

    // Begin write transaction
    var txn: ?*lmdb.MDB_txn = null;
    if (lmdb.mdb_txn_begin(state.env, null, 0, &txn) != 0) return;

    const path_slice = std.mem.span(path);
    var key = lmdb.MDB_val{ .mv_size = path_slice.len, .mv_data = @constCast(@ptrCast(path_slice.ptr)) };
    var data = lmdb.MDB_val{ .mv_size = value_size, .mv_data = @ptrCast(&value_buf) };

    if (lmdb.mdb_put(txn, state.dbi, &key, &data, 0) != 0) {
        lmdb.mdb_txn_abort(txn);
        return;
    }

    _ = lmdb.mdb_txn_commit(txn);
}

/// Return the number of entries in the cache.
export fn ddac_cache_count(handle: ?*anyopaque) u64 {
    const ptr = handle orelse return 0;
    const state: *CacheState = @ptrCast(@alignCast(ptr));

    var txn: ?*lmdb.MDB_txn = null;
    if (lmdb.mdb_txn_begin(state.env, null, lmdb.MDB_RDONLY, &txn) != 0) return 0;
    defer lmdb.mdb_txn_abort(txn);

    var stat: lmdb.MDB_stat = undefined;
    if (lmdb.mdb_stat(txn, state.dbi, &stat) != 0) return 0;

    return @intCast(stat.ms_entries);
}

/// Sync the database to disk (force fsync).
/// Call this periodically for durability or before graceful shutdown.
export fn ddac_cache_sync(handle: ?*anyopaque) void {
    const ptr = handle orelse return;
    const state: *CacheState = @ptrCast(@alignCast(ptr));
    _ = lmdb.mdb_env_sync(state.env, 1);
}
