// Docudactyl — I/O Prefetcher (Linux io_uring + fadvise)
//
// Addresses Wall 2 (I/O bandwidth) by prefetching upcoming documents
// into the kernel page cache while the current document is being parsed.
//
// Two strategies:
//   io_uring:  True async reads via submission queue (Linux 5.6+)
//   fadvise:   Hint-based readahead via posix_fadvise (all Linux)
//
// The prefetcher manages a sliding window of N upcoming files.
// Chapel tasks call ddac_prefetch_hint() before processing each document
// to keep the pipeline full.
//
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <jonathan.jewell@open.ac.uk>

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// Prefetcher State
// ============================================================================

const MAX_INFLIGHT: usize = 16; // Prefetch up to 16 files ahead
const READAHEAD_SIZE: usize = 256 * 1024; // 256 KB initial readahead per file

const PrefetchState = struct {
    /// File descriptors of prefetched files (to close after processing)
    fds: [MAX_INFLIGHT]std.posix.fd_t,
    paths: [MAX_INFLIGHT]?[*:0]const u8,
    count: usize,
    head: usize, // next slot to fill
    use_uring: bool,
    ring: if (builtin.os.tag == .linux) ?IoUringState else void,
};

const IoUringState = struct {
    ring: std.os.linux.IoUring,
};

var global_state: ?*PrefetchState = null;

// ============================================================================
// C-ABI exports
// ============================================================================

/// Initialise the I/O prefetcher.
/// window_size: how many files to prefetch ahead (clamped to MAX_INFLIGHT)
/// Returns opaque handle, or null on failure.
export fn ddac_prefetch_init(window_size: u32) ?*anyopaque {
    const state = std.heap.c_allocator.create(PrefetchState) catch return null;

    state.* = .{
        .fds = [_]std.posix.fd_t{-1} ** MAX_INFLIGHT,
        .paths = [_]?[*:0]const u8{null} ** MAX_INFLIGHT,
        .count = @min(window_size, MAX_INFLIGHT),
        .head = 0,
        .use_uring = false,
        .ring = if (builtin.os.tag == .linux) null else {},
    };

    // Try to initialise io_uring (Linux 5.6+)
    if (builtin.os.tag == .linux) {
        if (std.os.linux.IoUring.init(64, .{})) |ring| {
            state.ring = .{ .ring = ring };
            state.use_uring = true;
        } else |_| {
            // Fall back to fadvise
            state.use_uring = false;
        }
    }

    global_state = state;
    return @ptrCast(state);
}

/// Submit a prefetch hint for an upcoming file.
/// The kernel will start loading the file into page cache asynchronously.
export fn ddac_prefetch_hint(handle: *anyopaque, path: [*:0]const u8) void {
    const state: *PrefetchState = @ptrCast(@alignCast(handle));

    // Close the file that was in this slot previously (if any)
    const slot = state.head % state.count;
    if (state.fds[slot] >= 0) {
        std.posix.close(state.fds[slot]);
        state.fds[slot] = -1;
    }

    // Open the new file
    const fd = std.posix.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch return;
    state.fds[slot] = fd;
    state.paths[slot] = path;

    if (builtin.os.tag == .linux) {
        if (state.use_uring) {
            // io_uring: submit an async readahead operation
            prefetchWithUring(state, fd);
        } else {
            // fadvise: tell kernel to read ahead
            prefetchWithFadvise(fd);
        }
    }

    state.head +%= 1;
}

/// Signal that a file has been processed. Releases page cache.
export fn ddac_prefetch_done(handle: *anyopaque, path: [*:0]const u8) void {
    const state: *PrefetchState = @ptrCast(@alignCast(handle));
    _ = path; // TODO: could match by path and close specific FD

    if (builtin.os.tag == .linux) {
        // Drain completed io_uring operations
        if (state.use_uring) {
            drainUring(state);
        }
    }
}

/// Free the prefetcher and close all open files.
export fn ddac_prefetch_free(handle: ?*anyopaque) void {
    if (handle) |h| {
        const state: *PrefetchState = @ptrCast(@alignCast(h));

        // Close all open file descriptors
        for (&state.fds) |*fd| {
            if (fd.* >= 0) {
                std.posix.close(fd.*);
                fd.* = -1;
            }
        }

        // Clean up io_uring
        if (builtin.os.tag == .linux) {
            if (state.ring) |*ring_state| {
                ring_state.ring.deinit();
            }
        }

        std.heap.c_allocator.destroy(state);
        global_state = null;
    }
}

/// Get prefetcher statistics.
/// Returns the number of files currently being prefetched.
export fn ddac_prefetch_inflight(handle: *anyopaque) u32 {
    const state: *PrefetchState = @ptrCast(@alignCast(handle));
    var count: u32 = 0;
    for (state.fds[0..state.count]) |fd| {
        if (fd >= 0) count += 1;
    }
    return count;
}

// ============================================================================
// Linux-specific implementations
// ============================================================================

fn prefetchWithFadvise(fd: std.posix.fd_t) void {
    if (builtin.os.tag != .linux) return;

    // POSIX_FADV_WILLNEED = 3 (triggers readahead)
    _ = std.os.linux.fadvise(fd, 0, @intCast(READAHEAD_SIZE), 3);
}

fn prefetchWithUring(state: *PrefetchState, fd: std.posix.fd_t) void {
    if (builtin.os.tag != .linux) return;

    if (state.ring) |*ring_state| {
        // Submit a NOP operation as a readahead trigger
        // (io_uring doesn't have a native readahead op, but opening + fadvise
        // is triggered by the kernel when we submit a read)
        //
        // Use IORING_OP_FADVISE if available (kernel 5.6+)
        var sqe = ring_state.ring.get_sqe() orelse return;
        sqe.prep_fadvise(fd, 0, @intCast(READAHEAD_SIZE), 3); // POSIX_FADV_WILLNEED
        sqe.user_data = @intCast(fd);

        // Submit without waiting
        _ = ring_state.ring.submit() catch {};
    }
}

fn drainUring(state: *PrefetchState) void {
    if (builtin.os.tag != .linux) return;

    if (state.ring) |*ring_state| {
        // Collect any completed operations (non-blocking)
        while (ring_state.ring.cq_ready() > 0) {
            _ = ring_state.ring.cq_advance(1);
        }
    }
}
