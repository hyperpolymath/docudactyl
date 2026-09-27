// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
// Docudactyl — Dragonfly / Redis RESP Client (L2 Cache)
//
// Minimal RESP2 client for Dragonfly (Redis-compatible) cross-locale cache.
// Supports GET, SET (with TTL), and DEL operations on binary keys and values.
//
// Cache key format:  "ddac:{sha256_hex}" (69 bytes)
// Cache value format: raw bytes of ddac_parse_result_t (952 bytes)
//
// Dragonfly advantages over Redis:
//   - 25x throughput on same hardware
//   - Multi-threaded (no single-thread bottleneck)
//   - Compatible with RESP2 protocol

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
    healthy: bool = true,

    /// Connect to a Dragonfly/Redis server.
    /// Returns null if connection fails.
    pub fn connect(host: []const u8, port: u16) ?DragonflyClient {
        const addr = std.net.Address.parseIp4(host, port) catch return null;
        const stream = std.net.tcpConnectToAddress(addr) catch return null;

        // A cache must not block extraction indefinitely. Reject connections
        // if either timeout cannot be installed (Stream.handle is a raw fd).
        const timeout = std.posix.timeval{ .sec = 5, .usec = 0 };
        for ([_]u32{ std.posix.SO.RCVTIMEO, std.posix.SO.SNDTIMEO }) |option| {
            std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, option, std.mem.asBytes(&timeout)) catch {
                stream.close();
                return null;
            };
        }

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
        if (!self.healthy) return null;
        self.sendCommand(&[_][]const u8{ "GET", key }) catch {
            self.healthy = false;
            return null;
        };
        return self.readBulkReply() catch {
            self.healthy = false;
            return null;
        };
    }

    /// SET a binary key-value pair with optional TTL in seconds.
    /// Returns true on success.
    pub fn set(self: *DragonflyClient, key: []const u8, value: []const u8, ttl_secs: u32) bool {
        if (!self.healthy) return false;
        if (ttl_secs > 0) {
            var ttl_buf: [16]u8 = undefined;
            const ttl_str = std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl_secs}) catch {
                self.healthy = false;
                return false;
            };
            self.sendCommand(&[_][]const u8{ "SET", key, value, "EX", ttl_str }) catch {
                self.healthy = false;
                return false;
            };
        } else {
            self.sendCommand(&[_][]const u8{ "SET", key, value }) catch {
                self.healthy = false;
                return false;
            };
        }
        return self.readSimpleReply() catch false;
    }

    /// DEL a key. Returns true if the key was deleted.
    pub fn del(self: *DragonflyClient, key: []const u8) bool {
        if (!self.healthy) return false;
        self.sendCommand(&[_][]const u8{ "DEL", key }) catch {
            self.healthy = false;
            return false;
        };
        const n = self.readIntegerReply() catch {
            self.healthy = false;
            return false;
        };
        return n > 0;
    }

    /// PING — returns true if server responds with PONG.
    pub fn ping(self: *DragonflyClient) bool {
        if (!self.healthy) return false;
        self.sendCommand(&[_][]const u8{"PING"}) catch {
            self.healthy = false;
            return false;
        };
        const line = self.readLine() catch {
            self.healthy = false;
            return false;
        };
        return std.mem.eql(u8, line, "+PONG");
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

    // TCP preserves bytes, not RESP frame boundaries. Read exactly one frame
    // without consuming any bytes from the next response. Bound every length
    // before indexing or arithmetic so an untrusted cache cannot overflow.
    fn readExact(self: *DragonflyClient, bytes: []u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = try self.stream.read(bytes[offset..]);
            if (n == 0) return error.ConnectionClosed;
            offset += n;
        }
    }

    fn readLine(self: *DragonflyClient) ![]const u8 {
        var used: usize = 0;
        while (used < self.recv_buf.len) {
            try self.readExact(self.recv_buf[used .. used + 1]);
            if (self.recv_buf[used] == '\r') {
                var lf: [1]u8 = undefined;
                try self.readExact(&lf);
                if (lf[0] != '\n') return error.InvalidReply;
                return self.recv_buf[0..used];
            }
            if (self.recv_buf[used] == '\n') return error.InvalidReply;
            used += 1;
        }
        return error.ReplyTooLarge;
    }

    fn readBulkReply(self: *DragonflyClient) !?[]const u8 {
        const line = try self.readLine();
        if (std.mem.eql(u8, line, "$-1")) return null;
        if (line.len < 2 or line[0] != '$') return error.InvalidReply;
        for (line[1..]) |ch| {
            if (ch < '0' or ch > '9') return error.InvalidReply;
        }
        const len = std.fmt.parseInt(usize, line[1..], 10) catch return error.InvalidReply;
        if (len > self.recv_buf.len) return error.ReplyTooLarge;
        try self.readExact(self.recv_buf[0..len]);
        var terminator: [2]u8 = undefined;
        try self.readExact(&terminator);
        if (!std.mem.eql(u8, &terminator, "\r\n")) return error.InvalidReply;
        return self.recv_buf[0..len];
    }

    fn readSimpleReply(self: *DragonflyClient) !bool {
        return std.mem.eql(u8, try self.readLine(), "+OK");
    }

    fn readIntegerReply(self: *DragonflyClient) !i64 {
        const line = try self.readLine();
        if (line.len < 2 or line[0] != ':') return error.InvalidReply;
        return std.fmt.parseInt(i64, line[1..], 10) catch error.InvalidReply;
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

    var client = DragonflyClient.connect(host, port) orelse return null;

    // Verify connection
    const handle = std.heap.c_allocator.create(DfHandle) catch {
        client.close();
        return null;
    };
    handle.client = client;

    if (!handle.client.ping()) {
        handle.client.close();
        std.heap.c_allocator.destroy(handle);
        return null;
    }

    // SAFETY: handle was just allocated by c_allocator.create(DfHandle), which returns a well-aligned *DfHandle
    return @ptrCast(handle);
}

/// Close and free the Dragonfly connection.
export fn ddac_dragonfly_close(handle: ?*anyopaque) void {
    if (handle) |h| {
        // SAFETY: h originates from ddac_dragonfly_connect() which stores a *DfHandle via @ptrCast; alignment is guaranteed by c_allocator
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
    // SAFETY: handle originates from ddac_dragonfly_connect() which stores a *DfHandle via @ptrCast; alignment is guaranteed by c_allocator
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
    // SAFETY: handle originates from ddac_dragonfly_connect() which stores a *DfHandle via @ptrCast; alignment is guaranteed by c_allocator
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
    // SAFETY: handle originates from ddac_dragonfly_connect() which stores a *DfHandle via @ptrCast; alignment is guaranteed by c_allocator
    const df: *DfHandle = @ptrCast(@alignCast(handle));
    df.client.sendCommand(&[_][]const u8{"DBSIZE"}) catch return 0;
    const n = df.client.readIntegerReply() catch return 0;
    return if (n >= 0) @intCast(n) else 0;
}

// Pipes deliberately model only the byte stream used by the reply decoder.
// Coalesced frames must remain separate and malformed/oversized frames fail.
fn testReply(bytes: []const u8) !DragonflyClient {
    const fds = try std.posix.pipe();
    errdefer std.posix.close(fds[0]);
    const writer = std.fs.File{ .handle = fds[1] };
    defer writer.close();
    try writer.writeAll(bytes);
    return .{ .stream = .{ .handle = fds[0] }, .recv_buf = undefined };
}

test "RESP bulk consumes exactly one frame including binary payload" {
    var client = try testReply("$3\r\na\x00b\r\n$0\r\n\r\n$-1\r\n:12\r\n+OK\r\n");
    defer client.close();
    try std.testing.expectEqualStrings("a\x00b", (try client.readBulkReply()).?);
    try std.testing.expectEqualStrings("", (try client.readBulkReply()).?);
    try std.testing.expect((try client.readBulkReply()) == null);
    try std.testing.expectEqual(@as(i64, 12), try client.readIntegerReply());
    try std.testing.expect(try client.readSimpleReply());
}

test "RESP rejects invalid lengths and terminators" {
    const cases = [_][]const u8{ "$-2\r\n", "$999999999999999999999999999999\r\n", "$1\r\naXX", "$1\nx" };
    for (cases) |bytes| {
        var client = try testReply(bytes);
        defer client.close();
        try std.testing.expectError(error.InvalidReply, client.readBulkReply());
    }
    var oversized = try testReply("$4097\r\n");
    defer oversized.close();
    try std.testing.expectError(error.ReplyTooLarge, oversized.readBulkReply());
    var truncated = try testReply("$3\r\na");
    defer truncated.close();
    try std.testing.expectError(error.ConnectionClosed, truncated.readBulkReply());
}

fn writeFragmentedReply(fd: std.posix.fd_t) void {
    const writer = std.fs.File{ .handle = fd };
    defer writer.close();
    // Feed the header, payload bytes and trailer independently.
    writer.writeAll("$4096\r\n") catch return;
    for (0..4096) |_| writer.writeAll("x") catch return;
    writer.writeAll("\r\n:1\r\n") catch return;
}

test "RESP handles payload arriving over multiple writes" {
    const fds = try std.posix.pipe();
    var client = DragonflyClient{ .stream = .{ .handle = fds[0] }, .recv_buf = undefined };
    defer client.close();
    const thread = try std.Thread.spawn(.{}, writeFragmentedReply, .{fds[1]});
    defer thread.join();
    const payload = (try client.readBulkReply()).?;
    try std.testing.expectEqual(@as(usize, 4096), payload.len);
    for (payload) |ch| try std.testing.expectEqual(@as(u8, 'x'), ch);
    try std.testing.expectEqual(@as(i64, 1), try client.readIntegerReply());
}
