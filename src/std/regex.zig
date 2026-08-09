const mvzr = @import("mvzr");

const revo = @import("../root.zig");
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const NativeResult = root.NativeResult;

pub const specs: []const api.FnSpec = &.{
    .{
        .name = "compile",
        .placements = &.{api.mod("re")},
        .params = &.{.{ "pattern", "string" }},
        .ret = "table",
        .doc = "compile a regex pattern into a reusable handle",
        .f = root.define(&.{.string}, compileFn),
    },
    .{
        .name = "is_match",
        .placements = &.{api.mod("re")},
        .params = &.{ .{ "regex", "table | string" }, .{ "haystack", "string" } },
        .ret = "bool",
        .doc = "test if regex matches anywhere in haystack; pass a string for one-shot compile",
        .f = root.define(&.{ .any, .string }, isMatchFn),
    },
    .{
        .name = "find",
        .placements = &.{api.mod("re")},
        .params = &.{ .{ "regex", "table | string" }, .{ "haystack", "string" } },
        .ret = "string | :nil",
        .doc = "return first match or nil; pass a string for one-shot compile",
        .f = root.define(&.{ .any, .string }, findFn),
    },
    .{
        .name = "find_all",
        .placements = &.{api.mod("re")},
        .params = &.{ .{ "regex", "table | string" }, .{ "haystack", "string" } },
        .ret = "function",
        .doc = "return an iterator over all matches; pass a string for one-shot compile",
        .f = root.define(&.{ .any, .string }, findAllFn),
    },
    .{
        .name = "free",
        .placements = &.{api.mod("re")},
        .params = &.{.{ "regex", "table" }},
        .ret = ":nil",
        .doc = "free a compiled regex handle",
        .f = root.define(&.{.table}, freeFn),
    },
};

fn getRegexFromTable(val: Data, vm: *VM) !*mvzr.Regex {
    const tid = val.asTable().?;
    const table = try vm.tables.get(tid);
    const ptr_val = table.getRaw(try vm.dataAtom("_ptr"), vm) orelse
        return error.InvalidRegex;
    const regex_ptr = ptr_val.asForeign().?;
    return @ptrCast(@alignCast(regex_ptr));
}

fn compileFromString(str_val: Data, vm: *VM) !*mvzr.Regex {
    const pattern = try vm.runtime.alloc.dupe(u8, vm.stringValue(str_val.asString().?));
    defer vm.runtime.alloc.free(pattern);
    const regex = try vm.runtime.alloc.create(mvzr.Regex);
    errdefer vm.runtime.alloc.destroy(regex);
    regex.* = mvzr.compile(pattern) orelse return error.CompileFailed;
    return regex;
}

const ResolvedRegex = struct {
    regex: *mvzr.Regex,
    owned: bool,
};

fn resolveRegex(val: Data, vm: *VM) !ResolvedRegex {
    if (val.isTable()) {
        return .{ .regex = try getRegexFromTable(val, vm), .owned = false };
    }
    if (val.isString()) {
        return .{ .regex = try compileFromString(val, vm), .owned = true };
    }
    return error.InvalidRegex;
}

fn compileFn(args: []const Data, vm: *VM) !NativeResult {
    const pattern_str = try vm.runtime.alloc.dupe(u8, vm.stringValue(args[0].asString().?));
    defer vm.runtime.alloc.free(pattern_str);

    const regex = try vm.runtime.alloc.create(mvzr.Regex);
    errdefer vm.runtime.alloc.destroy(regex);
    regex.* = mvzr.compile(pattern_str) orelse {
        vm.runtime.alloc.destroy(regex);
        return .okData(Data.new.nil());
    };

    const tid = try vm.tables.create();
    const table = try vm.tables.get(tid);
    try table.putRaw(try vm.dataAtom("_ptr"), Data.new.foreign(@ptrCast(regex)), vm);

    try table.putRaw(try vm.dataAtom("_pattern"), args[0], vm);

    const mt_id = try vm.tables.create();
    const mt = try vm.tables.get(mt_id);

    const gc_fn_id = try vm.installNative("__regex_gc", .{
        .arity = 1,
        .param_types = &.{.table},
        .func = gcFn,
        .variadic = false,
        .ret_type = .any,
    });

    try mt.putRaw(try vm.dataAtom("__gc"), Data.new.function(gc_fn_id), vm);
    try vm.setTableMetatable(tid, mt_id);
    try vm.registerFinalizer(tid, Data.new.function(gc_fn_id));

    return .okData(Data.new.table(tid));
}

fn isMatchFn(args: []const Data, vm: *VM) !NativeResult {
    const r = resolveRegex(args[0], vm) catch return .okData(Data.new.boolean(false));
    const owned = r.owned;
    defer if (owned) vm.runtime.alloc.destroy(r.regex);
    const haystack = vm.stringValue(args[1].asString().?);
    return .okData(Data.new.boolean(r.regex.isMatch(haystack)));
}

fn findFn(args: []const Data, vm: *VM) !NativeResult {
    const r = resolveRegex(args[0], vm) catch return .okData(Data.new.nil());
    const owned = r.owned;
    defer if (owned) vm.runtime.alloc.destroy(r.regex);
    const haystack = vm.stringValue(args[1].asString().?);
    if (r.regex.match(haystack)) |m| {
        return .okData(try vm.ownDataString(m.slice));
    }
    return .okData(Data.new.nil());
}

fn findAllFn(args: []const Data, vm: *VM) !NativeResult {
    const r = resolveRegex(args[0], vm) catch return .okData(Data.new.nil());

    const it_id = try vm.tables.create();
    const it = try vm.tables.get(it_id);

    const atom_regex = try vm.internAtom("_ptr");
    const atom_haystack = try vm.internAtom("haystack");
    const atom_pos = try vm.internAtom("pos");

    try it.putRaw(Data.new.atom(atom_regex), Data.new.foreign(@ptrCast(r.regex)), vm);
    try it.putRaw(Data.new.atom(atom_haystack), args[1], vm);
    try it.putRaw(Data.new.atom(atom_pos), Data.new.num(0), vm);

    if (r.owned) {
        const gc_fn_id = try vm.installNative("__regex_it_gc", .{
            .arity = 1,
            .param_types = &.{.table},
            .func = itGcFn,
            .variadic = false,
            .ret_type = .any,
        });
        try vm.registerFinalizer(it_id, Data.new.function(gc_fn_id));
    }

    const mt_id = try vm.tables.create();
    const mt = try vm.tables.get(mt_id);

    const next_fn_id = try vm.installNative("__regex_next", .{
        .arity = 1,
        .param_types = &.{.table},
        .func = nextFn,
        .variadic = false,
        .ret_type = .any,
    });
    try mt.putRaw(try vm.dataAtom("__call"), Data.new.function(next_fn_id), vm);
    try vm.setTableMetatable(it_id, mt_id);

    return .okData(Data.new.table(it_id));
}

fn freeFn(args: []const Data, vm: *VM) !NativeResult {
    const tid = args[0].asTable().?;
    const table = try vm.tables.get(tid);

    const ptr_val = table.getRaw(try vm.dataAtom("_ptr"), vm) orelse
        return .okData(Data.new.nil());
    const regex_ptr = ptr_val.asForeign().?;
    const regex: *mvzr.Regex = @ptrCast(@alignCast(regex_ptr));

    _ = table.remove(try vm.dataAtom("_ptr"), vm);
    vm.runtime.alloc.destroy(regex);
    vm.unregisterFinalizer(tid);

    return .okData(Data.new.nil());
}

fn itGcFn(args: []const Data, vm: *VM) !NativeResult {
    const tid = args[0].asTable().?;
    const table = vm.tables.get(tid) catch return .okData(Data.new.nil());
    const atom_regex = try vm.internAtom("_ptr");
    const ptr_val = table.getRaw(Data.new.atom(atom_regex), vm) orelse
        return .okData(Data.new.nil());
    const regex_ptr = ptr_val.asForeign().?;
    const regex: *mvzr.Regex = @ptrCast(@alignCast(regex_ptr));
    _ = table.remove(Data.new.atom(atom_regex), vm);
    vm.runtime.alloc.destroy(regex);
    return .okData(Data.new.nil());
}

fn gcFn(args: []const Data, vm: *VM) !NativeResult {
    const tid = args[0].asTable().?;
    const table = vm.tables.get(tid) catch return .okData(Data.new.nil());
    const ptr_val = table.getRaw(try vm.dataAtom("_ptr"), vm) orelse
        return .okData(Data.new.nil());
    const regex_ptr = ptr_val.asForeign().?;
    const regex: *mvzr.Regex = @ptrCast(@alignCast(regex_ptr));
    _ = table.remove(try vm.dataAtom("_ptr"), vm);
    vm.runtime.alloc.destroy(regex);
    return .okData(Data.new.nil());
}

fn nextFn(args: []const Data, vm: *VM) !NativeResult {
    const tid = args[0].asTable().?;
    const table = try vm.tables.get(tid);

    const atom_regex = try vm.internAtom("_ptr");
    const atom_haystack = try vm.internAtom("haystack");
    const atom_pos = try vm.internAtom("pos");

    const ptr_val = table.getRaw(Data.new.atom(atom_regex), vm) orelse
        return .okData(Data.new.core(.done));
    const haystack_val = table.getRaw(Data.new.atom(atom_haystack), vm) orelse
        return .okData(Data.new.core(.done));
    const pos_val = table.getRaw(Data.new.atom(atom_pos), vm) orelse
        return .okData(Data.new.core(.done));

    const regex: *mvzr.Regex = @ptrCast(@alignCast(ptr_val.asForeign().?));
    const haystack = vm.stringValue(haystack_val.asString().?);
    const pos: usize = root.numToInt(usize, pos_val.asNum().?) orelse
        return .okData(Data.new.core(.done));

    if (pos > haystack.len) return .okData(Data.new.core(.done));

    const substack = haystack[pos..];
    if (regex.match(substack)) |m| {
        const next_pos = pos + @max(m.end, 1);
        try table.putRaw(Data.new.atom(atom_pos), Data.new.num(next_pos), vm);

        const atom_start = try vm.internAtom("start");
        const atom_end = try vm.internAtom("end");
        const atom_match_key = try vm.internAtom("match");

        const match_tid = try vm.tables.create();
        const match_t = try vm.tables.get(match_tid);
        try match_t.putRaw(Data.new.atom(atom_start), Data.new.num(pos + m.start), vm);
        try match_t.putRaw(Data.new.atom(atom_end), Data.new.num(pos + m.end), vm);
        try match_t.putRaw(Data.new.atom(atom_match_key), try vm.ownDataString(m.slice), vm);

        return .okData(Data.new.table(match_tid));
    }

    return .okData(Data.new.core(.done));
}
