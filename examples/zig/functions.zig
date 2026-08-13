//!
//! zig extension, for revo
//! build: zig build   (produces zrevo.so, revo as a module dependency)
//!
//! the shared lib exports revo_bindings which import(".so") picks up
//!
const std = @import("std");
const revo = @import("revo");

const RevoBinding = revo.functions.RevoBinding;
const Data = revo.Data;
const VM = revo.VM;

/// > zadd(a: number, b: number) -> number
fn zadd(vm_ptr: *anyopaque, argc: usize, argv: [*]const Data, out: *Data) callconv(.c) void {
    _ = vm_ptr;
    if (argc < 2) {
        out.* = Data.new.nil();
        return;
    }
    out.* = Data.new.num(argv[0].asNum().? + argv[1].asNum().?);
}

/// > zecho(s: string) -> string
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

/// > zsetglobal(name: string, value) -> number
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

pub export const revo_bindings = [_]RevoBinding{
    .{ .name = "zadd", .fn_ptr = @ptrCast(&zadd) },
    .{ .name = "zecho", .fn_ptr = @ptrCast(&zecho) },
    .{ .name = "zsetglobal", .fn_ptr = @ptrCast(&zsetglobal) },
    std.mem.zeroes(RevoBinding),
};
