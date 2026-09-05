const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const api = @import("api.zig");
const argparse = revo.argparse;

const Data = revo.Data;
const VM = revo.VM;
const mem = revo.vm.memory;
const HostResult = root.HostResult;

pub const impls: []const api.Impl = &.{
    .{ .name = "parse", .f = root.define(&.{ .function, .table }, parseFn) },
    .{ .name = "usage", .f = root.define(&.{.table}, usageFn) },
};

fn isTrue(d: Data) bool {
    if (d.asAtom()) |a| return a == revo.core_atoms.atomId(.true);
    return false;
}

fn tableStr(table: anytype, vm: *VM, id: mem.AtomID) ?[]const u8 {
    if (table.getRawAtom(id, vm)) |v| {
        if (v.asString()) |sid| return vm.stringValue(sid);
    }
    return null;
}

fn tableBool(table: anytype, vm: *VM, id: mem.AtomID) bool {
    if (table.getRawAtom(id, vm)) |v| return isTrue(v);
    return false;
}

// -- [builder methods] -------------------------------------------------------

fn builderFlagFn(args: []const Data, vm: *VM) !HostResult {
    return builderAddArgFn(args, vm, .boolean);
}

fn builderOptionFn(args: []const Data, vm: *VM) !HostResult {
    return builderAddArgFn(args, vm, .string);
}

fn builderPositionalFn(args: []const Data, vm: *VM) !HostResult {
    return builderAddArgFn(args, vm, .positional);
}

const ArgKind = enum { boolean, string, positional };

fn builderAddArgFn(args: []const Data, vm: *VM, kind: ArgKind) !HostResult {
    const name_atom = args[1].asAtom() orelse return .errType(1, "atom", root.typeof(args[1], vm));

    var short: ?u8 = null;
    var description: []const u8 = "";
    var terminal = false;
    var passthrough = false;

    if (args.len > 2 and args[2].isTable()) {
        const opts = try vm.tables.get(args[2].asTable().?);
        if (tableStr(opts, vm, try vm.internAtom("short"))) |s| {
            if (s.len > 0) short = s[0];
        }
        description = tableStr(opts, vm, try vm.internAtom("description")) orelse "";
        terminal = tableBool(opts, vm, try vm.internAtom("terminal"));
        passthrough = tableBool(opts, vm, try vm.internAtom("passthrough"));
    }

    const builder_id = args[0].asTable() orelse return .errType(0, "table", root.typeof(args[0], vm));
    const builder = try vm.tables.get(builder_id);
    const args_list_ptr = builder.getRawAtom(try vm.internAtom("_args_ptr"), vm) orelse return error.InvalidState;

    const list: *std.ArrayList(argparse.Arg) = @ptrCast(@alignCast(args_list_ptr.asForeign().?));
    try list.append(vm.runtime.alloc, .{
        .name = vm.stringValue(name_atom),
        .short = short,
        .kind = switch (kind) {
            .boolean => .boolean,
            .string => .string,
            .positional => .positional,
        },
        .description = description,
        .terminal = terminal,
        .passthrough = passthrough,
    });

    return .{ .ok = args[0] };
}

fn builderCommandFn(args: []const Data, vm: *VM) !HostResult {
    const name_atom = args[1].asAtom() orelse return .errType(1, "atom", root.typeof(args[1], vm));

    var description: []const u8 = "";
    var prefix = false;

    if (args.len > 2 and args[2].isTable()) {
        const opts = try vm.tables.get(args[2].asTable().?);
        description = tableStr(opts, vm, try vm.internAtom("description")) orelse "";
        prefix = tableBool(opts, vm, try vm.internAtom("prefix"));
    }

    const builder_id = args[0].asTable() orelse return .errType(0, "table", root.typeof(args[0], vm));
    const builder = try vm.tables.get(builder_id);
    const cmds_list_ptr = builder.getRawAtom(try vm.internAtom("_cmds_ptr"), vm) orelse return error.InvalidState;

    const list: *std.ArrayList(argparse.Command) = @ptrCast(@alignCast(cmds_list_ptr.asForeign().?));
    try list.append(vm.runtime.alloc, .{
        .name = vm.stringValue(name_atom),
        .description = description,
        .prefix = prefix,
    });

    return .{ .ok = args[0] };
}

// -- [parse] -----------------------------------------------------------------

fn parseFn(args: []const Data, vm: *VM) !HostResult {
    const alloc = vm.runtime.alloc;

    if (!args[0].isFunction()) return .errType(0, "function", root.typeof(args[0], vm));
    if (!args[1].isTable()) return .errType(1, "table", root.typeof(args[1], vm));

    // heap-allocated so pointers survive past this frame (usage reads them later)
    // intentionally not freed & lives for the VM's lifetime
    const arg_defs = try alloc.create(std.ArrayList(argparse.Arg));
    arg_defs.* = .empty;

    const cmd_defs = try alloc.create(std.ArrayList(argparse.Command));
    cmd_defs.* = .empty;

    // builder table;
    //   methods write directly into the zig arraylists
    const builder_id = try vm.tables.create();
    const builder = try vm.tables.get(builder_id);
    try builder.putRawAtom(try vm.internAtom("_args_ptr"), Data.new.foreign(arg_defs), vm);
    try builder.putRawAtom(try vm.internAtom("_cmds_ptr"), Data.new.foreign(cmd_defs), vm);

    const install = struct {
        fn go(vm_: *VM, tbl: anytype, comptime name: []const u8, func: root.HostFn) !void {
            const fn_id = try vm_.installHost(name, .{
                .arity = 1,
                .variadic = true,
                .param_types = &.{.any},
                .func = func,
            });
            try tbl.putRawAtom(try vm_.internAtom(name), Data.new.function(fn_id), vm_);
        }
    };
    try install.go(vm, builder, "flag", builderFlagFn);
    try install.go(vm, builder, "option", builderOptionFn);
    try install.go(vm, builder, "command", builderCommandFn);
    try install.go(vm, builder, "positional", builderPositionalFn);

    // call user callback
    _ = try vm.callFunctionParts(args[0], null, &[_]Data{Data.new.table(builder_id)}, null);

    // read argv; convert to [:0]const u8, skip argv[0]
    const argv_tbl = try vm.tables.get(args[1].asTable().?);
    var argv_buf: [128][:0]const u8 = undefined;
    const raw_len = argv_tbl.array.items.len;
    const start: usize = if (raw_len > 1) 1 else 0;
    const len = @min(raw_len - start, 128);
    for (0..len) |i| {
        const item = argv_tbl.array.items[start + i];
        argv_buf[i] = if (item.asString()) |sid|
            try alloc.dupeZ(u8, vm.stringValue(sid))
        else
            "";
    }

    // parse
    var leftover: std.ArrayList([:0]const u8) = .empty;
    defer leftover.deinit(alloc);

    var res = argparse.Result{
        .args = arg_defs.items,
        .commands = cmd_defs.items,
        .leftover = &leftover,
    };

    argparse.parse(alloc, argv_buf[0..len], &res) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnexpectedLongArg, error.UnexpectedShortArg, error.MissingValue => {
            const err_table_id = try vm.tables.create();
            const err_table = try vm.tables.get(err_table_id);
            if (res.err_token) |token| {
                try err_table.putRawAtom(try vm.internAtom("token"), try vm.ownDataString(token), vm);
            }
            const msg = switch (err) {
                error.UnexpectedLongArg => "unexpected long arg",
                error.UnexpectedShortArg => "unexpected short arg",
                error.MissingValue => "missing value",
                else => unreachable,
            };
            try err_table.putRawAtom(try vm.internAtom("message"), try vm.ownDataString(msg), vm);

            const result_id = try vm.tables.create();
            const result = try vm.tables.get(result_id);
            try result.putRawAtom(try vm.internAtom("err"), Data.new.table(err_table_id), vm);
            try result.putRawAtom(try vm.internAtom("flags"), Data.new.core(.nil), vm);
            try result.putRawAtom(try vm.internAtom("commands"), Data.new.core(.nil), vm);
            try result.putRawAtom(try vm.internAtom("positionals"), Data.new.core(.nil), vm);
            try result.putRawAtom(try vm.internAtom("leftover"), Data.new.core(.nil), vm);
            try result.putRawAtom(try vm.internAtom("_args"), Data.new.foreign(arg_defs), vm);
            try result.putRawAtom(try vm.internAtom("_cmds"), Data.new.foreign(cmd_defs), vm);
            return .okData(Data.new.table(result_id));
        },
    };

    // build result table
    const result_id = try vm.tables.create();
    const result = try vm.tables.get(result_id);

    // flags
    const flags_id = try vm.tables.create();
    const flags = try vm.tables.get(flags_id);
    for (arg_defs.items) |*arg| {
        if (arg.kind == .positional) continue;
        const nm = try vm.internAtom(arg.name);
        if (arg.kind == .boolean) {
            try flags.putRawAtom(nm, Data.new.boolean(arg.enabled), vm);
        } else if (arg.value) |v| {
            try flags.putRawAtom(nm, try vm.ownDataString(v), vm);
        }
    }
    try result.putRawAtom(try vm.internAtom("flags"), Data.new.table(flags_id), vm);

    // commands
    const cmds_id = try vm.tables.create();
    const cmds = try vm.tables.get(cmds_id);
    for (cmd_defs.items) |*cmd| {
        try cmds.putRawAtom(try vm.internAtom(cmd.name), Data.new.boolean(cmd.triggered), vm);
    }
    try result.putRawAtom(try vm.internAtom("commands"), Data.new.table(cmds_id), vm);

    // positionals
    const pos_id = try vm.tables.create();
    const pos = try vm.tables.get(pos_id);
    for (arg_defs.items) |*arg| {
        if (arg.kind != .positional) continue;
        if (arg.value) |v| {
            try pos.putRawAtom(try vm.internAtom(arg.name), try vm.ownDataString(v), vm);
        }
    }
    try result.putRawAtom(try vm.internAtom("positionals"), Data.new.table(pos_id), vm);

    // leftover
    const lo_id = try vm.tables.create();
    const lo = try vm.tables.get(lo_id);
    for (leftover.items) |item| {
        try lo.push(try vm.ownDataString(item));
    }
    try result.putRawAtom(try vm.internAtom("leftover"), Data.new.table(lo_id), vm);

    try result.putRawAtom(try vm.internAtom("err"), Data.new.core(.nil), vm);
    try result.putRawAtom(try vm.internAtom("_args"), Data.new.foreign(arg_defs), vm);
    try result.putRawAtom(try vm.internAtom("_cmds"), Data.new.foreign(cmd_defs), vm);

    return .okData(Data.new.table(result_id));
}

// -- [usage] -----------------------------------------------------------------

fn usageFn(args: []const Data, vm: *VM) !HostResult {
    const result_id = args[0].asTable() orelse return .errType(0, "table", root.typeof(args[0], vm));
    const result = try vm.tables.get(result_id);

    const arg_defs_ptr = result.getRawAtom(try vm.internAtom("_args"), vm) orelse return error.InvalidState;
    const cmd_defs_ptr = result.getRawAtom(try vm.internAtom("_cmds"), vm) orelse return error.InvalidState;

    const arg_defs: *std.ArrayList(argparse.Arg) = @ptrCast(@alignCast(arg_defs_ptr.asForeign().?));
    const cmd_defs: *std.ArrayList(argparse.Command) = @ptrCast(@alignCast(cmd_defs_ptr.asForeign().?));

    const text = try argparse.usage(vm.runtime.alloc, arg_defs.items, cmd_defs.items);
    defer vm.runtime.alloc.free(text);

    return .okData(try vm.ownDataString(text));
}
