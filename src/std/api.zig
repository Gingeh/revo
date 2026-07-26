// stdlib as data. modules publish `pub const specs: []const FnSpec`
// and `registerAll` installs everything in one walk so metatable
// methods added by later specs merge into earlier ones

const std = @import("std");

const revo = @import("../root.zig");
const Data = revo.Data;
const root = @import("root.zig");
const TypeSpec = root.TypeSpec;
const NativeFunc = root.NativeFunc;

pub const all_specs: []const []const FnSpec = blk: {
    var x = &.{
        @import("root.zig").root_specs,
        @import("string.zig").specs,
        @import("table.zig").specs,
        @import("tuple.zig").specs,
        @import("iter.zig").specs,
        @import("math.zig").specs,
        @import("json.zig").specs,
        @import("time.zig").specs,
        @import("net.zig").specs,
        @import("fs.zig").specs,
        @import("revo.zig").specs,
        @import("compress.zig").specs,
    };

    if (@import("build_options").regex)
        x = x ++ @import("regex.zig").specs;

    break :blk x;
};

/// look up a function by name across all spec tables.
/// first match wins
pub fn find(name: []const u8) ?FnSpec {
    for (all_specs) |group| for (group) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    };
    return null;
}

/// name(p1: t1, p2: t2) -> ret
pub fn renderSignature(w: *std.Io.Writer, spec: FnSpec) !void {
    try w.print("{s}(", .{spec.name});
    for (spec.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{s}: {s}", .{ p[0], p[1] });
    }
    try w.writeAll(")");
    if (spec.ret.len > 0) {
        try w.print(" -> {s}", .{spec.ret});
    }
}

pub const Kind = enum { global, module, method };

pub const Placement = struct {
    kind: Kind,
    module: ?[]const u8 = null,
    target: ?TypeSpec = null,
};

/// (name, type-string)
pub const Param = struct { []const u8, []const u8 };

pub const FnSpec = struct {
    name: []const u8,
    placements: []const Placement,
    params: []const Param,
    ret: []const u8,
    doc: []const u8 = "",
    variadic: bool = false,
    /// when set, the metatable key is this core atom (e.g. `__index`)
    /// instead of `internAtom(name)`. only `__index` uses it today
    core_key: ?revo.core_atoms = null,
    f: NativeFunc,
};

pub const g: Placement = .{ .kind = .global };
pub fn mod(comptime m: []const u8) Placement {
    return .{ .kind = .module, .module = m };
}
pub fn method(comptime m: []const u8, t: TypeSpec) Placement {
    return .{ .kind = .method, .module = m, .target = t };
}

/// returns a Data value to anchor the metatable at `target`. the
/// value itself is discarded; only the metatable slot matters
pub const PrototypeFn = fn (target: TypeSpec, vm: *revo.VM) anyerror!revo.Data;

pub fn registerAll(
    vm: *revo.VM,
    groups: []const []const FnSpec,
    prototype: PrototypeFn,
) !void {
    var module_funcs: std.StringHashMapUnmanaged(std.ArrayList(ModuleEntry)) = .empty;
    var module_calls: std.StringHashMapUnmanaged(revo.memory.FunctionID) = .empty;
    var methods_by_target: std.AutoHashMapUnmanaged(TypeSpec, std.ArrayList(MethodEntry)) = .empty;
    var global_funcs: std.ArrayList(GlobalEntry) = .empty;

    defer {
        var mit = module_funcs.iterator();
        while (mit.next()) |e| e.value_ptr.deinit(vm.runtime.alloc);
        module_funcs.deinit(vm.runtime.alloc);
        module_calls.deinit(vm.runtime.alloc);
        var tit = methods_by_target.iterator();
        while (tit.next()) |e| e.value_ptr.deinit(vm.runtime.alloc);
        methods_by_target.deinit(vm.runtime.alloc);
        global_funcs.deinit(vm.runtime.alloc);
    }

    for (groups) |specs| {
        for (specs) |spec| {
            const fn_id = try vm.installNative(spec.name, spec.f);
            for (spec.placements) |p| switch (p.kind) {
                .global => try global_funcs.append(vm.runtime.alloc, .{ .name = spec.name, .fn_id = fn_id }),
                .module => {
                    if (spec.core_key == .__call) {
                        try module_calls.put(vm.runtime.alloc, p.module.?, fn_id);
                    } else {
                        const gop = try module_funcs.getOrPutValue(vm.runtime.alloc, p.module.?, .empty);
                        try gop.value_ptr.append(vm.runtime.alloc, .{ .name = spec.name, .fn_id = fn_id });
                    }
                },
                .method => {
                    const gop = try methods_by_target.getOrPutValue(vm.runtime.alloc, p.target.?, .empty);
                    try gop.value_ptr.append(vm.runtime.alloc, .{
                        .name = spec.name,
                        .fn_id = fn_id,
                        .core_atom = spec.core_key,
                    });
                },
            };
        }
    }

    for (global_funcs.items) |gf| try vm.registerGlobal(gf.name, gf.fn_id);

    {
        var it = module_funcs.iterator();
        while (it.next()) |entry| {
            const table_id = try vm.ensureModule(entry.key_ptr.*);
            for (entry.value_ptr.items) |f| try vm.putInTable(table_id, f.name, f.fn_id);

            if (module_calls.get(entry.key_ptr.*)) |call_fn_id| {
                const mt_id = try vm.tables.create();
                try vm.putInTableAtom(mt_id, @backingInt(revo.core_atoms.__call), call_fn_id);
                try vm.setMetatable(Data.new.table(table_id), mt_id);
            }
        }
    }

    {
        var it = methods_by_target.iterator();
        while (it.next()) |entry| {
            const target = entry.key_ptr.*;
            const methods = entry.value_ptr.items;
            const proto = try prototype(target, vm);
            const mt_id = try vm.tables.create();
            for (methods) |m| {
                if (m.core_atom) |core| {
                    try vm.putInTableAtom(mt_id, @backingInt(core), m.fn_id);
                } else {
                    try vm.putInTable(mt_id, m.name, m.fn_id);
                }
            }
            try vm.setMetatable(proto, mt_id);
        }
    }
}

const ModuleEntry = struct {
    name: []const u8,
    fn_id: revo.memory.FunctionID,
};
const GlobalEntry = struct {
    name: []const u8,
    fn_id: revo.memory.FunctionID,
};
const MethodEntry = struct {
    name: []const u8,
    fn_id: revo.memory.FunctionID,
    core_atom: ?revo.core_atoms,
};
