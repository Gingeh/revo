//!
//! zig extension, for revo
//! build: zig build   (produces zrevo.so, revo as a module dependency)
//!
//! the shared lib exports revo_bindings which import(".so") picks up
//!
//! the type interface lives in the sibling zrevo.d.rv manifest, not here.
//! every binding lands in this module's table at import time
//!
const std = @import("std");
const revo = @import("revo");

const RevoBinding = revo.functions.RevoBinding;
const Data = revo.Data;
const VM = revo.VM;

fn zadd(vm_ptr: *anyopaque, argc: usize, argv: [*]const Data, out: *Data) callconv(.c) void {
    _ = vm_ptr;
    if (argc < 2) {
        out.* = Data.new.nil();
        return;
    }
    out.* = Data.new.num(argv[0].asNum().? + argv[1].asNum().?);
}

fn zecho(vm_ptr: *anyopaque, argc: usize, argv: [*]const Data, out: *Data) callconv(.c) void {
    if (argc < 1) {
        out.* = Data.new.nil();
        return;
    }
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const id = argv[0].asString() orelse {
        out.* = Data.new.nil();
        return;
    };
    const bytes = v.stringValue(id);
    const new_id = revo.ffi.revo_intern(@ptrCast(v), @intFromPtr(bytes.ptr), bytes.len);
    out.* = Data.new.str(new_id);
}

/// full vm access: cast the opaque vm pointer and use the normal api
fn zsetglobal(vm_ptr: *anyopaque, argc: usize, argv: [*]const Data, out: *Data) callconv(.c) void {
    if (argc < 2) {
        out.* = Data.new.nil();
        return;
    }
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    v.setGlobal(v.stringValue(argv[0].asString().?), argv[1]) catch {
        out.* = Data.new.nil();
        return;
    };
    out.* = Data.new.num(1);
}

/// tuples concat via the self argument: `("a", "b"):zconcat("-")`
fn zconcat(vm_ptr: *anyopaque, argc: usize, argv: [*]const Data, out: *Data) callconv(.c) void {
    if (argc < 2) {
        out.* = Data.new.nil();
        return;
    }
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tup_id = argv[0].asTuple() orelse {
        out.* = Data.new.nil();
        return;
    };
    const sep_id = argv[1].asString() orelse {
        out.* = Data.new.nil();
        return;
    };
    const sep = v.stringValue(sep_id);
    const parts = v.tuples.get(tup_id) catch {
        out.* = Data.new.nil();
        return;
    };

    var buf = std.ArrayList(u8).initCapacity(v.runtime.alloc, 32) catch {
        out.* = Data.new.nil();
        return;
    };
    defer buf.deinit(v.runtime.alloc);
    for (parts.items, 0..) |item, i| {
        if (i > 0) buf.appendSlice(v.runtime.alloc, sep) catch {
            out.* = Data.new.nil();
            return;
        };
        const s_id = item.asString() orelse {
            out.* = Data.new.nil();
            return;
        };
        buf.appendSlice(v.runtime.alloc, v.stringValue(s_id)) catch {
            out.* = Data.new.nil();
            return;
        };
    }
    const new_id = revo.ffi.revo_intern(@ptrCast(v), @intFromPtr(buf.items.ptr), buf.items.len);
    out.* = Data.new.str(new_id);
}

pub export const revo_bindings = [_]RevoBinding{
    .{ .name = "zadd", .fn_ptr = @ptrCast(&zadd) },
    .{ .name = "zecho", .fn_ptr = @ptrCast(&zecho) },
    .{ .name = "zsetglobal", .fn_ptr = @ptrCast(&zsetglobal) },
    .{ .name = "zconcat", .fn_ptr = @ptrCast(&zconcat) },
    std.mem.zeroes(RevoBinding),
};