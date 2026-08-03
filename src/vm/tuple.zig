const std = @import("std");

const revo = @import("revo");

const memory = revo.memory;
const Data = revo.Data;
const testing = revo.lang.testing;
const pool = @import("pool.zig");

pub const Tuple = struct {
    alloc: std.mem.Allocator,
    items: []Data,
    metatable: ?memory.TableID = null,

    pub fn deinit(self: *Tuple) void {
        self.alloc.free(self.items);
    }

    pub fn write(self: *Tuple, writer: *std.Io.Writer, vm: *revo.VM, mode: Data.RenderMode) anyerror!void {
        return revo.vm.print.writeTuple(self, writer, vm, mode);
    }
};

pub const TuplePool = struct {
    alloc: std.mem.Allocator,
    tuples: std.ArrayList(?Tuple),
    marks: std.DynamicBitSet,
    dead: std.ArrayList(memory.TupleID),
    first: usize = pool.end,
    last: usize = pool.end,
    next: std.ArrayList(usize),

    pub fn init(alloc: std.mem.Allocator) !TuplePool {
        return TuplePool{
            .alloc = alloc,
            .tuples = try .initCapacity(alloc, 4),
            .marks = try .initEmpty(alloc, 64),
            .dead = .empty,
            .next = try .initCapacity(alloc, 4),
        };
    }

    pub fn deinit(self: *TuplePool) void {
        for (self.tuples.items) |*maybe_t| {
            if (maybe_t.*) |*t| t.deinit();
        }
        self.tuples.deinit(self.alloc);
        self.marks.deinit();
        self.dead.deinit(self.alloc);
        self.next.deinit(self.alloc);
    }

    pub fn create(self: *TuplePool, items: []const Data) !memory.TupleID {
        const owned = try self.alloc.dupe(Data, items);
        errdefer self.alloc.free(owned);
        return pool.create(
            self.alloc,
            Tuple,
            memory.TupleID,
            &self.tuples,
            &self.marks,
            &self.dead,
            &self.first,
            &self.last,
            &self.next,
            .{ .alloc = self.alloc, .items = owned },
        );
    }

    pub fn get(self: *TuplePool, id: memory.TupleID) !*Tuple {
        if (id >= self.tuples.items.len) return error.InvalidTuple;
        if (self.tuples.items[id]) |*t| return t;
        return error.InvalidTuple;
    }

    pub fn mark(self: *TuplePool, id: memory.TupleID, vm: *revo.VM) void {
        if (id >= self.tuples.items.len) return;
        if (self.marks.isSet(id)) return;
        if (self.tuples.items[id] == null) return;
        self.marks.set(id);
        vm.pushMarkTuple(id);
    }

    pub fn sweep(self: *TuplePool) void {
        pool.sweep(
            self.alloc,
            Tuple,
            memory.TupleID,
            &self.tuples,
            &self.marks,
            &self.dead,
            &self.first,
            &self.last,
            &self.next,
            freeTuple,
        );
    }

    pub fn bytes(self: *const TuplePool) usize {
        var total: usize = 0;
        var id = self.first;
        while (id != pool.end) {
            const t = self.tuples.items[id].?;
            total += 32;
            total += @sizeOf(Data) * t.items.len;
            id = self.next.items[id];
        }
        return total;
    }

    pub fn clearMarks(self: *TuplePool) void {
        self.marks.unmanaged.unsetAll();
    }

    pub fn capacity(self: *const TuplePool) usize {
        return self.tuples.items.len;
    }
};

fn freeTuple(t: *Tuple, _: std.mem.Allocator) ?Tuple {
    t.deinit();
    return null;
}

test "parses tuple literals and keeps paren grouping distinct" {
    try testing.expectPrinted("(1, 2, 3)", "(tuple 1 2 3)");
    try testing.expectPrinted("(_, x)", "(tuple _ x)");
    try testing.expectPrinted("(1,)", "(tuple 1)");
    try testing.expectPrinted("(1)", "1");
    try testing.topNil("()");
}

test "parses tuple destructuring in bindings assignment and match" {
    try testing.expectPrinted(
        \\ const a, b = (:ok, "value")
        \\ (a, b) = (:err, "other")
        \\ match (:ok, "x")
        \\ | (:ok, value) => value
        \\ | (:err, err) => err
    , "(block (binding (tuple-pattern a b) (tuple :ok \"value\")) (assign " ++
        "(tuple-pattern a b) (tuple :err \"other\")) " ++
        "(match (tuple :ok \"x\") (arm (tuple-pattern :ok value) value) (arm (tuple-pattern :err err) err)))");
}

test "tuple destructuring ignores extras but errors when too short" {
    try testing.topNumber(
        \\ const a, b = (1, 2, 3)
        \\ a + b
    , 3);
}

test "tuple destructuring" {
    try testing.topTrue(":true");
}

test "tuple destructuring assmt doesnt die" {
    try testing.topNumber(
        \\ let (a, b) = (1, 2)
        \\ a = 123
        \\ a
    , 123);
    try testing.topNumber(
        \\ let (a, b) = (1, 2)
        \\ b
    , 2);
    try testing.topNumber(
        \\ const (a, b) = (1, 2)
        \\ b
    , 2);
    try testing.topNumber(
        \\ const a, b = (1, 2)
        \\ b
    , 2);
}

test "tuple length" {
    try testing.topNumber(
        \\ const t = (1, 2, 3, 4, 5)
        \\ len(t)
    , 5);
}
