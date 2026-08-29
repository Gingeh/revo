pub const impls: []const api.Impl = &.{
    .{ .name = "len", .f = root.define(&[_]root.TypeSpec{.tuple}, len) },
    .{ .name = "unwrap", .f = root.define(&[_]root.TypeSpec{.tuple}, root.try_) },
    .{ .name = "unwrap_err", .f = root.define(&[_]root.TypeSpec{.tuple}, root.unwrap_err_) },
    .{ .name = "add", .f = root.define(&[_]root.TypeSpec{ .tuple, .tuple }, add) },
    .{ .name = "mul", .f = root.define(&[_]root.TypeSpec{ .tuple, .number }, mul) },
    .{ .name = "__index", .f = root.define(&[_]root.TypeSpec{ .tuple, .any }, index) },
};

fn len(args: []const Data, vm: *VM) !HostResult {
    const id = args[0].asTuple() orelse return .errType(0, "tuple", root.typeof(args[0], vm));
    const t = try vm.tuples.get(id);
    return .{ .ok = Data.new.num(t.items.len) };
}

fn index(args: []const Data, vm: *VM) !HostResult {
    const id = args[0].asTuple() orelse return .errType(0, "tuple", root.typeof(args[0], vm));
    const n = args[1].asNum() orelse return .errType(1, "num", root.typeof(args[1], vm));
    const idx = try revo.asIndex(n);
    const t = try vm.tuples.get(id);
    if (idx >= t.items.len) return .okData(revo.Data.new.core(.missing));
    return .okData(t.items[idx]);
}

fn add(args: []const Data, vm: *VM) !HostResult {
    const left_id = args[0].asTuple() orelse return .errType(0, "tuple", root.typeof(args[0], vm));
    const right_id = args[1].asTuple() orelse return .errType(1, "tuple", root.typeof(args[1], vm));
    const left = try vm.tuples.get(left_id);
    const right = try vm.tuples.get(right_id);
    var items = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, left.items.len + right.items.len);
    defer items.deinit(vm.runtime.alloc);
    try items.appendSlice(vm.runtime.alloc, left.items);
    try items.appendSlice(vm.runtime.alloc, right.items);
    return .okData(Data.new.tuple(try vm.tuples.create(items.items)));
}

fn mul(args: []const Data, vm: *VM) !HostResult {
    const tuple_id = args[0].asTuple() orelse return .errType(0, "tuple", root.typeof(args[0], vm));
    const n = args[1].asNum() orelse return .errType(1, "num", root.typeof(args[1], vm));
    const times: i64 = root.numToInt(i64, n) orelse return .errType(1, "integer num", root.typeof(args[1], vm));
    if (times < 0) return .errType(1, "non-negative num", "negative num");
    const tuple = try vm.tuples.get(tuple_id);
    var items = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, tuple.items.len * @as(usize, @intCast(times)));
    defer items.deinit(vm.runtime.alloc);
    for (0..@as(usize, @intCast(times))) |_| {
        try items.appendSlice(vm.runtime.alloc, tuple.items);
    }
    return .okData(Data.new.tuple(try vm.tuples.create(items.items)));
}

const std = @import("std");

const revo = @import("../root.zig");
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const HostResult = root.HostResult;
const testing = revo.lang.testing;

test "generic unwrap_err infers T" {
    try testing.topString("(:err, \"boom\"):unwrap_err()", "boom");
    try testing.topNumber("(:err, 7):unwrap_err()", 7);
}

test "untyped receivers resolve module fns via the metatable" {
    try testing.topNumber("fn f(t) do t:unwrap_err() end f((:err, 3))", 3);
    try testing.topNumber("fn f(t) do t:len() end f((1, 2, 3))", 3);
}
