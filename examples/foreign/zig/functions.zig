const std = @import("std");
const revo = @import("revo");

const HostBinding = revo.HostBinding;
const HostResult = revo.std_lib.HostResult;
const Data = revo.Data;
const VM = revo.VM;

fn zadd(args: []const Data, _: *VM) anyerror!HostResult {
    const a = try args[0].asNumber();
    const b = try args[1].asNumber();
    return .okData(Data.new.num(a + b));
}

fn zecho(args: []const Data, vm: *VM) anyerror!HostResult {
    const id = args[0].asString() orelse return HostResult.errType(0, "string", "other");
    const bytes = vm.stringValue(id);
    const new_id = revo.ffi.revo_intern(@ptrCast(vm), @intFromPtr(bytes.ptr), bytes.len);
    return .okData(Data.new.str(new_id));
}

fn zsetglobal(args: []const Data, vm: *VM) anyerror!HostResult {
    const name = args[0].asString() orelse return HostResult.errType(0, "string", "other");
    try vm.setGlobal(vm.stringValue(name), args[1]);
    return .okData(Data.new.num(1));
}

fn zconcat(args: []const Data, vm: *VM) anyerror!HostResult {
    const tup_id = args[0].asTuple() orelse return HostResult.errType(0, "tuple", "other");
    const sep_id = args[1].asString() orelse return HostResult.errType(1, "string", "other");
    const sep = vm.stringValue(sep_id);
    const parts = try vm.tuples.get(tup_id);

    var buf = std.ArrayList(u8).initCapacity(vm.runtime.alloc, 32) catch {
        return HostResult.other("out of memory");
    };
    defer buf.deinit(vm.runtime.alloc);
    for (parts.items, 0..) |item, i| {
        if (i > 0) try buf.appendSlice(vm.runtime.alloc, sep);
        const s_id = item.asString() orelse return HostResult.errType(0, "tuple of strings", "other");
        try buf.appendSlice(vm.runtime.alloc, vm.stringValue(s_id));
    }
    const new_id = revo.ffi.revo_intern(@ptrCast(vm), @intFromPtr(buf.items.ptr), buf.items.len);
    return .okData(Data.new.str(new_id));
}

pub export const revo_native_bindings = [_]HostBinding{
    .{ .name = "zadd", .fn_ptr = @ptrCast(&zadd), .arity = 2, .variadic = false },
    .{ .name = "zecho", .fn_ptr = @ptrCast(&zecho), .arity = 1, .variadic = false },
    .{ .name = "zsetglobal", .fn_ptr = @ptrCast(&zsetglobal), .arity = 2, .variadic = false },
    .{ .name = "zconcat", .fn_ptr = @ptrCast(&zconcat), .arity = 2, .variadic = false },
    std.mem.zeroes(HostBinding),
};
