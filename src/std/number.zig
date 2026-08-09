pub const specs: []const api.FnSpec = &.{
    .{
        .name = "__call",
        .placements = &.{api.mod("number")},
        .params = &.{
            .{ "value", "any" },
        },
        .ret = "number",
        .doc = "converts value to number: number(\"12\") => 12",
        .core_key = revo.core_atoms.__call,
        .f = root.define(&.{ .any, .any }, call),
    },
    .{
        .name = "is_nan?",
        .placements = &.{ api.mod("number"), api.method("number", .number) },
        .params = &.{
            .{ "self", "number" },
        },
        .ret = "bool",
        .doc = "checks if number is NaN",
        .f = root.define(&.{.number}, isNan),
    },
    .{
        .name = "is_finite?",
        .placements = &.{ api.mod("number"), api.method("number", .number) },
        .params = &.{
            .{ "self", "number" },
        },
        .ret = "bool",
        .doc = "checks if number is finite",
        .f = root.define(&.{.number}, isFinite),
    },
    .{
        .name = "is_inf?",
        .placements = &.{ api.mod("number"), api.method("number", .number) },
        .params = &.{
            .{ "self", "number" },
        },
        .ret = "bool",
        .doc = "checks if number is infinite",
        .f = root.define(&.{.number}, isInf),
    },
    .{
        .name = "floor",
        .placements = &.{ api.mod("number"), api.method("number", .number) },
        .params = &.{
            .{ "self", "number" },
        },
        .ret = "number",
        .doc = "largest integer <= self",
        .f = root.define(&.{.number}, floor),
    },
    .{
        .name = "ceil",
        .placements = &.{ api.mod("number"), api.method("number", .number) },
        .params = &.{
            .{ "self", "number" },
        },
        .ret = "number",
        .doc = "smallest integer >= self",
        .f = root.define(&.{.number}, ceil),
    },
    .{
        .name = "round",
        .placements = &.{ api.mod("number"), api.method("number", .number) },
        .params = &.{
            .{ "self", "number" },
        },
        .ret = "number",
        .doc = "rounds to nearest integer",
        .f = root.define(&.{.number}, round),
    },
    .{
        .name = "abs",
        .placements = &.{ api.mod("number"), api.method("number", .number) },
        .params = &.{
            .{ "self", "number" },
        },
        .ret = "number",
        .doc = "absolute value",
        .f = root.define(&.{.number}, abs),
    },
};

// -- [impl] ------------------------------------------------------------------

fn num(args: []const Data) f64 {
    return args[0].asNum().?;
}

fn call(args: []const Data, vm: *VM) !NativeResult {
    _ = args[0];
    return root.number_(args[1..], vm);
}

fn isNan(args: []const Data, _: *VM) !NativeResult {
    return .okBool(std.math.isNan(num(args)));
}

fn isFinite(args: []const Data, _: *VM) !NativeResult {
    return .okBool(std.math.isFinite(num(args)));
}

fn isInf(args: []const Data, _: *VM) !NativeResult {
    return .okBool(std.math.isInf(num(args)));
}

fn floor(args: []const Data, _: *VM) !NativeResult {
    return .okData(Data.new.num(@floor(num(args))));
}

fn ceil(args: []const Data, _: *VM) !NativeResult {
    return .okData(Data.new.num(@ceil(num(args))));
}

fn round(args: []const Data, _: *VM) !NativeResult {
    return .okData(Data.new.num(@round(num(args))));
}

fn abs(args: []const Data, _: *VM) !NativeResult {
    return .okData(Data.new.num(@abs(num(args))));
}

test "number module and metatable" {
    try testing.topNumber("unwrap(number(\"12\"))", 12);
    try testing.topNumber("unwrap(number(3.5))", 3.5);
    try testing.topTrue("number.is_nan(unwrap(number(\"nan\")))");
    try testing.topTrue("unwrap(number(\"nan\")):isNan()");
    try testing.topFalse("42:isNan()");
    try testing.topTrue("42:isFinite()");
    try testing.topFalse("42:isInf()");
    try testing.topTrue("unwrap(number(\"inf\")):isInf()");
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
const NativeResult = root.NativeResult;
