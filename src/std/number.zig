pub const impls: []const api.Impl = &.{
    .{ .name = "__call", .f = root.define(&.{ .any, .any }, call) },
    .{ .name = "is_nan?", .f = root.define(&.{.number}, isNan) },
    .{ .name = "is_finite?", .f = root.define(&.{.number}, isFinite) },
    .{ .name = "is_inf?", .f = root.define(&.{.number}, isInf) },
    .{ .name = "floor", .f = root.define(&.{.number}, floor) },
    .{ .name = "ceil", .f = root.define(&.{.number}, ceil) },
    .{ .name = "round", .f = root.define(&.{.number}, round) },
    .{ .name = "abs", .f = root.define(&.{.number}, abs) },
};

// -- [impl] ------------------------------------------------------------------

fn number(args: []const Data) f64 {
    return args[0].asNum().?;
}

fn call(args: []const Data, vm: *VM) !HostResult {
    _ = args[0];
    return root.number_(args[1..], vm);
}

fn isNan(args: []const Data, _: *VM) !HostResult {
    return .okBool(std.math.isNan(number(args)));
}

fn isFinite(args: []const Data, _: *VM) !HostResult {
    return .okBool(std.math.isFinite(number(args)));
}

fn isInf(args: []const Data, _: *VM) !HostResult {
    return .okBool(std.math.isInf(number(args)));
}

fn floor(args: []const Data, _: *VM) !HostResult {
    return .okData(Data.new.num(@floor(number(args))));
}

fn ceil(args: []const Data, _: *VM) !HostResult {
    return .okData(Data.new.num(@ceil(number(args))));
}

fn round(args: []const Data, _: *VM) !HostResult {
    return .okData(Data.new.num(@round(number(args))));
}

fn abs(args: []const Data, _: *VM) !HostResult {
    return .okData(Data.new.num(@abs(number(args))));
}

test "number module and metatable" {
    try testing.topNumber("unwrap(number(\"12\"))", 12);
    try testing.topNumber("unwrap(number(3.5))", 3.5);
    try testing.topTrue("number.is_nan?(unwrap(number(\"nan\")))");
    try testing.topTrue("unwrap(number(\"nan\")):is_nan?()");
    try testing.topFalse("42:is_nan?()");
    try testing.topTrue("42:is_finite?()");
    try testing.topFalse("42:is_inf?()");
    try testing.topTrue("unwrap(number(\"inf\")):is_inf?()");
    try testing.topNumber("3.7:floor()", 3);
    try testing.topNumber("3.2:ceil()", 4);
    try testing.topNumber("3.5:round()", 4);
    try testing.topNumber("(-3):abs()", 3);
    try testing.topNumber("number.abs(-7)", 7);
}

const std = @import("std");

const revo = @import("../root.zig");
const testing = revo.lang.testing;
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const HostResult = root.HostResult;
