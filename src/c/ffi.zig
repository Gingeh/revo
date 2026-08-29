//
// callable functions for revo runtime interop
//
const std = @import("std");
const builtin = @import("builtin");

const revo = @import("revo");
const vm = @import("vm");
const VM = vm.VM;
const memory = vm.memory;
const Data = memory.Data;
const functions = vm.functions;
const Tuple = vm.tuple.Tuple;
const RevoBinding = functions.RevoBinding;
const CFnPtr = functions.CFnPtr;

// for error/missing returns
const nil_val = Data.new.nil();

/// intern a byte slice, returns stable string id (0 on failure)
pub export fn revo_intern(vm_ptr: *anyopaque, ptr_val: u64, len: usize) callconv(.c) u64 {
    // returns 0 on failure but safe because vm assigns ids starting at 1
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(ptr_val)));
    const slice = ptr[0..len];
    const id = v.strings.own(slice) catch return 0;
    return @intCast(id);
}

/// intern a byte slice as an atom, returns stable atom id (0 on failure)
pub export fn revo_intern_atom(vm_ptr: *anyopaque, ptr_val: u64, len: usize) callconv(.c) u64 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(ptr_val)));
    const slice = ptr[0..len];
    const id = v.internAtom(slice) catch return 0;
    return @intCast(id);
}

/// look up a global variable by name, returns nil if missing
pub export fn revo_getglobal(vm_ptr: *anyopaque, name_ptr: u64, name_len: usize) callconv(.c) Data {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(name_ptr)));
    const name_slice = ptr[0..name_len];

    const value = v.getGlobal(name_slice) orelse
        return nil_val;

    // getGlobal returns :undef for missing names instead of null
    if (value.tag() == .atom and value.asAtom().? == @intFromEnum(revo.core_atoms.undef))
        return nil_val;

    return value;
}

/// set a global variable by name
pub export fn revo_setglobal(vm_ptr: *anyopaque, name_ptr: u64, name_len: usize, value: Data) callconv(.c) void {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const ptr: [*]u8 = @ptrFromInt(@as(usize, @intCast(name_ptr)));
    const name_slice = ptr[0..name_len];

    v.setGlobal(name_slice, value) catch {};
}

/// create a new empty table, returns nil on failure
pub export fn revo_table_create(vm_ptr: *anyopaque) callconv(.c) Data {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid = v.tables.create() catch
        return nil_val;
    return Data.new.table(tid);
}

/// return the number of entries in a table (0 on failure)
pub export fn revo_table_len(vm_ptr: *anyopaque, table_id: u64) callconv(.c) u64 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tbl = v.tables.get(@intCast(table_id)) catch return 0;
    return @intCast(tbl.count());
}

/// look up a key in a table, returns nil if missing or on error
pub export fn revo_table_get(vm_ptr: *anyopaque, table_id: u64, key: Data) callconv(.c) Data {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));

    const tid: memory.TableID = @intCast(table_id);

    const tbl = v.tables.get(tid) catch return nil_val;

    if (tbl.get(key, v) catch return nil_val) |value|
        return value;

    return nil_val;
}

/// delete a table entry, returns true if key existed
pub export fn revo_table_remove(vm_ptr: *anyopaque, table_id: u64, key: Data) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tid: memory.TableID = @intCast(table_id);
    const tbl = v.tables.get(tid) catch return false;
    return tbl.remove(key, v);
}

/// insert or update a table entry, silently ignores errors
pub export fn revo_table_set(vm_ptr: *anyopaque, table_id: u64, key: Data, value: Data) callconv(.c) void {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));

    const tid: memory.TableID = @intCast(table_id);

    const tbl = v.tables.get(tid) catch return;
    tbl.put(tid, v, key, value) catch {};
}

/// create a new tuple from an array of values, returns nil on failure
pub export fn revo_tuple_create(vm_ptr: *anyopaque, count: u64, items: [*]const Data) callconv(.c) Data {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const src = items[0..@as(usize, @intCast(count))];
    var data_list = std.ArrayList(Data).initCapacity(v.runtime.alloc, src.len) catch
        return nil_val;
    defer data_list.deinit(v.runtime.alloc);
    for (src) |item|
        data_list.appendAssumeCapacity(item);
    const tid = v.tuples.create(data_list.items) catch
        return nil_val;
    v.noteGCPressure(@sizeOf(Tuple) + @sizeOf(Data) * src.len);
    return Data.new.tuple(tid);
}

/// get element at index from a tuple, nil if out of bounds or on error
pub export fn revo_tuple_get(vm_ptr: *anyopaque, tuple_id: u64, index: u64) callconv(.c) Data {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tup = v.tuples.get(@intCast(tuple_id)) catch
        return nil_val;
    if (index >= tup.items.len)
        return nil_val;
    return tup.items[@intCast(index)];
}

/// return the number of elements in a tuple (0 on failure)
pub export fn revo_tuple_len(vm_ptr: *anyopaque, tuple_id: u64) callconv(.c) u64 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const tup = v.tuples.get(@intCast(tuple_id)) catch return 0;
    return @intCast(tup.items.len);
}

/// call a revo function from c, returns false on type/resource error (max 16 args)
pub export fn revo_call(
    vm_ptr: *anyopaque,
    func: Data,
    argc: u64,
    argv: [*]const Data,
    out: *Data,
) callconv(.c) bool {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const callee = func;

    // stack buffer avoids GC-triggering heap alloc, most revo functions have few args
    var buf: [16]Data = undefined;
    if (argc > 16) return false;
    for (0..@as(usize, @intCast(argc))) |i|
        buf[i] = argv[i];

    const result = v.callFunctionParts(callee, null, buf[0..@as(usize, @intCast(argc))], null) catch return false;
    out.* = result;
    return true;
}

/// return pointer to interned string data (null on failure, valid until next GC sweep)
pub export fn revo_string_data(vm_ptr: *anyopaque, id: u64) callconv(.c) ?[*]const u8 {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const slice = v.strings.get(@intCast(id)) catch return null;
    // pointer valid only until next GC sweep; caller must not hold across allocs
    return slice.ptr;
}

/// return byte length of an interned string (0 on failure)
pub export fn revo_string_length(vm_ptr: *anyopaque, id: u64) callconv(.c) usize {
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const slice = v.strings.get(@intCast(id)) catch return 0;
    return slice.len;
}

/// wrap a raw pointer as a foreign value, caller manages lifetime
pub export fn revo_foreign_new(ptr: ?*anyopaque) callconv(.c) Data {
    return Data.new.foreign(ptr);
}

/// extract the raw pointer from a foreign value (null if not foreign)
pub export fn revo_foreign_ptr(val: Data) callconv(.c) ?*anyopaque {
    return val.asForeign();
}

/// register a shared lib's revo_bindings into the module table; types come
/// from the sibling `<stem>.d.rv` manifest (`extensionManifestFor`)
pub fn loadC(vm_ptr: *VM, lib_path: []const u8) ![]functions.CFunction {
    if (builtin.target.os.tag == .wasi or builtin.target.os.tag == .freestanding) {
        std.debug.print("error: dynamic library loading is not supported on this platform\n", .{});
        return error.OsNotSupported;
    }

    if (builtin.target.os.tag == .windows) {
        std.debug.print("error: dynamic library loading is not supported on windows\n", .{});
        return error.OsNotSupported;
    }

    var lib = try std.DynLib.open(lib_path);

    const bindings_ptr: [*]const RevoBinding = lib.lookup([*]const RevoBinding, "revo_bindings") orelse {
        std.debug.print("error: extension '{s}' has no revo_bindings export\n", .{lib_path});
        return error.NoBindings;
    };

    var registered = try std.ArrayList(functions.CFunction).initCapacity(vm_ptr.runtime.alloc, 16);
    defer registered.deinit(vm_ptr.runtime.alloc);

    var i: usize = 0;
    while (@as(?[*:0]const u8, bindings_ptr[i].name) != null) : (i += 1) {
        try registered.append(vm_ptr.runtime.alloc, .{
            .name = std.mem.span(bindings_ptr[i].name),
            .fn_ptr = @ptrCast(@alignCast(bindings_ptr[i].fn_ptr)),
        });
    }

    try vm_ptr.loaded_extensions.append(vm_ptr.runtime.alloc, lib);
    return try registered.toOwnedSlice(vm_ptr.runtime.alloc);
}
