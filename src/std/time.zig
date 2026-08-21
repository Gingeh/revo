pub const impls: []const api.Impl = &.{
    .{ .name = "now", .f = root.define(&.{}, now_ms) },
    .{ .name = "now_ns", .f = root.define(&.{}, now_ns) },
    .{ .name = "monotonic", .f = root.define(&.{}, monotonic_ms) },
    .{ .name = "monotonic_ns", .f = root.define(&.{}, monotonic_ns) },
    .{ .name = "sleep", .f = root.define(&.{.number}, root.sleep) },
};

fn now_ms(_: []const Data, vm: *VM) !NativeResult {
    const ts = std.Io.Clock.real.now(vm.runtime.io);
    return .{ .ok = Data.new.num(ts.toMilliseconds()) };
}

fn now_ns(_: []const Data, vm: *VM) !NativeResult {
    const ts = std.Io.Clock.real.now(vm.runtime.io);
    if (vm.runtime.time_wall_base == 0) vm.runtime.time_wall_base = ts.nanoseconds;
    return .{ .ok = Data.new.num(ts.nanoseconds - vm.runtime.time_wall_base) };
}

fn monotonic_ms(_: []const Data, vm: *VM) !NativeResult {
    const ts = std.Io.Clock.awake.now(vm.runtime.io);
    return .{ .ok = Data.new.num(ts.toMilliseconds()) };
}

fn monotonic_ns(_: []const Data, vm: *VM) !NativeResult {
    const ts = std.Io.Clock.awake.now(vm.runtime.io);
    if (vm.runtime.time_mono_base == 0) vm.runtime.time_mono_base = ts.nanoseconds;
    return .{ .ok = Data.new.num(ts.nanoseconds - vm.runtime.time_mono_base) };
}

test "time module works probably" {
    const testing = revo.lang.testing;

    try testing.topTrue("time.now() > 0");
    try testing.topTrue("time.monotonic() >= 0");
}

const std = @import("std");

const revo = @import("../root.zig");
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const NativeResult = root.NativeResult;
