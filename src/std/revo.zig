// for metaprogramming

pub const impls: []const api.Impl = &.{
    .{ .name = "eval", .f = root.define(&.{.string}, eval) },
    .{ .name = "dofile", .f = if (@import("build_options").is_freestanding) root.defineStub(&.{.string}) else root.define(&.{.string}, dofile) },
    .{ .name = "build", .f = root.define(&.{.string}, build) },
    .{ .name = "version", .f = root.define(&.{}, version) },
};

pub fn version(args: []const Data, vm: *VM) !HostResult {
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
pub fn eval(args: []const Data, vm: *VM) !HostResult {
    if (args.len != 1) return .errArity(args.len, 1);

    const source = switch (args[0].tag()) {
        .string => vm.stringValue(args[0].asString().?),
        else => return .errType(0, "string", typeof(args[0], vm)),
    };

    const source_name = "<eval>";
    const res = revo.module.runModule(vm, source_name, source, true) catch {
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

/// > dofile(path: string) -> !any
/// reads the file, evaluates it as a module, gives you back its' return value
/// like eval but the source comes from a file, relative paths resolve
/// against the current module's directory like `import`, then cwd
pub fn dofile(args: []const Data, vm: *VM) !HostResult {
    if (args.len != 1) return .errArity(args.len, 1);

    const path = switch (args[0].tag()) {
        .string => vm.stringValue(args[0].asString().?),
        else => return .errType(0, "string", typeof(args[0], vm)),
    };

    // import-style resolution: ./mod.rv means "next to the script", not
    // "next to the cwd"; raw path is the fallback for repl/-e runs
    const resolved: ?[]const u8 = revo.resolveImportFile(
        vm.runtime.io,
        vm.runtime.alloc,
        path,
        vm.module_dir,
        vm.project_root,
        vm.package_path.items,
    ) catch null;
    defer if (resolved) |p| vm.runtime.alloc.free(p);
    const real_path = resolved orelse path;

    const source = std.Io.Dir.cwd().readFileAlloc(
        vm.runtime.io,
        real_path,
        vm.runtime.alloc,
        .limited(fs.max_read_size),
    ) catch |err| {
        const msg = try vm.ownDataString(fs.mapIOError(err));
        return root.resultTuple(vm, .err, msg);
    };
    defer vm.runtime.alloc.free(source);

    const res = revo.module.runModule(vm, real_path, source, false) catch {
        return .other("dofile failed");
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
pub fn build(args: []const Data, vm: *VM) !HostResult {
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
const std = @import("std");
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const fs = @import("fs.zig");
const HostResult = root.HostResult;
const typeof = root.typeof;

test "revo.dofile returns the file's value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hi.rv", .data = "{x = 2}" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "hi.rv" });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\ const (_, res) = revo.dofile('{s}')
        \\ res.x
    , .{file_path});
    defer std.testing.allocator.free(source);

    try testing.topNumber(source, 2);
}

test "revo.dofile resolves relative paths against the module dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dep.rv", .data = "\"from-dep\"" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    try testing.topStringInDir(dir_path,
        \\ revo.dofile("./dep.rv")[1]
    , "from-dep");
}
