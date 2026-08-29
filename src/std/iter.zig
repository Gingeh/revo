// all iterator fns live only under the `iter` module. `to_iter` stays a
// global: the for-loop compiler emits `load_global to_iter` directly

pub const impls: []const api.Impl = &.{
    // zig fmt: off
    .{ .name = "to_iter", .f = root.define(&.{.any}, to_iter), },
    .{ .name = "to_iter", .f = root.define(&.{.any}, to_iter), },
    .{ .name = "range", .f = root.defineVariadic(&.{.any}, range_fn), },
    .{ .name = "map", .f = root.define(&.{ .any, .function }, transformFn(.map)), },
    .{ .name = "filter", .f = root.define(&.{ .any, .function }, transformFn(.filter)), },
    .{ .name = "take", .f = root.define(&.{ .any, .any }, boundedFn(.take)), },
    .{ .name = "drop", .f = root.define(&.{ .any, .any }, boundedFn(.drop)), },
    .{ .name = "zip", .f = root.defineVariadic(&.{.any}, zip_fn), },
    .{ .name = "enumerate", .f = root.define(&.{.any}, enumerate_fn), },
    .{ .name = "chunk", .f = root.define(&.{ .any, .any }, boundedFn(.chunk)), },
    .{ .name = "flat_map", .f = root.define(&.{ .any, .function }, transformFn(.flat_map)), },
    .{ .name = "collect", .f = root.define(&.{.any}, collect_fn), },
    .{ .name = "collect_string", .f = root.define(&.{.any}, collect_string_fn), },
    .{ .name = "reduce", .f = root.define(&.{ .any, .function, .any }, reduce_fn), },
    .{ .name = "fold", .f = root.define(&.{ .any, .function }, fold_fn), },
    .{ .name = "each", .f = root.define(&.{ .any, .function }, each_fn), },
    .{ .name = "find", .f = root.define(&.{ .any, .function }, find_fn), },
    .{ .name = "all?", .f = root.define(&.{ .any, .function }, all_fn), },
    .{ .name = "any?", .f = root.define(&.{ .any, .function }, any_fn), },
    .{ .name = "count", .f = root.defineVariadic(&.{.any}, count_fn), },
    .{ .name = "sum", .f = root.define(&.{.any}, sum_fn), },
    // zig fmt: on
};

const Kind = enum(usize) {
    seq,
    map,
    filter,
    take,
    drop,
    enumerate,
    chunk,
    zip,
    flat_map,
    range,
};

/// > to_iter(obj: any) -> function
/// returns a zero-arg callable iterator for obj
pub fn to_iter(args: []const Data, vm: *VM) !HostResult {
    const w = (try wrapIterable(vm, args[0])) orelse
        return .errType(0, "iterable", typeof(args[0], vm));
    if (w.isString() or w.isTuple() or w.isTable())
        return makeSeqIterator(vm, w);
    return .okData(w);
}

/// > range(...) -> function
/// returns a lazy arithmetic sequence
pub fn range_fn(args: []const Data, vm: *VM) !HostResult {
    const start: f64 = if (args.len == 1) 0 else blk: {
        const n = args[0].asNum() orelse return .errType(0, "num", typeof(args[0], vm));
        break :blk n;
    };
    const end: f64 = if (args.len == 1) blk: {
        const n = args[0].asNum() orelse return .errType(0, "num", typeof(args[0], vm));
        break :blk n;
    } else blk: {
        const n = args[1].asNum() orelse return .errType(1, "num", typeof(args[1], vm));
        break :blk n;
    };
    const step: f64 = if (args.len >= 3) blk: {
        const n = args[2].asNum() orelse return .errType(2, "num", typeof(args[2], vm));
        break :blk n;
    } else 1;
    if (step == 0) return .errType(2, "non-zero step", "0");

    const it_id = try makeIterator(vm, .range);
    try putState(vm, it_id, .a, Data.new.num(start));
    try putState(vm, it_id, .b, Data.new.num(end));
    try putState(vm, it_id, .step, Data.new.num(step));
    return .okData(Data.new.table(it_id));
}

/// Host for map/filter/flat_map-style lazy transform iterators
fn transformFn(comptime kind: Kind) root.HostFn {
    return struct {
        fn f(args: []const Data, vm: *VM) anyerror!HostResult {
            const up = (try wrapIterable(vm, args[0])) orelse
                return .errType(0, "iterable", typeof(args[0], vm));
            const it_id = try makeIterator(vm, kind);
            try putState(vm, it_id, .up, up);
            try putState(vm, it_id, .func, args[1]);
            return .okData(Data.new.table(it_id));
        }
    }.f;
}

/// Host for take/drop/chunk-style bounded lazy iterators
fn boundedFn(comptime kind: Kind) root.HostFn {
    return struct {
        fn f(args: []const Data, vm: *VM) anyerror!HostResult {
            const up = (try wrapIterable(vm, args[0])) orelse
                return .errType(0, "iterable", typeof(args[0], vm));
            const n = args[1].asNum() orelse return .errType(1, "num", typeof(args[1], vm));
            const it_id = try makeIterator(vm, kind);
            try putState(vm, it_id, .up, up);
            try putState(vm, it_id, .n, Data.new.num(n));
            return .okData(Data.new.table(it_id));
        }
    }.f;
}

/// > zip(...) -> function
/// returns a lazy iterator of tuples, one element from each iterable
pub fn zip_fn(args: []const Data, vm: *VM) !HostResult {
    if (args.len < 2) return .errArity(args.len, 2);
    var ups = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, args.len);
    defer ups.deinit(vm.runtime.alloc);
    for (args) |a| {
        const w = (try toCallable(vm, a)) orelse
            return .errType(0, "iterable", typeof(a, vm));
        try ups.append(vm.runtime.alloc, w);
    }
    const up_tuple = try vm.tuples.create(ups.items);
    const it_id = try makeIterator(vm, .zip);
    try putState(vm, it_id, .up, Data.new.tuple(up_tuple));
    return .okData(Data.new.table(it_id));
}

/// > enumerate(collection: any) -> function
/// returns a lazy iterator of (index, value) tuples
pub fn enumerate_fn(args: []const Data, vm: *VM) !HostResult {
    const up = (try wrapIterable(vm, args[0])) orelse
        return .errType(0, "iterable", typeof(args[0], vm));
    const it_id = try makeIterator(vm, .enumerate);
    try putState(vm, it_id, .up, up);
    return .okData(Data.new.table(it_id));
}

/// > collect(iterable: any) -> table
/// collects all values from an iterable into a table
pub fn collect_fn(args: []const Data, vm: *VM) !HostResult {
    if (args.len != 1) return .errArity(args.len, 1);
    const st_id = toState(vm, args[0]) catch
        return .errType(0, "iterable", typeof(args[0], vm));
    const out_id = try vm.tables.create();
    var v: Data = undefined;
    var idx: Data = undefined;
    while (try pullStep(vm, st_id, &v, &idx))
        try (try vm.tables.get(out_id)).array.append(vm.runtime.alloc, v);
    return .okData(Data.new.table(out_id));
}

/// > collect_string(iterable: any) -> string
/// collects string/num elements from an iterable into a string
pub fn collect_string_fn(args: []const Data, vm: *VM) !HostResult {
    if (args.len != 1) return .errArity(args.len, 1);
    const st_id = toState(vm, args[0]) catch
        return .errType(0, "iterable", typeof(args[0], vm));
    var buf = try std.ArrayList(u8).initCapacity(vm.runtime.alloc, 0);
    defer buf.deinit(vm.runtime.alloc);
    var v: Data = undefined;
    var idx: Data = undefined;
    while (try pullStep(vm, st_id, &v, &idx)) {
        if (v.asString()) |s| {
            try buf.appendSlice(vm.runtime.alloc, vm.stringValue(s));
        } else if (v.asNum()) |n| {
            try buf.append(vm.runtime.alloc, @as(u8, @intFromFloat(std.math.clamp(@round(n), 0, 255))));
        } else {
            return .errType(0, "string or num", typeof(v, vm));
        }
    }
    return .{ .ok = try vm.adoptDataString(try buf.toOwnedSlice(vm.runtime.alloc)) };
}

/// > reduce(collection: any, fn: function, init: any) -> any
/// folds/accumulates elements using function and initial value
pub fn reduce_fn(args: []const Data, vm: *VM) !HostResult {
    if (args.len != 3) return .errArity(args.len, 3);
    const st_id = toState(vm, args[0]) catch
        return .errType(0, "iterable", typeof(args[0], vm));
    var acc = args[2];
    var v: Data = undefined;
    var idx: Data = undefined;
    while (try pullStep(vm, st_id, &v, &idx))
        acc = try vm.callFunction(args[1], &[_]Data{ acc, v });
    return .{ .ok = acc };
}

/// > fold(collection: any, fn: function) -> any
/// like reduce but without an initial value; first element seeds the fold
pub fn fold_fn(args: []const Data, vm: *VM) !HostResult {
    if (args.len != 2) return .errArity(args.len, 2);
    const st_id = toState(vm, args[0]) catch
        return .errType(0, "iterable", typeof(args[0], vm));
    var acc: Data = undefined;
    var got: bool = false;
    var v: Data = undefined;
    var idx: Data = undefined;
    while (try pullStep(vm, st_id, &v, &idx)) {
        if (!got) {
            acc = v;
            got = true;
        } else {
            acc = try vm.callFunction(args[1], &[_]Data{ acc, v });
        }
    }
    if (!got) return .okData(revo.Data.new.core(.nil));
    return .{ .ok = acc };
}

/// call fn with (value, index) when it takes 2+ params, else (value)
fn callPred(vm: *VM, f: Data, v: Data, idx: Data) !Data {
    return if (passesIndex(vm, f))
        try vm.callFunction(f, &[_]Data{ v, idx })
    else
        try vm.callFunction(f, &[_]Data{v});
}

/// > each(collection: any, fn: function) -> atom
/// iterates over elements, calling function for side effects, returns :ok
pub fn each_fn(args: []const Data, vm: *VM) !HostResult {
    if (args.len != 2) return .errArity(args.len, 2);
    const st_id = toState(vm, args[0]) catch
        return .errType(0, "iterable", typeof(args[0], vm));
    var v: Data = undefined;
    var idx: Data = undefined;
    while (try pullStep(vm, st_id, &v, &idx))
        _ = try callPred(vm, args[1], v, idx);
    return root.okAtom(vm);
}

/// > find(what: any, fn: function) -> any
/// returns first element where function returns true, or nil
pub fn find_fn(args: []const Data, vm: *VM) !HostResult {
    if (args.len != 2) return .errArity(args.len, 2);
    const st_id = toState(vm, args[0]) catch
        return .errType(0, "iterable", typeof(args[0], vm));
    var v: Data = undefined;
    var idx: Data = undefined;
    while (try pullStep(vm, st_id, &v, &idx)) {
        if (isTruthy(try callPred(vm, args[1], v, idx))) return .{ .ok = v };
    }
    return .okData(revo.Data.new.core(.nil));
}

/// > all?(collection: any, pred: function) -> boolean
/// returns true if function returns true for all elements
pub fn all_fn(args: []const Data, vm: *VM) !HostResult {
    if (args.len != 2) return .errArity(args.len, 2);
    const st_id = toState(vm, args[0]) catch
        return .errType(0, "iterable", typeof(args[0], vm));
    var v: Data = undefined;
    var idx: Data = undefined;
    while (try pullStep(vm, st_id, &v, &idx)) {
        if (!isTruthy(try callPred(vm, args[1], v, idx))) return .okData(Data.new.boolean(false));
    }
    return .okData(Data.new.boolean(true));
}

/// > any?(collection: any, pred: function) -> boolean
/// returns true if function returns true for any element
pub fn any_fn(args: []const Data, vm: *VM) !HostResult {
    if (args.len != 2) return .errArity(args.len, 2);
    const st_id = toState(vm, args[0]) catch
        return .errType(0, "iterable", typeof(args[0], vm));
    var v: Data = undefined;
    var idx: Data = undefined;
    while (try pullStep(vm, st_id, &v, &idx)) {
        if (isTruthy(try callPred(vm, args[1], v, idx))) return .okData(Data.new.boolean(true));
    }
    return .okData(Data.new.boolean(false));
}

/// > count(collection: any, pred: function) -> num
/// returns the num of elements, or of those where pred is truthy
pub fn count_fn(args: []const Data, vm: *VM) !HostResult {
    if (args.len < 1 or args.len > 2) return .errArity(args.len, 1);
    const st_id = toState(vm, args[0]) catch
        return .errType(0, "iterable", typeof(args[0], vm));
    var n: f64 = 0;
    var v: Data = undefined;
    var idx: Data = undefined;
    while (try pullStep(vm, st_id, &v, &idx)) {
        if (args.len == 2 and !isTruthy(try callPred(vm, args[1], v, idx))) continue;
        n += 1;
    }
    return .okData(Data.new.num(n));
}

/// > sum(collection: any) -> num
/// sums numeric elements, skipping non-numbers
pub fn sum_fn(args: []const Data, vm: *VM) !HostResult {
    if (args.len != 1) return .errArity(args.len, 1);
    const st_id = toState(vm, args[0]) catch
        return .errType(0, "iterable", typeof(args[0], vm));
    var total: f64 = 0;
    var v: Data = undefined;
    var idx: Data = undefined;
    while (try pullStep(vm, st_id, &v, &idx)) {
        if (v.asNum()) |n| total += n;
    }
    return .okData(Data.new.num(total));
}

/// __call handler for iterator tables
/// reads the kind from the metatable and advances the matching state machine
fn iteratorNext(args: []const Data, vm: *VM) !HostResult {
    const mt_id = (try vm.getMetatableId(args[0])) orelse
        return .okData(revo.Data.new.core(.done));
    const kind_val = (try vm.tables.get(mt_id)).getRawAtom(revo.core_atoms.kind.atomId(), vm) orelse
        return .okData(revo.Data.new.core(.done));
    const kind_num = kind_val.asNum() orelse return .okData(revo.Data.new.core(.done));
    const kind: Kind = @enumFromInt(@as(usize, @intFromFloat(kind_num)));
    return switch (kind) {
        .seq => seqNext(mt_id, vm),
        .map => mapNext(mt_id, vm),
        .filter => filterNext(mt_id, vm),
        .take => takeNext(mt_id, vm),
        .drop => dropNext(mt_id, vm),
        .enumerate => enumerateNext(mt_id, vm),
        .chunk => chunkNext(mt_id, vm),
        .zip => zipNext(mt_id, vm),
        .flat_map => flatMapNext(mt_id, vm),
        .range => rangeNext(mt_id, vm),
    };
}

fn seqNext(st_id: mem.TableID, vm: *VM) !HostResult {
    var v: Data = undefined;
    var idx: Data = undefined;
    if (!try pullStep(vm, st_id, &v, &idx)) return .okData(revo.Data.new.core(.done));
    return .okData(v);
}

fn mapNext(st_id: mem.TableID, vm: *VM) !HostResult {
    var v: Data = undefined;
    var idx: Data = undefined;
    if (!try pullStep(vm, st_id, &v, &idx)) return .okData(revo.Data.new.core(.done));
    const f = (try vm.tables.get(st_id)).getRawAtom(revo.core_atoms.func.atomId(), vm) orelse
        return .okData(revo.Data.new.core(.done));
    return .okData(try callPred(vm, f, v, idx));
}

fn filterNext(st_id: mem.TableID, vm: *VM) !HostResult {
    const f = (try vm.tables.get(st_id)).getRawAtom(revo.core_atoms.func.atomId(), vm) orelse
        return .okData(revo.Data.new.core(.done));
    while (true) {
        var v: Data = undefined;
        var idx: Data = undefined;
        if (!try pullStep(vm, st_id, &v, &idx)) return .okData(revo.Data.new.core(.done));
        if (isTruthy(try callPred(vm, f, v, idx))) return .okData(v);
    }
}

fn takeNext(st_id: mem.TableID, vm: *VM) !HostResult {
    var st = try vm.tables.get(st_id);
    const n = (st.getRawAtom(revo.core_atoms.n.atomId(), vm) orelse Data.new.num(0)).asNum().?;
    const taken = (st.getRawAtom(revo.core_atoms.count.atomId(), vm) orelse Data.new.num(0)).asNum().?;
    if (taken >= n) return .okData(revo.Data.new.core(.done));
    var v: Data = undefined;
    var idx: Data = undefined;
    if (!try pullStep(vm, st_id, &v, &idx)) return .okData(revo.Data.new.core(.done));
    st = try vm.tables.get(st_id);
    try st.putRawAtom(revo.core_atoms.count.atomId(), Data.new.num(taken + 1), vm);
    return .okData(v);
}

fn dropNext(st_id: mem.TableID, vm: *VM) !HostResult {
    while (true) {
        var v: Data = undefined;
        var idx: Data = undefined;
        if (!try pullStep(vm, st_id, &v, &idx)) return .okData(revo.Data.new.core(.done));
        var st = try vm.tables.get(st_id);
        const n = (st.getRawAtom(revo.core_atoms.n.atomId(), vm) orelse Data.new.num(0)).asNum().?;
        const dropped = (st.getRawAtom(revo.core_atoms.count.atomId(), vm) orelse Data.new.num(0)).asNum().?;
        if (dropped >= n) return .okData(v);
        try st.putRawAtom(revo.core_atoms.count.atomId(), Data.new.num(dropped + 1), vm);
    }
}

fn enumerateNext(st_id: mem.TableID, vm: *VM) !HostResult {
    var v: Data = undefined;
    var idx: Data = undefined;
    if (!try pullStep(vm, st_id, &v, &idx)) return .okData(revo.Data.new.core(.done));
    const pair = try vm.tuples.create(&[_]Data{ idx, v });
    return .okData(Data.new.tuple(pair));
}

fn chunkNext(st_id: mem.TableID, vm: *VM) !HostResult {
    const n_val = (try vm.tables.get(st_id)).getRawAtom(revo.core_atoms.n.atomId(), vm) orelse
        return .okData(revo.Data.new.core(.done));
    const n = root.numToInt(usize, n_val.asNum().?) orelse
        return .okData(revo.Data.new.core(.done));
    const out_id = try vm.tables.create();
    var count: usize = 0;
    while (count < n) {
        var v: Data = undefined;
        var idx: Data = undefined;
        if (!try pullStep(vm, st_id, &v, &idx)) break;
        try (try vm.tables.get(out_id)).array.append(vm.runtime.alloc, v);
        count += 1;
    }
    if (count == 0) return .okData(revo.Data.new.core(.done));
    return .okData(Data.new.table(out_id));
}

fn zipNext(st_id: mem.TableID, vm: *VM) !HostResult {
    const ups_data = (try vm.tables.get(st_id)).getRawAtom(revo.core_atoms.up.atomId(), vm) orelse
        return .okData(revo.Data.new.core(.done));
    const ups_id = ups_data.asTuple() orelse return .okData(revo.Data.new.core(.done));
    var vals = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, 0);
    defer vals.deinit(vm.runtime.alloc);
    var i: usize = 0;
    while (true) : (i += 1) {
        const ups = vm.tuples.get(ups_id) catch return .okData(revo.Data.new.core(.done));
        if (i >= ups.items.len) break;
        const v = try vm.callFunction(ups.items[i], &.{});
        if (isDone(v)) return .okData(revo.Data.new.core(.done));
        try vals.append(vm.runtime.alloc, v);
    }
    const t = try vm.tuples.create(vals.items);
    return .okData(Data.new.tuple(t));
}

fn flatMapNext(st_id: mem.TableID, vm: *VM) !HostResult {
    while (true) {
        var st = try vm.tables.get(st_id);
        const cur = st.getRawAtom(revo.core_atoms.cur.atomId(), vm) orelse revo.Data.new.core(.nil);
        if (cur.asAtom()) |a| {
            if (a == revo.core_atoms.atomId(.nil)) {
                var v: Data = undefined;
                var idx: Data = undefined;
                if (!try pullStep(vm, st_id, &v, &idx)) return .okData(revo.Data.new.core(.done));
                const f = (try vm.tables.get(st_id)).getRawAtom(revo.core_atoms.func.atomId(), vm) orelse
                    return .okData(revo.Data.new.core(.done));
                const mapped = try callPred(vm, f, v, idx);
                const sub = (try toCallable(vm, mapped)) orelse
                    return .errType(1, "iterable", typeof(mapped, vm));
                st = try vm.tables.get(st_id);
                try st.putRawAtom(revo.core_atoms.cur.atomId(), sub, vm);
                continue;
            }
        }
        const val = try vm.callFunction(cur, &.{});
        if (isDone(val)) {
            st = try vm.tables.get(st_id);
            try st.putRawAtom(revo.core_atoms.cur.atomId(), revo.Data.new.core(.nil), vm);
            continue;
        }
        return .okData(val);
    }
}

fn rangeNext(st_id: mem.TableID, vm: *VM) !HostResult {
    var st = try vm.tables.get(st_id);
    const a = (st.getRawAtom(revo.core_atoms.a.atomId(), vm) orelse Data.new.num(0)).asNum().?;
    const b = (st.getRawAtom(revo.core_atoms.b.atomId(), vm) orelse Data.new.num(0)).asNum().?;
    const step = (st.getRawAtom(revo.core_atoms.step.atomId(), vm) orelse Data.new.num(1)).asNum().?;
    const cur = (st.getRawAtom(revo.core_atoms.pos.atomId(), vm) orelse Data.new.num(a)).asNum().?;
    if ((step > 0 and cur >= b) or (step < 0 and cur <= b))
        return .okData(revo.Data.new.core(.done));
    st = try vm.tables.get(st_id);
    try st.putRawAtom(revo.core_atoms.pos.atomId(), Data.new.num(cur + step), vm);
    return .okData(Data.new.num(cur));
}

/// resolves obj to an iterable:
/// functions and callable tables are iterators already
/// __iter metamethods are called
/// raw string/tuple/table pass through so index/key callbacks keep keys
/// returns null for non-iterables
fn wrapIterable(vm: *VM, obj: Data) !?Data {
    if (obj.isFunction()) return obj;
    if (try vm.getMetamethodByAtom(obj, revo.core_atoms.__iter.atomId())) |mm|
        return try vm.callFunction(mm, &[_]Data{obj});
    if (obj.isTable() and try vm.getMetamethodByAtom(obj, revo.core_atoms.__call.atomId()) != null)
        return obj;
    if (obj.isString() or obj.isTuple() or obj.isTable()) return obj;
    return null;
}

/// resolves obj to a zero-arg callable iterator:
/// functions and callable tables return as-is, raw sequences get a seq wrapper
fn toCallable(vm: *VM, obj: Data) !?Data {
    const w = (try wrapIterable(vm, obj)) orelse return null;
    if (w.isFunction()) return w;
    if (w.isTable() and try vm.getMetamethodByAtom(w, revo.core_atoms.__call.atomId()) != null)
        return w;
    const it_id = try makeIterator(vm, .seq);
    try putState(vm, it_id, .up, w);
    return Data.new.table(it_id);
}

/// makes a state table (metatable-less) for terminal-op iteration
fn toState(vm: *VM, xs: Data) !mem.TableID {
    const w = (try wrapIterable(vm, xs)) orelse
        return error.NotIterable;
    return makeState(vm, w);
}

fn makeState(vm: *VM, obj: Data) !mem.TableID {
    const st_id = try vm.tables.create();
    const st = try vm.tables.get(st_id);
    try st.putRawAtom(revo.core_atoms.up.atomId(), obj, vm);
    try st.putRawAtom(revo.core_atoms.pos.atomId(), Data.new.num(0), vm);
    try st.putRawAtom(revo.core_atoms.phase.atomId(), Data.new.num(0), vm);
    try st.putRawAtom(revo.core_atoms.idx.atomId(), Data.new.num(0), vm);
    return st_id;
}

fn makeSeqIterator(vm: *VM, obj: Data) !HostResult {
    const it_id = try makeIterator(vm, .seq);
    try putState(vm, it_id, .up, obj);
    return .okData(Data.new.table(it_id));
}

/// creates an empty iterator table whose metatable holds state and __call
fn makeIterator(vm: *VM, kind: Kind) !mem.TableID {
    const it_id = try vm.tables.create();
    const mt_id = try vm.tables.create();
    const mt = try vm.tables.get(mt_id);
    try mt.putRawAtom(revo.core_atoms.kind.atomId(), Data.new.num(@as(f64, @floatFromInt(@intFromEnum(kind)))), vm);
    const next_id = try vm.installHost("iter_next", .{
        .arity = 1,
        .param_types = &.{.any},
        .func = iteratorNext,
    });
    try mt.putRawAtom(revo.core_atoms.__call.atomId(), Data.new.function(next_id), vm);
    try vm.setTableMetatable(it_id, mt_id);
    return it_id;
}

fn putState(vm: *VM, it_id: mem.TableID, comptime k: revo.core_atoms, val: Data) !void {
    const mt_id = (try vm.getMetatableId(Data.new.table(it_id))).?;
    try (try vm.tables.get(mt_id)).putRawAtom(k.atomId(), val, vm);
}

/// advances the state machine one element; out_idx is the index (or key for
/// hash-phase table iteration) of the element; returns false at :done
fn pullStep(vm: *VM, st_id: mem.TableID, out: *Data, out_idx: *Data) !bool {
    var st = try vm.tables.get(st_id);
    const up = st.getRawAtom(revo.core_atoms.up.atomId(), vm) orelse return false;

    const callable = up.isFunction() or
        (up.isTable() and try vm.getMetamethodByAtom(up, revo.core_atoms.__call.atomId()) != null);
    if (callable) {
        const v = try vm.callFunction(up, &.{});
        if (isDone(v)) return false;
        st = try vm.tables.get(st_id);
        const idx_val = st.getRawAtom(revo.core_atoms.idx.atomId(), vm) orelse Data.new.num(0);
        out.* = v;
        out_idx.* = idx_val;
        try st.putRawAtom(revo.core_atoms.idx.atomId(), Data.new.num(idx_val.asNum().? + 1), vm);
        return true;
    }

    const phase_val = st.getRawAtom(revo.core_atoms.phase.atomId(), vm) orelse Data.new.num(0);
    var phase = phase_val.asNum().?;
    const pos_val = st.getRawAtom(revo.core_atoms.pos.atomId(), vm) orelse Data.new.num(0);
    var pos = root.numToInt(usize, pos_val.asNum().?) orelse return false;

    if (phase == 0) {
        const yielded = switch (up.tag()) {
            .string => blk: {
                const str = vm.stringValue(up.asString().?);
                if (pos >= str.len) break :blk false;
                out.* = try vm.ownDataString(str[pos .. pos + 1]);
                break :blk true;
            },
            .tuple => blk: {
                const t_id = up.asTuple().?;
                const t = vm.tuples.get(t_id) catch return false;
                if (pos >= t.items.len) break :blk false;
                out.* = t.items[pos];
                break :blk true;
            },
            .table => blk: {
                const table_id = up.asTable().?;
                const t = try vm.tables.get(table_id);
                if (pos < t.array.items.len) {
                    out.* = t.array.items[pos];
                    break :blk true;
                }
                break :blk false;
            },
            else => return false,
        };
        out_idx.* = Data.new.num(@as(f64, @floatFromInt(pos)));
        if (yielded) {
            st = try vm.tables.get(st_id);
            try st.putRawAtom(revo.core_atoms.pos.atomId(), Data.new.num(@as(f64, @floatFromInt(pos + 1))), vm);
            return true;
        }
        if (up.tag() != .table) return false;

        // array part exhausted: snapshot hash entries in insertion order
        const table_id = up.asTable().?;
        var entries = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, 0);
        defer entries.deinit(vm.runtime.alloc);
        {
            const t = try vm.tables.get(table_id);
            var hash_it = t.hash.orderedIterator();
            while (hash_it.next()) |entry| {
                const pair = try vm.tuples.create(&[_]Data{ entry.key, entry.val });
                try entries.append(vm.runtime.alloc, Data.new.tuple(pair));
            }
        }
        const entries_tuple = try vm.tuples.create(entries.items);
        st = try vm.tables.get(st_id);
        try st.putRawAtom(revo.core_atoms.entries.atomId(), Data.new.tuple(entries_tuple), vm);
        try st.putRawAtom(revo.core_atoms.phase.atomId(), Data.new.num(1), vm);
        try st.putRawAtom(revo.core_atoms.pos.atomId(), Data.new.num(0), vm);
        phase = 1;
        pos = 0;
    }

    if (phase == 1) {
        const entries_data = st.getRawAtom(revo.core_atoms.entries.atomId(), vm) orelse return false;
        const entries_id = entries_data.asTuple() orelse return false;
        const entries = vm.tuples.get(entries_id) catch return false;
        if (pos >= entries.items.len) return false;
        const pair_data = entries.items[pos];
        const pair = vm.tuples.get(pair_data.asTuple().?) catch return false;
        out.* = pair.items[1];
        out_idx.* = pair.items[0];
        st = try vm.tables.get(st_id);
        try st.putRawAtom(revo.core_atoms.pos.atomId(), Data.new.num(@as(f64, @floatFromInt(pos + 1))), vm);
        return true;
    }
    return false;
}

/// true when the function is declared with 2+ params (value + index/key)
fn passesIndex(vm: *VM, f: Data) bool {
    const fn_id = f.asFunction() orelse return false;
    const func = vm.functions.get(fn_id) catch return false;
    return func.arity() >= 2;
}

inline fn isDone(data: Data) bool {
    if (data.asAtom()) |a| return a == revo.core_atoms.atomId(.done);
    return false;
}

inline fn isTruthy(data: Data) bool {
    return !revo.isFalse(data);
}

const std = @import("std");

const revo = @import("../root.zig");
const Data = revo.Data;
const VM = revo.VM;
const api = @import("api.zig");
const root = @import("root.zig");
const mem = revo.memory;
const HostResult = root.HostResult;
const typeof = root.typeof;
const testing = revo.lang.testing;

test "iter functions" {
    try testing.topString(
        \\ iter.collect_string(iter.map("abc", fn(c) "x"))
    , "xxx");

    try testing.topString(
        \\ iter.collect_string(iter.map("", fn(c) "x"))
    , "");

    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.map({a = 1, b = 2}, fn(v) v + 10)))
    , 23);

    try testing.topNumber(
        \\ const out = {}
        \\ iter.each({a = 1, b = 2}, fn(v, k) out[k] = v + 10)
        \\ out.a
    , 11);

    try testing.topNumber(
        \\ iter.reduce((1, 2, 3, 4), fn(acc, x) acc + x, 0)
    , 10);

    try testing.topNumber(
        \\ iter.reduce(iter.map((1, 2, 3), fn(x) x * 2), fn(acc, x) acc + x, 0)
    , 12);

    try testing.topNumber(
        \\ iter.reduce("abc", fn(acc, c) acc + 1, 0)
    , 3);

    try testing.topNumber(
        \\ iter.reduce("", fn(acc, c) acc + 1, 42)
    , 42);

    try testing.topAtom(
        \\ iter.each((1, 2, 3), fn(x) x)
    , "ok");

    try testing.topAtom(
        \\ iter.each("", fn(c) c)
    , "ok");

    try testing.topNumber(
        \\ const it = iter.filter((1, 2, 3, 4, 5), fn(x) x > 3)
        \\ it() + it()
    , 9);

    try testing.topNumber(
        \\ iter.find((1, 2, 3, 4), fn(x) x > 2)
    , 3);

    try testing.topNil(
        \\ iter.find((1, 2), fn(x) x > 10)
    );

    try testing.topTrue(
        \\ iter.all?((1, 2, 3), fn(x) x > 0)
    );

    try testing.topFalse(
        \\ iter.all?((1, 2, 0), fn(x) x > 0)
    );

    try testing.topFalse(
        \\ iter.any?((1, 2), fn(x) x > 10)
    );

    try testing.topTrue(
        \\ iter.any?((0, 0, 3), fn(x) x > 2)
    );

    try testing.topTrue(
        \\ iter.all?("", fn(x) 0)
    );

    try testing.topFalse(
        \\ iter.any?("", fn(x) 0)
    );
}

test "iter lazy transforms" {
    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.take((1, 2, 3, 4), 2)))
    , 3);

    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.drop((1, 2, 3, 4), 2)))
    , 7);

    try testing.topNumber(
        \\ iter.collect(iter.take((1, 2, 3), 0)):len()
    , 0);

    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.take((1, 2), 5)))
    , 3);

    try testing.topNumber(
        \\ iter.collect(iter.drop((1, 2), 5)):len()
    , 0);

    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.flat_map((1, 2), fn(x) (x, x * 10))))
    , 33);

    try testing.topNumber(
        \\ (1, 2, 3, 4)
        \\     |> iter.map(fn(x) x * 2)
        \\     |> iter.filter(fn(x) x > 4)
        \\     |> iter.collect()
        \\     |> iter.sum()
    , 14);

    try testing.topString(
        \\ iter.collect_string(iter.filter("hello", fn(c) c != "l"))
    , "heo");
}

test "iter range" {
    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.range(5)))
    , 10);

    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.range(1, 5)))
    , 10);

    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.range(0, 10, 2)))
    , 20);

    try testing.topNumber(
        \\ iter.sum(iter.collect(iter.range(5, 0, -1)))
    , 15);

    try testing.topNumber(
        \\ let total = 0
        \\ for x in iter.range(4) do total = total + x end
        \\ total
    , 6);
}

test "iter fold count sum" {
    try testing.topNumber(
        \\ iter.fold((1, 2, 3, 4), fn(a, x) a + x)
    , 10);

    try testing.topNil(
        \\ iter.fold({}, fn(a, x) a + x)
    );

    try testing.topNumber(
        \\ iter.count((1, 2, 3, 4))
    , 4);

    try testing.topNumber(
        \\ iter.count((1, 2, 3, 4), fn(x) x > 2)
    , 2);

    try testing.topNumber(
        \\ iter.count(iter.range(10), fn(x) x % 2 == 0)
    , 5);

    try testing.topNumber(
        \\ iter.sum((1, "x", 3))
    , 4);

    try testing.topNumber(
        \\ iter.sum({a = 1, b = "y", c = 3})
    , 4);
}

test "iter index callbacks and state hiding" {
    try testing.topNumber(
        \\ let last = -1
        \\ iter.each((10, 20), fn(v, i) last = i)
        \\ last
    , 1);

    try testing.topNumber(
        \\ let total = 0
        \\ for x, i in (7, 8) do total = total + x + i end
        \\ total
    , 16);

    try testing.topNumber(
        \\ const it = iter.map((1, 2, 3), fn(x) x)
        \\ len(it:keys()) + it:len()
    , 0);

    try testing.topString(
        \\ const out = {}
        \\ iter.each({a = 1, b = 2}, fn(v, k) out:push(k))
        \\ out[0] ~ out[1]
    , ":a:b");

    try testing.topAtom(
        \\ let k = :none
        \\ iter.find({a = 1, b = 2}, fn(v, key) do k = key; :true end)
        \\ k
    , "a");
}

test "iter Host closures can allocate tables without corrupting pools" {
    // pool grew underneath them, corrupting the iterated table
    try testing.topNumber(
        \\ const xs = {}
        \\ xs:push("abc")
        \\ xs:push("")
        \\ const wrap = fn(f) do
        \\     iter.reduce(f, fn(acc, c) do acc:push(c); acc end, {})
        \\ end
        \\ iter.collect(iter.map(xs, wrap))[0]:len()
    , 3);

    try testing.topAtom(
        \\ const xs = {}
        \\ xs:push("abc")
        \\ xs:push("")
        \\ const wrap = fn(f) do
        \\     iter.reduce(f, fn(acc, c) do acc:push(c); acc end, {})
        \\     :done
        \\ end
        \\ iter.each(xs, fn(f) do wrap(f) end)
    , "ok");

    try testing.topNumber(
        \\ iter.reduce((1, 2, 3), fn(acc, n) do
        \\     const t = {}
        \\     t:push("x")
        \\     acc + 1
        \\ end, 0)
    , 3);
}
