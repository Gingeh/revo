// an backend-owned job abstraction
// backend may keep its own payload types; job here is a minimal common payload

pub const AsyncTicket = usize;

const std = @import("std");

pub const AsyncJobKind = enum {
    socket_send,
    socket_recv,
    socket_accept,
    socket_connect,
};

pub const AsyncJob = struct {
    fiber_id: usize,
    kind: AsyncJobKind,
    handle: std.posix.fd_t,
    // message_id stores the VM string id as usize
    message_id: usize,
    offset: usize,
    // optional buffer for recv; allocated w runtime.alloc and owned by backend after submit
    buffer: ?[]u8,
    max_bytes: usize,
};
