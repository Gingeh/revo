const std = @import("std");

const revo = @import("../root.zig");
const mem = revo.memory;
const meta = @import("meta.zig");

const Data = mem.Data;
const VM = revo.VM;
const testing = revo.lang.testing;

pub const api = @import("api.zig");

pub const root_impls: []const api.Impl = &.{
    .{ .name = "fmt", .f = defineVariadic(&[_]TypeSpec{.string}, fmt) },
    .{ .name = "len", .f = define(&[_]TypeSpec{.any}, len_) },
    .{ .name = "inspect", .f = define(&[_]TypeSpec{.any}, inspect) },
    .{ .name = "get_metatable", .f = define(&[_]TypeSpec{.any}, meta.get_metatable_) },
    .{ .name = "set_metatable", .f = define(&[_]TypeSpec{ .any, .any }, meta.set_metatable_) },
    .{ .name = "type", .f = define(&[_]TypeSpec{.any}, typeof_) },
    .{ .name = "typeof", .f = define(&[_]TypeSpec{.any}, typeof_) },
    .{ .name = "expect", .f = define(&[_]TypeSpec{.any}, expect) },
    .{ .name = "expect_eq", .f = define(&[_]TypeSpec{ .any, .any }, expect_eq) },
    .{ .name = "assert", .f = define(&[_]TypeSpec{.any}, assert_) },
    .{ .name = "assert_eq", .f = define(&[_]TypeSpec{ .any, .any }, assert_eq) },
    .{ .name = "set_debug", .f = define(&[_]TypeSpec{.table}, meta.set_debug) },
    .{ .name = "debug", .f = define(&[_]TypeSpec{}, debug_) },
    .{ .name = "unwrap", .f = define(&[_]TypeSpec{.tuple}, try_) },
    .{ .name = "chan", .f = defineVariadic(&[_]TypeSpec{}, chan_new) },
    .{ .name = "send", .f = define(&[_]TypeSpec{ .tuple, .any }, chan_send) },
    .{ .name = "recv", .f = define(&[_]TypeSpec{.tuple}, chan_recv) },
    .{ .name = "sleep", .f = define(&[_]TypeSpec{.number}, sleep) },
    .{ .name = "panic", .f = defineVariadic(&[_]TypeSpec{}, panic_) },
    .{ .name = "print", .f = defineVariadic(&[_]TypeSpec{}, print) },
    .{ .name = "gensym", .f = define(&[_]TypeSpec{}, gensym) },
};

pub const os_impls: []const api.Impl = &.{
    .{ .name = "input", .f = if (revo.is_freestanding) defineStubVariadic(&[_]TypeSpec{}) else defineVariadic(&[_]TypeSpec{}, input) },
    .{ .name = "cwd", .f = if (revo.is_freestanding) defineStub(&[_]TypeSpec{}) else define(&[_]TypeSpec{}, cwd) },
    .{ .name = "exit", .f = if (revo.is_freestanding) defineStub(&[_]TypeSpec{.number}) else define(&[_]TypeSpec{.number}, exit) },
    .{ .name = "system", .f = if (revo.is_freestanding) defineStub(&[_]TypeSpec{.table}) else define(&[_]TypeSpec{.table}, system_) },
    .{ .name = "import", .f = if (revo.is_freestanding) defineStub(&[_]TypeSpec{.string}) else define(&[_]TypeSpec{.string}, import) },
    .{ .name = "__internal_dotest", .f = if (revo.is_freestanding) defineStub(&[_]TypeSpec{ .string, .function }) else define(&[_]TypeSpec{ .string, .function }, dotest) },
    .{ .name = "__internal_dosuite", .f = if (revo.is_freestanding) defineStub(&[_]TypeSpec{ .string, .function }) else define(&[_]TypeSpec{ .string, .function }, dosuite) },
};

pub fn register_stdlib(vm: *revo.VM) !void {
    vm.loaded_specs = try api.loadAllSpecs(vm.runtime.alloc);
    const argv_id = try vm.tables.create();
    const argv = try vm.tables.get(argv_id);
    for (vm.runtime.argv) |arg| {
        try argv.push(try vm.ownDataString(arg));
    }
    const argv_val = Data.new.table(argv_id);
    try vm.globals.put(try vm.internAtom("argv"), argv_val);
    try vm.stdlib_globals.put(try vm.internAtom("argv"), argv_val);

    const all = api.full_specs;

    try api.registerAll(vm, all, mtPrototype);

    try attachMathPi(vm);
    try typeUtils(vm);
}

fn attachMathPi(vm: *revo.VM) !void {
    if (vm.globals.get(try vm.internAtom("math"))) |t| {
        if (t.asTable()) |table_id| {
            const table = try vm.tables.get(table_id);
            try table.putRawAtom(try vm.internAtom("pi"), Data.new.num(std.math.pi), vm);
        }
    }
}

fn mtPrototype(target: TypeSpec, vm: *revo.VM) !Data {
    return switch (target) {
        .number => Data.new.num(0),
        .string => try vm.ownDataString(""),
        .tuple => Data.new.tuple(std.math.maxInt(usize)),
        .table => Data.new.table(std.math.maxInt(usize)),
        else => return error.UnsupportedTarget,
    };
}

pub const NativeFn = *const fn (args: []const Data, vm: *VM) anyerror!NativeResult;
pub const NativeFunc = struct {
    name: []const u8 = "",
    arity: usize,
    variadic: bool = false,
    param_types: []const TypeSpec,
    ret_type: TypeSpec = .any,
    func: NativeFn,
};

pub fn define(
    comptime types: []const TypeSpec,
    impl: NativeFn,
) NativeFunc {
    return .{
        .arity = types.len,
        .param_types = types,
        .func = impl,
    };
}

pub fn defineVariadic(
    comptime types: []const TypeSpec,
    impl: NativeFn,
) NativeFunc {
    return .{
        .arity = types.len,
        .variadic = true,
        .param_types = types,
        .func = impl,
    };
}

pub const ResultTag = enum { ok, err };

pub const TypeSpec = union(enum) {
    integer,
    float,
    number,
    string,
    atom,
    function,
    table,
    tuple,
    bool,
    any,

    pub fn matches(self: TypeSpec, data: Data) bool {
        return switch (self) {
            .any => true,
            .number, .integer, .float => data.isNumber(),
            .bool => if (data.asAtom()) |a| isBoolAtom(a) else false,
            .string => data.isString(),
            .atom => data.isAtom(),
            .function => data.isFunction(),
            .table => data.isTable(),
            .tuple => data.isTuple(),
        };
    }
};

/// type name -> TypeSpec, for parsing sig heads (`tuple:len` -> .tuple)
pub fn typeFromName(name: []const u8) ?TypeSpec {
    const tbl = std.StaticStringMap(TypeSpec).initComptime(.{
        .{ "int", .integer },
        .{ "float", .float },
        .{ "number", .number },
        .{ "string", .string },
        .{ "atom", .atom },
        .{ "function", .function },
        .{ "table", .table },
        .{ "tuple", .tuple },
        .{ "bool", .bool },
        .{ "any", .any },
    });
    return tbl.get(name);
}

/// lookup `key` in the module table named `name`; null when the module
/// or key is absent. untyped method receivers fall back here via the
/// type metatable's `__index` chain
fn isBoolAtom(atom: mem.AtomID) bool {
    const true_id = revo.core_atoms.atomId(.true);
    const false_id = revo.core_atoms.atomId(.false);
    return atom == true_id or atom == false_id;
}

/// converts a number to an integer of type T; null when the value is not a
/// finite integral number representable in T
pub const numToInt = revo.vm.memory.numToInt;

pub fn resultTuple(vm: *VM, comptime tag: ResultTag, value: Data) !NativeResult {
    const tag_atom = try resultTag(vm, tag);
    const items = [_]Data{
        Data.new.atom(tag_atom),
        value,
    };
    return .okData(Data.new.tuple(try vm.tuples.create(&items)));
}

pub fn okAtom(vm: *VM) NativeResult {
    _ = vm;
    return .{ .ok = revo.Data.new.core(.ok) };
}

pub fn resultTag(vm: *VM, comptime tag: ResultTag) !mem.AtomID {
    _ = vm;
    return switch (tag) {
        .ok => revo.core_atoms.atomId(.ok),
        .err => revo.core_atoms.atomId(.err),
    };
}

pub inline fn boolData(value: bool) Data {
    return if (value) revo.Data.new.core(.true) else revo.Data.new.core(.false);
}

/// > fmt(format: string, args: any...) -> string
/// format string with %v, %d, %? specifiers
/// %v: display value, %d: as number, %?: debug repr
///     fmt("hello %v", "world")
///     fmt("val: %v, num: %d", "x", 42)
pub fn fmt(args: []const Data, vm: *VM) !NativeResult {
    if (args.len == 0) return .errArity(0, 1);
    const format = vm.stringValue(args[0].asString().?);

    var result = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer result.deinit();

    var arg_idx: usize = 1;
    var i: usize = 0;

    while (i < format.len) {
        if (i + 1 < format.len and format[i] == '%') {
            switch (format[i + 1]) {
                '%' => {
                    try result.writer.writeByte('%');
                    i += 2;
                },
                'v' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    try append_data(&result.writer, args[arg_idx], vm, .display);
                    arg_idx += 1;
                    i += 2;
                },
                's' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    try append_data(&result.writer, args[arg_idx], vm, .display);
                    arg_idx += 1;
                    i += 2;
                },
                'd' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    try append_data(&result.writer, args[arg_idx], vm, .decimal);
                    arg_idx += 1;
                    i += 2;
                },
                '?' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    try append_data(&result.writer, args[arg_idx], vm, .debug);
                    arg_idx += 1;
                    i += 2;
                },
                'p' => {
                    if (arg_idx >= args.len) return .errArity(args.len, arg_idx + 1);
                    try append_data(&result.writer, args[arg_idx], vm, .pretty);
                    arg_idx += 1;
                    i += 2;
                },
                else => {
                    try result.writer.writeByte('%');
                    try result.writer.writeByte(format[i + 1]);
                    i += 2;
                },
            }
        } else {
            try result.writer.writeByte(format[i]);
            i += 1;
        }
    }

    const str = try result.toOwnedSlice();
    return .{ .ok = try vm.adoptDataString(str) };
}

test "fmt %d formats numbers" {
    try testing.topString(
        \\ fmt("%d", 42)
    , "42");
    try testing.topString(
        \\ fmt("%d", 1.5)
    , "1.5");
    try testing.topString(
        \\ fmt("%d", "10.5")
    , "10.5");
    try testing.topString(
        \\ fmt("%d", :hello)
    , "<un-number-able>");
}

test "fmt escapes literal percent" {
    try testing.topString(
        \\ fmt("100%%")
    , "100%");
}

test "fmt %? uses debug rendering" {
    try testing.topString(
        \\ const mt = {__debug = fn(self) "custom-debug"}
        \\ const t = set_metatable({}, mt)
        \\ fmt("%?", t)
    , "\"custom-debug\"");
}

test "fmt rendering is recursive" {
    try testing.topString(
        \\ const mt = {__display = fn(self) "shown", __debug = fn(self) "debug"}
        \\ const t = set_metatable({}, mt)
        \\ fmt("%v|%?|%d", {x = t}, {x = t}, {x = t})
    , "{ :x: shown, }|{ :x: \"debug\", }|{ <un-number-able>: { }, }");
}

/// internal, do not use pls
pub fn dotest(args: []const Data, vm: *VM) !NativeResult {
    const name = args[0].asString().?;
    const body = args[1].asFunction().?;
    var buf: [128]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(vm.runtime.io, &buf);
    defer w.flush() catch {};

    w.interface.print("* test \"{s}\"...\n", .{try vm.strings.get(name)}) catch {};
    w.flush() catch {};
    const res = vm.callFunction(Data.new.function(body), &[0]Data{}) catch |err| {
        const failure = vm.evalFailure(err);
        failure.render(vm.runtime.alloc, &w.interface, vm.currentDebugSource() orelse "") catch {
            try revo.pretty.printError(&w.interface, "hard-fail - {s}", .{@errorName(err)});
            return .{ .ok = Data.new.nil() };
        };
        return .{ .ok = Data.new.nil() };
    };
    // only react to err tuple
    // everything else is pass
    if (res.asTuple()) |tid| {
        const tpl = try vm.tuples.get(tid);
        if (tpl.items.len != 2)
            return .{ .ok = Data.new.nil() };
        const tag = tpl.items[0].asAtom() orelse return .{ .ok = Data.new.nil() };
        if (tag != revo.core_atoms.atomId(.err))
            return .{ .ok = Data.new.nil() };

        var obuf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer obuf.deinit();
        try append_data(&obuf.writer, tpl.items[1], vm, .debug);

        try revo.pretty.printError(&w.interface, "fail - {s}", .{obuf.written()});
    }
    return .{ .ok = Data.new.nil() };
}

/// internal, pls dont use. runs a test suite
pub fn dosuite(args: []const Data, vm: *VM) !NativeResult {
    const body = args[1].asFunction().?;
    var sbuf: [128]u8 = undefined;
    var sw = std.Io.File.stdout().writerStreaming(vm.runtime.io, &sbuf);
    defer sw.flush() catch {};
    _ = vm.callFunction(Data.new.function(body), &[0]Data{}) catch |err| {
        const failure = vm.evalFailure(err);
        var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
        defer buf.deinit();
        failure.render(vm.runtime.alloc, &buf.writer, vm.currentDebugSource() orelse "") catch {
            sw.interface.print("* suite hard-failed: \"{s}\"\n", .{@errorName(err)}) catch {};
            return .okCa(.nil);
        };
        sw.interface.print("{s}\n", .{buf.written()}) catch {};
    };

    return .okCa(.nil);
}

pub fn debug_(args: []const Data, vm: *VM) !NativeResult {
    _ = args;

    const out_id = try vm.tables.create();
    const out = try vm.tables.get(out_id);

    const flags_id = try vm.tables.create();
    const flags = try vm.tables.get(flags_id);
    try flags.putRawAtom(try vm.internAtom("dump"), Data.new.boolean(vm.debug.dump), vm);
    try flags.putRawAtom(try vm.internAtom("trace"), Data.new.boolean(vm.debug.trace), vm);
    try flags.putRawAtom(try vm.internAtom("instr"), Data.new.boolean(vm.debug.each_instr), vm);
    try flags.putRawAtom(try vm.internAtom("stack"), Data.new.boolean(vm.debug.each_stack), vm);
    try out.putRawAtom(try vm.internAtom("flags"), Data.new.table(flags_id), vm);

    const fiber = vm.currentFiber();
    try out.putRawAtom(try vm.internAtom("fiber_id"), Data.new.num(fiber.id), vm);
    try out.putRawAtom(try vm.internAtom("pc"), Data.new.num(fiber.pc), vm);
    try out.putRawAtom(try vm.internAtom("stack_depth"), Data.new.num(fiber.registers_len), vm);
    try out.putRawAtom(try vm.internAtom("frame_depth"), Data.new.num(fiber.frames.items.len), vm);
    try out.putRawAtom(try vm.internAtom("program_len"), Data.new.num(fiber.program.len), vm);

    if (vm.currentDebugInfo()) |info| {
        try out.putRawAtom(try vm.internAtom("has_debug_info"), Data.new.boolean(true), vm);
        try out.putRawAtom(try vm.internAtom("source_name"), try vm.ownDataString(info.source_name), vm);
        try out.putRawAtom(try vm.internAtom("source"), try vm.ownDataString(info.source), vm);
        try out.putRawAtom(try vm.internAtom("span_count"), Data.new.num(info.spans.len), vm);
    } else {
        try out.putRawAtom(try vm.internAtom("has_debug_info"), Data.new.boolean(false), vm);
        try out.putRawAtom(try vm.internAtom("source_name"), Data.new.nil(), vm);
        try out.putRawAtom(try vm.internAtom("source"), Data.new.nil(), vm);
        try out.putRawAtom(try vm.internAtom("span_count"), Data.new.num(0), vm);
    }

    try out.putRaw(
        Data.new.atom(try vm.internAtom("panic_message")),
        if (vm.panic_message) |msg| try vm.ownDataString(msg) else Data.new.nil(),
        vm,
    );
    try out.putRaw(
        Data.new.atom(try vm.internAtom("runtime_message")),
        if (vm.runtime_message) |msg| try vm.ownDataString(msg) else Data.new.nil(),
        vm,
    );

    return .okData(Data.new.table(out_id));
}

/// > len(arg0: any) -> number|nil
/// returns length of string or table
/// for strings: byte length, for tables: array + map parts
/// uses __len metamethod if available
pub fn len_(args: []const Data, vm: *VM) !NativeResult {
    const mm = try vm.getMetamethodByAtom(args[0], revo.core_atoms.atomId(.__len));
    if (mm) |m| return callUnaryMetamethod(m, args[0], vm);
    return switch (args[0].tag()) {
        .string => .okData(Data.new.num(vm.stringValue(args[0].asString().?).len)),
        .table => .okData(Data.new.num((try vm.tables.get(args[0].asTable().?)).count())),
        .tuple => .okData(Data.new.num((try vm.tuples.get(args[0].asTuple().?)).items.len)),
        else => .errType(1, "string, table, or tuple", typeof(args[0], vm)),
    };
}

/// > inspect(any) -> any
/// prints one value and returns it back
pub fn inspect(args: []const Data, vm: *VM) !NativeResult {
    if (comptime !revo.is_freestanding)
        _ = try print(args, vm);
    return .okData(args[0]);
}

pub fn typeof(d: Data, vm: *VM) []const u8 {
    if (d.asStructVal()) |instance_id| {
        const instance = vm.struct_instances.get(instance_id) catch return "struct";
        const desc = vm.struct_types.getType(instance.type_id) orelse return "struct";
        return desc.name;
    }
    return switch (d.tag()) {
        .atom => if (d.asAtom().? == revo.core_atoms.atomId(.nil)) "nil" else "atom",
        .struct_val => "struct",
        .struct_type => "type",
        else => |e| @tagName(e),
    };
}

/// > typeof(arg0: any) -> atom|type
/// returns type of arg0 as atom
/// possible values: nil, number, string, atom, function, table, tuple,
/// type, foreign; struct values return the struct type itself, which is callable
pub fn typeof_(args: []const Data, vm: *VM) !NativeResult {
    if (args[0].asStructVal()) |instance_id| {
        const instance = vm.struct_instances.get(instance_id) catch
            return .okData(Data.new.atom(try vm.internAtom("struct")));
        return .okData(Data.new.structType(instance.type_id));
    }
    return .okData(Data.new.atom(try vm.internAtom(typeof(args[0], vm))));
}

/// > string(arg0: any) -> string
/// converts value to string representation
/// uses __tostring or __display metamethod if available
pub fn string_(args: []const Data, vm: *VM) !NativeResult {
    const mm = try vm.getMetamethodByAtom(args[0], revo.core_atoms.__tostring.atomId());
    if (mm) |m| return callUnaryMetamethod(m, args[0], vm);
    var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer buf.deinit();
    try args[0].write(&buf.writer, vm, .display);
    const str = try buf.toOwnedSlice();
    return .{ .ok = try vm.adoptDataString(str) };
}

/// > unwrap(result: tuple) -> any
/// unwraps result tuple, panics if not :ok
pub fn try_(args: []const Data, vm: *VM) !NativeResult {
    const t_id = args[0].asTuple() orelse return .errType(0, "tuple", typeof(args[0], vm));
    const tuple = try vm.tuples.get(t_id);
    if (tuple.items.len < 2) return .errType(0, "tuple with at least 2 elements", "tuple with less than 2 elements");
    const tag = tuple.items[0];
    const atom = tag.asAtom() orelse return .errType(0, "tuple starting with atom", "tuple starting with non-atom");
    const ok_id = revo.core_atoms.atomId(.ok);
    if (atom != ok_id) return panic_(&[1]Data{tuple.items[1]}, vm);
    return .{ .ok = tuple.items[1] };
}

/// > tuple:unwrap_err() -> any
/// extracts error from result tuple, panics if not :err
pub fn unwrap_err_(args: []const Data, vm: *VM) !NativeResult {
    const result = args[0];
    const result_tid = result.asTuple() orelse return .errType(0, "tuple", typeof(result, vm));
    const tuple = try vm.tuples.get(result_tid);
    if (tuple.items.len < 2) return .errType(0, "tuple with at least 2 elements", "empty tuple");

    const tag = tuple.items[0];
    if (tag.asAtom() == null) return .errType(0, "tuple starting with atom", "tuple starting with non-atom");

    const err_tag = revo.core_atoms.atomId(.err);
    if (tag.asAtom().? == err_tag) {
        return .{ .ok = tuple.items[1] };
    }

    return panic_(&[1]Data{revo.Data.new.core(.err)}, vm);
}

fn as_stack_index(value: Data) ?usize {
    const num = value.asNum() orelse return null;
    // SAFETY: asIndex returns null for non-integer/out-of-range numbers
    return revo.asIndex(num) catch null;
}

/// > chan(capacity?: number) -> tuple
/// creates a new channel with optional buffer size
///     chan()        # unbuffered
///     chan(5)       # buffer of 5
pub fn chan_new(args: []const Data, vm: *VM) !NativeResult {
    const cap: usize = if (args.len == 0)
        0
    else if (args.len == 1)
        as_stack_index(args[0]) orelse return .errType(0, "number", typeof(args[0], vm))
    else
        return .errArity(args.len, 0);

    const channel_id = try vm.sched.channelCreate(&vm.tables, cap);
    const res = try vm.tuples.create(&[2]Data{
        Data.new.atom(revo.core_atoms.chan.atomId()),
        Data.new.num(channel_id),
    });
    return .okData(Data.new.tuple(res));
}

/// validate `args[0]` as a `:chan, id` tuple and extract the channel id
fn chanIdOf(args: []const Data, vm: *VM) NativeResult {
    const tuple_id = args[0].asTuple() orelse return .errType(0, "tuple", typeof(args[0], vm));
    const t = vm.tuples.get(tuple_id) catch return .errType(0, "chan tuple", "tuple");
    if (t.items.len < 2) return .errType(0, "chan tuple", "tuple");
    const chan_atom = revo.core_atoms.chan.atomId();
    if (t.items[0].asAtom() != chan_atom)
        return .errType(0, "chan tuple", "tuple");
    const chan_id = t.items[1].asNum() orelse return .errType(0, "chan tuple", "tuple");
    return .okData(Data.new.num(@as(revo.vm.ChannelID, @intFromFloat(chan_id))));
}

/// > send(chan: tuple, value: any) -> atom
/// sends value to channel
pub fn chan_send(args: []const Data, vm: *VM) !NativeResult {
    const cid = switch (chanIdOf(args, vm)) {
        .ok => |d| @as(revo.vm.ChannelID, @intFromFloat(d.asNum().?)),
        else => |r| return r,
    };
    try vm.sched.channelSend(cid, args[1]);
    return okAtom(vm);
}

/// > recv(chan: tuple) -> any
/// receives value from channel, parks if empty
pub fn chan_recv(args: []const Data, vm: *VM) !NativeResult {
    const cid = switch (chanIdOf(args, vm)) {
        .ok => |d| @as(revo.vm.ChannelID, @intFromFloat(d.asNum().?)),
        else => |r| return r,
    };
    const recv_result = try vm.sched.channelRecv(cid);
    if (recv_result) |value| return .{ .ok = value };
    return .parked();
}

/// converts value to number
/// accepts number (passthrough) or string (parsed)
/// errors on other types
pub fn number_(args: []const Data, vm: *VM) !NativeResult {
    if (args[0].isNumber()) return .Ok(vm, args[0]);
    if (args[0].asString()) |id| {
        const parsed = try std.fmt.parseFloat(f64, vm.stringValue(id));
        return .Ok(vm, Data.new.num(parsed));
    }
    return .errType(0, "number, string", typeof(args[0], vm));
}

/// > expect(what: any) -> !what
/// used in tests
///
/// return the value back if truthy, otherwise (:err, :AssertionFailed)
pub fn expect(args: []const Data, vm: *VM) !NativeResult {
    if (revo.isFalse(args[0])) return .Err(vm, "ExpectFailed");
    return .Ok(vm, args[0]);
}

/// > expect_eq(what: any) -> !:ok
/// panics if the value is falsy
pub fn expect_eq(args: []const Data, vm: *VM) !NativeResult {
    if (vm.compare(args[0], args[1]) != .eq) {
        return .Err(vm, "NotEqual");
    }
    return .Ok(vm, args[0]);
}

/// > assert(what: any) -> what
/// panics if the value is falsy
pub fn assert_(args: []const Data, vm: *VM) !NativeResult {
    if (revo.isFalse(args[0])) return panic_(&[1]Data{args[0]}, vm);
    return .okData(args[0]);
}

/// > assert(what: any) -> what
/// panics if the value is falsy
pub fn assert_eq(args: []const Data, vm: *VM) !NativeResult {
    if (vm.compare(args[0], args[1]) != .eq) {
        return .other("neq");
    }
    return .okData(args[0]);
}

/// > print(args: any...) -> atom
/// prints values to stdout with space separator
///     print("hello", 42, "world")
pub fn print(args: []const Data, vm: *VM) !NativeResult {
    var pbuf: [256]u8 = undefined;
    const stdout_file = if (comptime revo.is_freestanding)
        std.Io.File{ .handle = if (@import("builtin").target.os.tag == .freestanding) @as(void, {}) else @as(std.posix.fd_t, -1), .flags = .{ .nonblocking = false } }
    else
        std.Io.File.stdout();
    var pw = stdout_file.writerStreaming(vm.runtime.io, &pbuf);
    defer _ = pw.flush() catch {};
    if (args.len == 0) {
        _ = try pw.interface.writeAll("\n");
        try pw.flush();
        return okAtom(vm);
    }
    for (args, 0..) |a, idx| {
        if (idx != 0) _ = try pw.interface.writeAll(" ");
        try append_data(&pw.interface, a, vm, .display);
    }
    try pw.interface.print("\n", .{});
    try pw.flush();
    return .{ .ok = revo.Data.new.core(.ok) };
}

/// > panic(args: any...) -> error
/// panics with given message
///     panic("something went wrong")
pub fn panic_(args: []const Data, vm: *VM) !NativeResult {
    var buf = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer buf.deinit();
    if (args.len == 0) {
        try buf.writer.writeAll("panic");
    } else {
        for (args, 0..) |arg, idx| {
            if (idx != 0) try buf.writer.writeAll(" ");
            try append_data(&buf.writer, arg, vm, .display);
        }
    }
    try vm.setPanicMessage(buf.written());
    return .other("panic");
}

pub fn system_(tbl: []const Data, vm: *VM) !NativeResult {
    const args = tbl[0].asTable().?;
    const table = try vm.tables.get(args);

    var argv = try vm.runtime.alloc.alloc([]const u8, table.array.items.len);
    defer vm.runtime.alloc.free(argv);
    defer for (argv) |arg| vm.runtime.alloc.free(arg);

    for (table.array.items, 0..) |arg, i|
        argv[i] = try vm.runtime.alloc.dupe(u8, vm.stringValue(arg.asString().?));

    var proc = try std.process.spawn(vm.runtime.io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer proc.kill(vm.runtime.io);

    // drain stdout and stderr concurrently: reading one pipe to EOF while the
    // child blocks writing the other (full pipe buffer) would deadlock
    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(vm.runtime.alloc, vm.runtime.io, mr_buf.toStreams(), &.{ proc.stdout.?, proc.stderr.? });
    defer multi_reader.deinit();

    try multi_reader.fillRemaining(.none);

    _ = try proc.wait(vm.runtime.io);

    const so = try vm.adoptDataString(try multi_reader.toOwnedSlice(0));
    const se = try vm.adoptDataString(try multi_reader.toOwnedSlice(1));
    return .Ok(vm, Data.new.tuple(try vm.tuples.create(&[2]Data{ so, se })));
}

pub fn input(args: []const Data, vm: *VM) !NativeResult {
    var read_eof = false;
    var delim: u8 = '\n';

    if (args.len > 1) return .errArity(args.len, 1);
    if (args.len == 1) {
        const t = args[0].asTable() orelse return .errType(0, "table", typeof(args[0], vm));
        const table = try vm.tables.get(t);

        if (try table.get(Data.new.atom(revo.core_atoms.delimiter.atomId()), vm)) |v| {
            if (v.asAtom()) |atom| {
                const eof_id = revo.core_atoms.eof.atomId();
                if (atom == revo.core_atoms.nil.atomId() or atom == eof_id)
                    read_eof = true
                else
                    return .errType(0, "string, :nil, or :eof", typeof(v, vm));
            } else if (v.asString()) |id| {
                const s = vm.stringValue(id);
                if (s.len == 1) {
                    delim = s[0];
                } else {
                    return .errType(0, "single char string", "string");
                }
            } else {
                return .errType(0, "string, :nil, or :eof", typeof(v, vm));
            }
        }
    }

    const file = std.Io.File.stdin();
    var result = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 128);
    defer result.deinit(vm.runtime.alloc);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.readStreaming(vm.runtime.io, &.{buf[0..]}) catch |err| switch (err) {
            error.EndOfStream => {
                if (result.items.len > 0)
                    return resultTuple(vm, .ok, try vm.adoptDataString(try result.toOwnedSlice(vm.runtime.alloc)));
                return .Err(vm, "EndOfStream");
            },
            else => |e| return e,
        };
        if (!read_eof) {
            if (std.mem.indexOfScalar(u8, buf[0..n], delim)) |di| {
                try result.appendSlice(vm.runtime.alloc, buf[0..di]);
                return resultTuple(vm, .ok, try vm.adoptDataString(try result.toOwnedSlice(vm.runtime.alloc)));
            }
        }
        try result.appendSlice(vm.runtime.alloc, buf[0..n]);
    }
}

var gensym_counter: u64 = 0;

pub fn gensym(args: []const Data, vm: *VM) !NativeResult {
    _ = args;
    const n = gensym_counter;
    gensym_counter += 1;
    const name = try std.fmt.allocPrint(vm.runtime.alloc, "__gensym_{d}", .{n});
    defer vm.runtime.alloc.free(name);
    return .{ .ok = try vm.ownDataStringNoDedup(name) };
}

test "gensym produces different values on each call" {
    try revo.lang.testing.topAtom(
        \\ const a = gensym()
        \\ const b = gensym()
        \\ a != b
    , "true");
}

pub fn cwd(args: []const Data, vm: *VM) !NativeResult {
    _ = args;
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(vm.runtime.io, ".", vm.runtime.alloc);
    defer vm.runtime.alloc.free(cwd_path);
    return .{ .ok = try vm.ownDataString(cwd_path) };
}

pub fn exit(args: []const Data, vm: *VM) noreturn {
    _ = vm;
    const n = args[0].asNum().?;
    const status: u8 = numToInt(u8, n) orelse 255;
    std.process.exit(status);
}

pub fn import(args: []const Data, vm: *VM) !NativeResult {
    if (args.len != 1) return .{ .err = .{ .wrong_arity = .{ .got = args.len, .expected = 1 } } };

    const raw_path = args[0].asString() orelse return .{ .err = .{ .type_error = .{
        .arg = 0,
        .expected = "string",
        .got = typeof(args[0], vm),
    } } };
    const raw_path_s = vm.stringValue(raw_path);

    const resolved_path = try revo.resolveImportFile(
        vm.runtime.io,
        vm.runtime.alloc,
        raw_path_s,
        vm.module_dir,
        vm.project_root,
        vm.package_path.items,
    ) orelse return .other("module not found!");

    defer vm.runtime.alloc.free(resolved_path);
    if (std.mem.endsWith(u8, resolved_path, ".d.rv")) {
        // ambient declaration file: compile-time only, no runtime side effects
        const t_id = try vm.tables.create();
        return .okData(Data.new.table(t_id));
    }
    if (std.mem.endsWith(u8, resolved_path, ".so") or std.mem.endsWith(u8, resolved_path, ".dylib")) {
        // a sibling `lib.d.rv` manifest owns the interface: every binding
        // lands in this module's table so manifest-typed calls resolve
        const mods = try revo.ffi.loadC(vm, resolved_path);
        defer vm.runtime.alloc.free(mods);
        const t_id = try vm.tables.create();
        const tbl = try vm.tables.get(t_id);

        for (mods) |c_fn| {
            const fn_id = try vm.functions.create(.{ .c_function = c_fn });
            try tbl.putRaw(
                Data.new.atom(try vm.internAtom(c_fn.name)),
                Data.new.function(fn_id),
                vm,
            );
        }
        return .okData(Data.new.table(t_id));
    }

    const current_stamp = try vm.moduleStamp(resolved_path);
    if (vm.module_cache.get(resolved_path)) |cached| {
        if (std.meta.eql(cached.stamp, current_stamp)) {
            return .{ .ok = cached.result };
        }
        _ = vm.invalidateModuleCache(resolved_path);
    }
    for (vm.loading_stack.items) |loading| {
        if (std.mem.eql(u8, loading, resolved_path)) return NativeResult.other("cyclic import detected");
    }

    const source = try std.Io.Dir.cwd().readFileAlloc(
        vm.runtime.io,
        resolved_path,
        vm.runtime.alloc,
        std.Io.Limit.unlimited,
    );
    defer vm.runtime.alloc.free(source);

    const cache_key = try vm.runtime.alloc.dupe(u8, resolved_path);
    errdefer vm.runtime.alloc.free(cache_key);

    try vm.loading_stack.append(vm.runtime.alloc, cache_key);
    const result = vm.runImportedModule(resolved_path, source) catch |err| {
        _ = vm.loading_stack.pop();
        if (err != error.OutOfMemory) vm.runtime.alloc.free(cache_key);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => NativeResult.other("module error"),
        };
    };
    _ = vm.loading_stack.pop();

    try vm.module_cache.put(cache_key, .{ .result = result, .stamp = current_stamp });
    return .{ .ok = result };
}

fn append_data(writer: *std.Io.Writer, val: Data, vm: *VM, mode: Data.RenderMode) !void {
    try val.write(writer, vm, mode);
}

pub fn callUnaryMetamethod(mm: Data, val: Data, vm: *VM) NativeResult {
    if (!mm.isFunction()) return .errType(0, "function", typeof(mm, vm));
    const result = vm.callFunction(mm, &.{val}) catch |err| {
        return .other(@errorName(err));
    };
    return .{ .ok = result };
}

/// > sleep(ms: number) -> parked
/// sleeps current fiber for given milliseconds
/// parks fiber instead of blocking
pub fn sleep(args: []const Data, vm: *VM) !NativeResult {
    const n = args[0].asNum() orelse return .errType(0, "number", typeof(args[0], vm));
    const ms: u64 = numToInt(u64, n) orelse return .errType(0, "non-negative integer", typeof(args[0], vm));
    try vm.schedParkCurrentForSleepMS(ms);
    return .parked();
}

pub const NativeErrPayload = union(enum) {
    wrong_arity: struct { got: usize, expected: usize },
    type_error: struct { arg: ?usize, expected: []const u8, got: []const u8 },
    native_error: revo.vm.NativeError,
    parked: void,
    other: []const u8,
};

pub const NativeResult = union(enum) {
    ok: Data,
    err: NativeErrPayload,

    pub fn parked() NativeResult {
        return .{ .err = .{ .parked = {} } };
    }
    pub fn okBool(b: bool) NativeResult {
        return .{ .ok = Data.new.boolean(b) };
    }
    pub fn errArity(got: usize, expected: usize) NativeResult {
        return .{ .err = .{ .wrong_arity = .{ .got = got, .expected = expected } } };
    }
    pub fn errType(arg: usize, expected: []const u8, got: []const u8) NativeResult {
        return .{ .err = .{ .type_error = .{ .arg = arg, .expected = expected, .got = got } } };
    }
    pub fn okData(d: Data) NativeResult {
        return .{ .ok = d };
    }
    pub fn okCa(a: revo.core_atoms) NativeResult {
        return .{ .ok = Data.new.atom(@intFromEnum(a)) };
    }
    pub fn other(message: []const u8) NativeResult {
        return .{ .err = .{ .other = message } };
    }
    pub fn panic() NativeResult {
        return .{ .err = .{ .other = "panic" } };
    }

    pub fn Ok(vm: *VM, value: Data) !NativeResult {
        return resultTuple(vm, .ok, value);
    }

    pub fn Err(vm: *VM, err_atom: []const u8) !NativeResult {
        const tag = try vm.internAtom(err_atom);
        return resultTuple(vm, .err, Data.new.atom(tag));
    }
};

pub fn wasm_stub(_: []const Data, _: *VM) anyerror!NativeResult {
    return NativeResult.other("function unavailable on this platform");
}

pub fn defineStub(comptime types: []const TypeSpec) NativeFunc {
    return .{
        .arity = types.len,
        .variadic = false,
        .param_types = types,
        .func = wasm_stub,
    };
}

pub fn defineStubVariadic(comptime types: []const TypeSpec) NativeFunc {
    return .{
        .arity = types.len,
        .variadic = true,
        .param_types = types,
        .func = wasm_stub,
    };
}

// type utils
pub fn typeUtils(vm: *VM) !void {
    inline for (@typeInfo(revo.memory.Type).@"enum".fields) |field| {
        const func = struct {
            fn is_of(args: []const Data, _: *VM) !NativeResult {
                for (args) |arg| {
                    if (arg.tag() != @field(revo.memory.Type, field.name)) {
                        return .okBool(false);
                    }
                }
                return .okBool(true);
            }
        }.is_of;
        const id = try vm.functions.create(.{ .native = define(
            &[1]TypeSpec{.any},
            func,
        ) });
        const atom = try vm.internAtom(field.name ++ "?");
        const val = Data.new.function(id);
        try vm.globals.put(atom, val);
        try vm.stdlib_globals.put(atom, val);
    }
    const is_number = struct {
        fn num(args: []const Data, _: *VM) !NativeResult {
            for (args) |arg| {
                if (!arg.isNumber()) return .okBool(false);
            }
            return .okBool(true);
        }
    }.num;
    const id = try vm.functions.create(.{ .native = define(&[_]TypeSpec{.any}, is_number) });
    const atom = try vm.internAtom("number?");
    const val = Data.new.function(id);
    try vm.globals.put(atom, val);
    try vm.stdlib_globals.put(atom, val);
}

test "type predicates" {
    try testing.topTrue("number?(42)");
    try testing.topTrue("string?(\"hello\")");
    try testing.topTrue("table?({})");
    try testing.topTrue("atom?(:ok)");
    try testing.topTrue("function?(fn() 42)");

    try testing.topTrue("tuple?((1, 2))");
    try testing.topFalse("tuple?(42)");
    try testing.topTrue("struct Foo { x = 1 } struct_val?(Foo{})");
    try testing.topFalse("struct Foo { x = 1 } struct_val?(42)");
    try testing.topTrue("struct Foo { x = 1 } struct_type?(Foo)");
    try testing.topFalse("struct Foo { x = 1 } struct_type?(42)");
}

test "array methods" {
    try testing.topNumber("{1, 2, 3}:first()", 1);
    try testing.topNumber("{1, 2, 3}:last()", 3);
    try testing.topTrue("{1, 2, 3}:contains?(2)");
    try testing.topFalse("{1, 2, 3}:contains?(5)");
    try testing.topNumber("{1, 2, 3}:index_of(2)", 1);
    try testing.topNumber("iter.sum({1, 2, 3})", 6);
}

test "array sort" {
    try testing.topNumber("{3, 1, 2}:sort():first()", 1);
    try testing.topNumber("{3, 1, 2}:sort():last()", 3);
    try testing.topNumber("{1, 5, 3}:sort_by(fn(a, b) a > b):first()", 5);
}

test "array transform" {
    try testing.topNumber("{1, 2, 3}:reverse():first()", 3);
    try testing.topNumber("iter.sum({1, 2, 3}:unique())", 6);
    try testing.topNumber("iter.sum({1, 2, 1, 3, 2}:unique())", 6);
}

test "string table conversion" {
    try testing.topNumber("len(\"abc\":table())", 3);
    try testing.topNumber("\"a\":ascii()", 97);
    try testing.topNumber("\"Hello\":ascii()", 72);
}

test "array flatten" {
    try testing.topNumber("iter.sum({{1, 2}, {3, 4}}:flatten())", 10);
    try testing.topNumber("iter.sum({{1}, {2, 3}, {4}}:flatten())", 10);
}

test "stdlib json time and string modules are exposed" {
    try testing.topString("json.encode((\"a\", \"b\", \"c\")):unwrap()", "[\"a\",\"b\",\"c\"]");
    try testing.topNumber("json.decode(\"{{ \\\"a\\\" : 1}}\"):unwrap().a", 1);
    try testing.topTrue("time.now() > 0");
    try testing.topNumber("len(string.split(\"a,b\", \",\"))", 2);
}

test "len" {
    try testing.topNumber("len(\"hi\")", 2);
    try testing.topNumber("len(\"\")", 0);
    try testing.topNumber("len(\"abcde\")", 5);
    try testing.topNumber("len((1, 2, 3))", 3);
    try testing.topNumber("len((1,))", 1);
    try testing.topNumber("len({})", 0);
}

test "meatballs are distinct" {
    try testing.topString(
        \\ const a = set_metatable({}, {__tostring = fn(self) "foo"})
        \\ const b = set_metatable({}, {__tostring = fn(self) "bar"})
        \\ string(a)
    , "foo");

    try testing.topString(
        \\ const a = set_metatable(:true, {__tostring = fn(self) "foo"})
        \\ string(1 == 1)
    , "foo");
}

test "bullshit: metatable constructors closures and method chaining" {
    try testing.topNumber(
        \\ let Counter = set_metatable({}, {
        \\   new = fn(start) do
        \\     const state = {n = start}
        \\     set_metatable(state, {
        \\       inc = fn(s, step) do s.n = s.n + step s end,
        \\       value = fn(s) s.n
        \\     })
        \\   end
        \\ })
        \\ let a = Counter.new(10)
        \\ let b = Counter.new(1)
        \\ a:inc(5):inc(7)
        \\ b:inc(2)
        \\ a:value() * 10 + b:value()
    , 223);
}

test "natives register as functions" {
    try testing.topType("len", .function);
    try testing.topType("number", .table);
    try testing.topType("assert", .function);
    try testing.topTrue("assert(type(len) == :function)");
}

test "expect" {
    try testing.topAtom(
        \\ let r = expect(1 == 2)
        \\ r[0]
    , "err");

    try testing.topNumber(
        \\ expect(42)?
    , 42);
}
