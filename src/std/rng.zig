const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const api = @import("api.zig");
const testing = revo.lang.testing;

const Data = revo.Data;
const VM = revo.VM;
const HostResult = root.HostResult;

pub const impls: []const api.Impl = &.{
    .{ .name = "set_seed", .f = root.define(&.{.number}, setSeed) },
    .{ .name = "revert_seed", .f = root.define(&.{}, revertSeed) },
    .{ .name = "rand", .f = root.define(&.{.number}, rand) },
    .{ .name = "range", .f = root.define(&.{ .number, .number }, randRange) },
    .{ .name = "rand_float", .f = root.define(&.{}, randFloat) },
    .{ .name = "choice", .f = root.define(&.{.table}, choice) },
};

pub fn setSeed(args: []const Data, vm: *VM) !HostResult {
    const raw_arg = args[0].asNum() orelse return .errType(0, "num", root.typeof(args[0], vm));
    const new_seed: u64 = root.numToInt(u64, raw_arg) orelse return .errType(0, "non-negative integer", root.typeof(args[0], vm));

    vm.runtime.rng_prng = std.Random.DefaultPrng.init(new_seed);

    return .okData(Data.new.nil());
}

pub fn revertSeed(args: []const Data, vm: *VM) !HostResult {
    _ = args;

    vm.runtime.rng_prng = null;

    return .okData(Data.new.nil());
}

pub fn rand(args: []const Data, vm: *VM) !HostResult {
    const raw_arg = args[0].asNum() orelse return .errType(0, "num", root.typeof(args[0], vm));
    const upper_bound: isize = root.numToInt(isize, raw_arg) orelse return .errType(0, "integer num", root.typeof(args[0], vm));

    return .okData(Data.new.num(randomNumber(isize, vm, 0, upper_bound)));
}

pub fn randRange(args: []const Data, vm: *VM) !HostResult {
    const raw_lower = args[0].asNum() orelse return .errType(0, "num", root.typeof(args[0], vm));
    const lower_bound: isize = root.numToInt(isize, raw_lower) orelse return .errType(0, "integer num", root.typeof(args[0], vm));

    const raw_upper = args[1].asNum() orelse return .errType(1, "num", root.typeof(args[1], vm));
    const upper_bound: isize = root.numToInt(isize, raw_upper) orelse return .errType(1, "integer num", root.typeof(args[1], vm));

    const result = if (lower_bound < upper_bound)
        randomNumber(isize, vm, lower_bound, upper_bound)
    else
        randomNumber(isize, vm, upper_bound, lower_bound);

    return .okData(Data.new.num(result));
}

pub fn randFloat(args: []const Data, vm: *VM) !HostResult {
    _ = args;

    return .okData(Data.new.num(randomNumber(f64, vm, 0.0, 1.0)));
}

pub fn choice(args: []const Data, vm: *VM) !HostResult {
    const tid = args[0].asTable().?;

    const table = try vm.tables.get(tid);

    if (table.array.items.len > 0) {
        const idx = randomNumber(usize, vm, 0, table.array.items.len - 1);

        return .okData(table.array.items[idx]);
    } else {
        return .okData(Data.new.nil());
    }
}

fn randomNumber(comptime T: type, vm: *VM, lowerBound: T, upperBound: T) T {
    // seed once on first use so a loop advances a single stream, a
    // fresh per-call generator seeded from the same-ns timestamp would
    // return identical values for every call in that nanosecond
    if (vm.runtime.rng_prng == null) {
        const time_seed: u64 = @intCast(std.Io.Clock.awake.now(vm.runtime.io).toNanoseconds());
        vm.runtime.rng_prng = std.Random.DefaultPrng.init(time_seed);
    }
    var random = vm.runtime.rng_prng.?.random();
    return switch (@typeInfo(T)) {
        .int => random.intRangeAtMost(T, lowerBound, upperBound),
        .float => random.float(T),
        else => unreachable,
    };
}

test "getting random element from table" {
    try testing.topNumber(
        \\ rng.set_seed(2226)
        \\ const elem = rng.choice({1, 2, 3})
        \\ elem
    , 3);
}

test "nil from a table with only named members" {
    try testing.topTrue(
        \\ let t = {"hi" = 1, "bye" = 2}
        \\ let result = :true
        \\
        \\ for _ in 0..100 
        \\   result = result and rng.choice(t) == :nil
        \\
        \\ result
    );
}

test "seed setting and resetting" {
    try testing.topTrue(
        \\ rng.set_seed(2226)
        \\ let x_total = 0 
        \\
        \\ for x in 0..10 
        \\   x_total += rng.rand(x)
        \\
        \\ rng.set_seed(7)
        \\ let y_total = 0
        \\
        \\ for y in 0..10
        \\   y_total += rng.rand(y)
        \\
        \\ x_total == 16 and y_total == 24
    );
}
