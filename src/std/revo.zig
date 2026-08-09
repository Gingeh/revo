// for metaprogramming

pub const specs: []const api.FnSpec = &.{
    .{
        .name = "eval",
        .placements = &.{api.mod("revo")},
        .params = &.{
            .{ "code", "string" },
        },
        .ret = "!any/string",
        .doc =
        \\evaluates it as a module, gives you back its' return value
        \\you can treat it as a function's body
        ,
        .f = root.define(&.{.string}, eval),
    },
    .{
        .name = "build",
        .placements = &.{api.mod("revo")},
        .params = &.{
            .{ "code", "string" },
        },
        .ret = "!string",
        .doc =
        \\builds it as a module, gives you back its' bytecode in a string
        \\the string is only useful for writing to a file or executing
        ,
        .f = root.define(&.{.string}, build),
    },
    .{
        .name = "version",
        .placements = &.{api.mod("revo")},
        .params = &.{},
        .ret = "string",
        .doc =
        \\version of your revo installation, like "revo v1.2.3"
        ,
        .f = root.define(&.{}, version),
    },
};

pub fn version(args: []const Data, vm: *VM) !NativeResult {
    _ = args;
    const v = @import("build_options").version;

    return if (@import("builtin").mode == .Debug)
        .okData(try vm.ownDataString("revo #" ++ v))
    else
        .okData(try vm.ownDataString("revo v" ++ v));
}

/// > eval(code: string) -> !any
/// evaluates it as a module, gives you back its' return value
/// you can treat it as a function's body
pub fn eval(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 1) return .errArity(args.len, 1);

    const source = switch (args[0].tag()) {
        .string => vm.stringValue(args[0].asString().?),
        else => return .errType(0, "string", dataToString(args[0], vm)),
    };

    const source_name = "<eval>";
    const res = revo.module.runModuleReport(vm, source_name, source) catch {
        return .other("eval failed");
    };

    return switch (res) {
        .ok => root.resultTuple(vm, .ok, vm.currentFiber().result),
        .err => |err| {
            const err_str = try vm.ownDataString(revo.lang.diagnostic.firstError(err.report).?);
            return root.resultTuple(vm, .err, err_str);
        },
    };
}

/// > build(code: string) -> !any
/// builds it as a module, gives you back its' bytecode in a string
/// the string is only useful for writing to a file or executing
pub fn build(args: []const Data, vm: *VM) !NativeResult {
    const source = vm.stringValue(args[0].asString().?);

    const result = try revo.lang.build(vm, .{ .text = source, .name = "<anon>" }, .{});

    switch (result) {
        .ok => |artifact| {
            defer vm.runtime.alloc.free(artifact.instructions);
            defer vm.runtime.alloc.free(artifact.spans);

            const bc = try revo.bytecode.serialize(vm, artifact, vm.runtime.alloc);
            defer vm.runtime.alloc.free(bc);
            // super slow
            const sid = try vm.strings.own(bc);
            return root.resultTuple(vm, .ok, Data.new.str(sid));
        },
        .err => |err| switch (err) {
            .lower => |e| return root.resultTuple(vm, .err, try vm.ownDataString(revo.lang.diagnostic.firstError(e.report).?)),
            .expand => |e| return root.resultTuple(vm, .err, try vm.ownDataString(revo.lang.diagnostic.firstError(e.report).?)),
            .parse => |e| return root.resultTuple(vm, .err, try vm.ownDataString(revo.lang.diagnostic.firstError(e.report).?)),
            .semantic => |e| return root.resultTuple(vm, .err, try vm.ownDataString(revo.lang.diagnostic.firstError(e.report).?)),
        },
    }
}

test "native eval works" {
    try testing.topNumber(
        \\ const (_, res) = revo.eval("21*2")
        \\ res
    , 42);
}

test "revo.build compiles source" {
    try testing.topAtom(
        \\ revo.build("1 + 1")[0]
    , "ok");
}

const revo = @import("../root.zig");
const testing = revo.lang.testing;
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const NativeResult = root.NativeResult;
const dataToString = root.dataToString;
