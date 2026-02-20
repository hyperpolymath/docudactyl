// Docudactyl — Dragonfly / Redis RESP Client (L2 Cache)
//
// Minimal RESP2 client for Dragonfly (Redis-compatible) cross-locale cache.
// Supports GET, SET (with TTL), and DEL operations on binary keys and values.
//
// Cache key format:  "ddac:{sha256_hex}" (65 bytes)
// Cache value format: raw bytes of ddac_parse_result_t (952 bytes)
//
// Dragonfly advantages over Redis:
//   - 25x throughput on same hardware
//   - Multi-threaded (no single-thread bottleneck)
//   - Compatible with RESP2 protocol
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

const std = @import("std");

// ============================================================================
// RESP2 Wire Protocol
// ============================================================================

const RESP_SIMPLE_STRING: u8 = '+';
const RESP_ERROR: u8 = '-';
const RESP_INTEGER: u8 = ':';
const RESP_BULK_STRING: u8 = '$';
const RESP_ARRAY: u8 = '*';
const RESP_NULL_BULK = "$-1\r\n";

// ============================================================================
// Dragonfly Client
// ============================================================================

pub const DragonflyClient = struct {
    stream: std.net.Stream,
    recv_buf: [4096]u8,

    /// Connect to a Dragonfly/Redis server.
    /// Returns null if connection fails.
    pub fn connect(host: []const u8, port: u16) ?DragonflyClient {
        const addr = std.net.Address.parseIp4(host, port) catch return null;
        const stream = std.net.tcpConnectToAddress(addr) catch return null;

        // Set a reasonable timeout (5 seconds)
        stream.handle.setReadTimeout(5_000_000_000) catch {};
        stream.handle.setWriteTimeout(5_000_000_000) catch {};

        return .{
            .stream = stream,
            .recv_buf = undefined,
        };
    }

    /// Close the connection.
    pub fn close(self: *DragonflyClient) void {
        self.stream.close();
    }

    /// GET a binary value by key.
    /// Returns the value bytes (pointing into recv_buf — valid until next call), or null.
    pub fn get(self: *DragonflyClient, key: []const u8) ?[]const u8 {
        // Send: *2\r\n$3\r\nGET\r\n${key.len}\r\n{key}\r\n
        self.sendCommand(&[_][]const u8{ "GET", key }) catch return null;
        return self.readBulkReply() catch null;
    }

    /// SET a binary key-value pair with optional TTL in seconds.
    /// Returns true on success.
    pub fn set(self: *DragonflyClient, key: []const u8, value: []const u8, ttl_secs: u32) bool {
        if (ttl_secs > 0) {
            var ttl_buf: [16]u8 = undefined;
            const ttl_str = std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl_secs}) catch return false;
            self.sendCommand(&[_][]const u8{ "SET", key, value, "EX", ttl_str }) catch return false;
        } else {
            self.sendCommand(&[_][]const u8{ "SET", key, value }) catch return false;
        }
        return self.readSimpleReply() catch false;
    }

    /// DEL a key. Returns true if the key was deleted.
    pub fn del(self: *DragonflyClient, key: []const u8) bool {
        self.sendCommand(&[_][]const u8{ "DEL", key }) catch return false;
        const n = self.readIntegerReply() catch return false;
        return n > 0;
    }

    /// PING — returns true if server responds with PONG.
    pub fn ping(self: *DragonflyClient) bool {
        self.sendCommand(&[_][]const u8{"PING"}) catch return false;
        // Expect +PONG\r\n
        const n = self.stream.read(&self.recv_buf) catch return false;
        if (n >= 7 and std.mem.startsWith(u8, self.recv_buf[0..n], "+PONG\r\n")) return true;
        return false;
    }

    // ── Internal: RESP2 encoding ──────────────────────────────────────

    fn sendCommand(self: *DragonflyClient, args: []const []const u8) !void {
        // Send array header: *{argc}\r\n
        var header_buf: [32]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "*{d}\r\n", .{args.len});
        try self.stream.writeAll(header);

        // Send each argument as bulk string: ${len}\r\n{data}\r\n
        for (args) |arg| {
            var len_buf: [32]u8 = undefined;
            const len_str = try std.fmt.bufPrint(&len_buf, "${d}\r\n", .{arg.len});
            try self.stream.writeAll(len_str);
            try self.stream.writeAll(arg);
            try self.stream.writeAll("\r\n");
        }
    }

    fn readBulkReply(self: *DragonflyClient) !?[]const u8 {
        // Read response into recv_buf
        const n = try self.stream.read(&self.recv_buf);
        if (n == 0) return error.ConnectionClosed;

        const resp = self.recv_buf[0..n];

        // Null bulk string: $-1\r\n
        if (n >= 5 and resp[0] == '$' and resp[1] == '-' and resp[2] == '1') return null;

        // Bulk string: ${len}\r\n{data}\r\n
        if (resp[0] != '$') return null;

        // Parse length
        var i: usize = 1;
        var len: usize = 0;
        while (i < n and resp[i] != '\r') : (i += 1) {
            if (resp[i] < '0' or resp[i] > '9') return null;
            len = len * 10 + (resp[i] - '0');
        }
        i += 2; // skip \r\n

        // Data may span multiple reads for large values
        if (i + len <= n) {
            return resp[i .. i + len];
        }

        // Need more data — for our use case (952 bytes), this shouldn't happen
        // with a 4KB buffer, but handle gracefully
        return null;
    }

    fn readSimpleReply(self: *DragonflyClient) !bool {
        const n = try self.stream.read(&self.recv_buf);
        if (n == 0) return error.ConnectionClosed;
        // +OK\r\n
        return n >= 5 and self.recv_buf[0] == RESP_SIMPLE_STRING;
    }

    fn readIntegerReply(self: *DragonflyClient) !i64 {
        const n = try self.stream.read(&self.recv_buf);
        if (n == 0) return error.ConnectionClosed;
        if (self.recv_buf[0] != RESP_INTEGER) return 0;

        var i: usize = 1;
        var negative = false;
        if (i < n and self.recv_buf[i] == '-') {
            negative = true;
            i += 1;
        }
        var val: i64 = 0;
        while (i < n and self.recv_buf[i] != '\r') : (i += 1) {
            if (self.recv_buf[i] < '0' or self.recv_buf[i] > '9') break;
            val = val * 10 + @as(i64, self.recv_buf[i] - '0');
        }
        return if (negative) -val else val;
    }
};

// ============================================================================
// C-ABI exports for Chapel FFI
// ============================================================================

/// Opaque handle wrapping DragonflyClient.
const DfHandle = struct {
    client: DragonflyClient,
};

/// Connect to a Dragonfly/Redis server.
/// host: null-terminated "host:port" string (e.g., "localhost:6379")
/// Returns opaque handle, or null on failure.
export fn ddac_dragonfly_connect(host_port: [*:0]const u8) ?*anyopaque {
    const hp = std.mem.span(host_port);

    // Parse "host:port"
    var colon_pos: ?usize = null;
    for (hp, 0..) |ch, idx| {
        if (ch == ':') colon_pos = idx;
    }

    const host = if (colon_pos) |cp| hp[0..cp] else hp;
    const port: u16 = if (colon_pos) |cp| blk: {
        const port_str = hp[cp + 1 ..];
        break :blk std.fmt.parseInt(u16, port_str, 10) catch 6379;
    } else 6379;

    const client = DragonflyClient.connect(host, port) orelse return null;

    // Verify connection
    var handle = std.heap.c_allocator.create(DfHandle) catch return null;
    handle.client = client;

    if (!handle.client.ping()) {
        handle.client.close();
        std.heap.c_allocator.destroy(handle);
        return null;
    }

    return @ptrCast(handle);
}

/// Close and free the Dragonfly connection.
export fn ddac_dragonfly_close(handle: ?*anyopaque) void {
    if (handle) |h| {
        const df: *DfHandle = @ptrCast(@alignCast(h));
        df.client.close();
        std.heap.c_allocator.destroy(df);
    }
}

/// Look up a cached parse result by document SHA-256.
/// sha256: 64-char hex string (null-terminated)
/// result_out: pointer to ddac_parse_result_t (952 bytes)
/// Returns 1 on cache hit, 0 on miss.
export fn ddac_dragonfly_lookup(
    handle: *anyopaque,
    sha256: [*:0]const u8,
    result_out: [*]u8,
    result_size: usize,
) c_int {
    const df: *DfHandle = @ptrCast(@alignCast(handle));
    const sha = std.mem.span(sha256);

    // Build cache key: "ddac:{sha256}"
    var key_buf: [72]u8 = undefined; // "ddac:" + 64 hex + null
    const prefix = "ddac:";
    @memcpy(key_buf[0..prefix.len], prefix);
    const key_len = @min(sha.len, 64);
    @memcpy(key_buf[prefix.len .. prefix.len + key_len], sha[0..key_len]);

    const value = df.client.get(key_buf[0 .. prefix.len + key_len]) orelse return 0;

    if (value.len != result_size) return 0;

    @memcpy(result_out[0..result_size], value);
    return 1;
}

/// Store a parse result in the Dragonfly cache.
/// sha256: 64-char hex string (null-terminated)
/// result: pointer to ddac_parse_result_t (952 bytes)
/// ttl_secs: time-to-live in seconds (0 = no expiry)
export fn ddac_dragonfly_store(
    handle: *anyopaque,
    sha256: [*:0]const u8,
    result: [*]const u8,
    result_size: usize,
    ttl_secs: u32,
) void {
    const df: *DfHandle = @ptrCast(@alignCast(handle));
    const sha = std.mem.span(sha256);

    // Build cache key
    var key_buf: [72]u8 = undefined;
    const prefix = "ddac:";
    @memcpy(key_buf[0..prefix.len], prefix);
    const key_len = @min(sha.len, 64);
    @memcpy(key_buf[prefix.len .. prefix.len + key_len], sha[0..key_len]);

    _ = df.client.set(key_buf[0 .. prefix.len + key_len], result[0..result_size], ttl_secs);
}

/// Get the number of ddac keys in the cache (approximate).
/// Uses DBSIZE command.
export fn ddac_dragonfly_count(handle: *anyopaque) u64 {
    const df: *DfHandle = @ptrCast(@alignCast(handle));
    df.client.sendCommand(&[_][]const u8{"DBSIZE"}) catch return 0;
    const n = df.client.readIntegerReply() catch return 0;
    return if (n >= 0) @intCast(n) else 0;
}
