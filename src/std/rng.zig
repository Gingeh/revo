const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const api = @import("api.zig");
const testing = revo.lang.testing;

const Data = revo.Data;
const VM = revo.VM;
const NativeResult = root.NativeResult;

// Possibly change when multi-vm and multi-threading to prevent bad stuff from happening
var prng: ?std.Random.DefaultPrng = null;

pub const specs: []const api.FnSpec = &.{
    .{
        .name = "set_seed",
        .placements = &.{api.mod("rng")},
        .params = &.{
            .{ "seed", "number" },
        },
        .ret = "",
        .doc = "Statically sets the seed used for generation of pseudo-random numbers.",
        .f = root.define(&.{.number}, setSeed),
    },
    .{
        .name = "revert_seed",
        .placements = &.{api.mod("rng")},
        .params = &.{},
        .ret = "",
        .doc = "Reverts seed back to using the current time at the time of generation.",
        .f = root.define(&.{}, revertSeed),
    },
    .{
        .name = "rand",
        .placements = &.{api.mod("rng")},
        .params = &.{
            .{ "upper_bound", "number" },
        },
        .ret = "number",
        .doc = "Returns a random integer in the range [0, upper_bound]",
        .f = root.define(&.{.number}, rand),
    },
    .{
        .name = "range",
        .placements = &.{api.mod("rng")},
        .params = &.{
            .{ "lower_bound", "number" },
            .{ "upper_bound", "number" },
        },
        .ret = "number",
        .doc = "Returns a random integer in the range [lower_bound, upper_bound]",
        .f = root.define(&.{ .number, .number }, randRange),
    },
    .{
        .name = "rand_float",
        .placements = &.{api.mod("rng")},
        .params = &.{},
        .ret = "number",
        .doc = "Returns a random float in the range [0, 1]",
        .f = root.define(&.{}, randFloat),
    },
    .{
        .name = "choice",
        .placements = &.{api.mod("rng")},
        .params = &.{
            .{ "input", "table" },
        },
        .ret = "any",
        .doc = "Returns a random element from a table (note: this function *ignores* key value pairs.)",
        .f = root.define(&.{.table}, choice),
    },
};

pub fn setSeed(args: []const Data, vm: *VM) !NativeResult {
    const raw_arg = args[0].asNum() orelse return .Err(vm, "err");
    const new_seed: u64 = @intFromFloat(raw_arg);

    prng = std.Random.DefaultPrng.init(new_seed);

    return .okData(Data.new.nil());
}

pub fn revertSeed(args: []const Data, vm: *VM) !NativeResult {
    _ = args;
    _ = vm;

    prng = null;

    return .okData(Data.new.nil());
}

pub fn rand(args: []const Data, vm: *VM) !NativeResult {
    const raw_arg = args[0].asNum() orelse return .Err(vm, "err");
    const upper_bound: isize = @intFromFloat(raw_arg);

    return .okData(Data.new.num(randomNumber(isize, vm, 0, upper_bound)));
}

pub fn randRange(args: []const Data, vm: *VM) !NativeResult {
    const raw_lower = args[0].asNum() orelse return .Err(vm, "err");
    const lower_bound: isize = @intFromFloat(raw_lower);

    const raw_upper = args[1].asNum() orelse return .Err(vm, "err");
    const upper_bound: isize = @intFromFloat(raw_upper);

    const result = if (lower_bound < upper_bound)
        randomNumber(isize, vm, lower_bound, upper_bound)
    else
        randomNumber(isize, vm, upper_bound, lower_bound);

    return .okData(Data.new.num(result));
}

pub fn randFloat(args: []const Data, vm: *VM) !NativeResult {
    _ = args;

    return .okData(Data.new.num(randomNumber(f64, vm, 0.0, 1.0)));
}

pub fn choice(args: []const Data, vm: *VM) !NativeResult {
    const tid = args[0].asTable().?;

    // gusic: I have no idea if this is the right error to use, please don't kill me if it isn't
    const table = vm.tables.get(tid) catch return error.RuntimeError;

    // gusic: We need to account for when a table has no array elements otherwise bad things happen.
    //        Perhaps this function should return (:some, T) or :none instead?
    if (table.array.items.len > 0) {
        const idx = randomNumber(usize, vm, 0, table.array.items.len - 1);

        return .okData(table.array.items[idx]);
    } else {
        return .okData(Data.new.nil());
    }
}

fn randomNumber(comptime T: type, vm: *VM, lowerBound: T, upperBound: T) T {
    if (prng) |*p| {
        var random = p.random();
        return switch (@typeInfo(T)) {
            .int => random.intRangeAtMost(T, lowerBound, upperBound),
            .float => random.float(T),
            else => unreachable,
        };
    }

    const time_seed: u64 = @intCast(std.Io.Clock.awake.now(vm.runtime.io).toNanoseconds());
    var temp_prng = std.Random.DefaultPrng.init(time_seed);
    var random = temp_prng.random();
    return switch (@typeInfo(T)) {
        .int => random.intRangeAtMost(T, lowerBound, upperBound),
        .float => return random.float(T),
        // gusic: At the moment `randomNumber` is only ever instantiated with `isize/usize` and f64`.
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

test "seed setting and resetting" {
    try testing.topTrue(
        \\ rng.set_seed(2226)
        \\ const x = rng.rand(10)
        \\
        \\ rng.set_seed(7)
        \\ const y = rng.rand(10)
        \\
        \\ x != y
    );
}
