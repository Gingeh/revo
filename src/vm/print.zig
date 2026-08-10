const std = @import("std");

const revo = @import("revo");
const style = revo.pretty.style;

const memory = @import("memory.zig");
const Data = memory.Data;

const color_reset = "\x1b[0m";
const color_accent = "\x1b[33m"; // numbers, atoms, array indices, table keys
const color_string = "\x1b[32m"; // strings
const color_brace = "\x1b[34m"; // table braces

// backstop against unbounded recursion e.g. a __tostring/__display
// metamethod chain that keeps producing brand=new values forever. this alone
// doesnt catch true cycles gracefully (it just bails after printing
// max_write_depth levels), so it's paired with the ancestor-stack cycle
// detector below, which catches the common case (a table/tuple/struct that
// contains itself) immediately and cheaply
threadlocal var write_depth: usize = 0;
const max_write_depth: usize = 200;

// detects genuine cycles (a container that directly or indirectly contains
// itself) by tracking which containers are currently being printed, i.e. are
// ancestors of the value we're about to print. if we're asked to print a
// container that's already an active ancestor, we print "<circular>" instead
// of recursing into it again
//
// identity is tracked via the resolved pointer rather than the pool's
// internal id, so this doesn't need to know the id type, and via a kind tag
// so a table and a tuple that happen to reuse the same pool slot number
// can't be confused for each other. this is not a "seen anywhere" set -
// the same table referenced from two unrelated fields is fine and will be
// printed twice; only an actual ancestor-of-itself trips it
const ContainerKind = enum { table, tuple, struct_val };
const VisitEntry = struct { kind: ContainerKind, addr: usize };

// sized off max_write_depth just to reuse one constant; pushVisiting below
// bounds-checks against this array's actual length, so correctness doesn't
// depend on this size matching write_depth's cap
threadlocal var visiting: [max_write_depth]VisitEntry = undefined;
threadlocal var visiting_len: usize = 0;

fn isVisiting(kind: ContainerKind, addr: usize) bool {
    var i: usize = 0;
    while (i < visiting_len) : (i += 1) {
        if (visiting[i].kind == kind and visiting[i].addr == addr) return true;
    }
    return false;
}

// returns false if the stack full. bounds-checked independently of
// write_depth rather than assuming the two counters stay in lockstep;
// they don't in every path (writeTable/writeTuple can be entered
// directly, without first passing through writeData's own depth check)
fn pushVisiting(kind: ContainerKind, addr: usize) bool {
    if (visiting_len >= visiting.len) return false;
    visiting[visiting_len] = .{ .kind = kind, .addr = addr };
    visiting_len += 1;
    return true;
}

fn popVisiting() void {
    visiting_len -= 1;
}

fn styledPrint(
    writer: *std.Io.Writer,
    mode: Data.RenderMode,
    color: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) anyerror!void {
    const colored = mode == .pretty;
    if (colored) try style(writer, color);
    try writer.print(fmt, args);
    if (colored) try style(writer, color_reset);
}

fn writeEscapedString(writer: *std.Io.Writer, s: []const u8) anyerror!void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

pub fn writeData(self: Data, writer: *std.Io.Writer, vm: *revo.VM, mode: Data.RenderMode) anyerror!void {
    if (write_depth >= max_write_depth) {
        try writer.writeAll("<max-depth-exceeded>");
        return;
    }
    write_depth += 1;
    defer write_depth -= 1;

    const metamethod = switch (mode) {
        .display => try vm.getMetamethodByAtom(self, try vm.internAtom("__display")) orelse
            try vm.getMetamethodByAtom(self, revo.core_atoms.__tostring.atomId()),
        .debug => try vm.getMetamethodByAtom(self, revo.core_atoms.__debug.atomId()),
        .decimal, .pretty => null,
    };
    if (metamethod) |mm| {
        if (!mm.isFunction()) return error.TypeError;
        return writeData(try vm.callFunction(mm, &.{self}), writer, vm, mode);
    }

    switch (self.tag()) {
        .number => try styledPrint(writer, mode, color_accent, "{}", .{self.asNum().?}),
        .string => switch (mode) {
            .display => try writer.writeAll(vm.stringValue(self.asString().?)),
            .decimal => try writer.print("{}", .{try std.fmt.parseFloat(f64, vm.stringValue(self.asString().?))}),
            .debug => try writeEscapedString(writer, vm.stringValue(self.asString().?)),
            .pretty => {
                try style(writer, color_string);
                try writeEscapedString(writer, vm.stringValue(self.asString().?));
                try style(writer, color_reset);
            },
        },
        .atom => {
            if (mode == .decimal) {
                try writer.writeAll("<un-number-able>");
            } else {
                try styledPrint(writer, mode, color_accent, ":{s}", .{vm.atomName(self.asAtom().?)});
            }
        },
        .function => {
            const id = self.asFunction().?;
            const f = try vm.functions.get(id);
            switch (f.*) {
                .native => try writer.print("#fn@{}()/{}", .{ id, f.arity() }),
                .c_function => |cf| try writer.print("${s}@{}()/{}", .{ cf.name, id, f.arity() }),
                .closure => try writer.print("{s}()/{d}", .{ f.name(), f.arity() }),
            }
        },
        .table => {
            const tbl = vm.tables.get(self.asTable().?) catch {
                try writer.writeAll("<dead-table>");
                return;
            };
            tbl.write(writer, vm, mode) catch try writer.writeAll("<table-unprintable>");
        },
        .tuple => {
            const tup = vm.tuples.get(self.asTuple().?) catch {
                try writer.writeAll("<dead-tuple>");
                return;
            };
            tup.write(writer, vm, mode) catch try writer.writeAll("<tuple-unprintable>");
        },
        .struct_val => {
            const instance_id = self.asStructVal().?;
            const instance = vm.struct_instances.get(instance_id) catch {
                try writer.writeAll("<dead-struct>");
                return;
            };
            const desc = vm.struct_types.getType(instance.type_id) orelse {
                try writer.writeAll("<unknown-struct>");
                return;
            };

            const addr = @intFromPtr(instance);
            if (isVisiting(.struct_val, addr)) {
                try writer.writeAll("<circular>");
                return;
            }
            if (!pushVisiting(.struct_val, addr)) {
                try writer.writeAll("<max-depth-exceeded>");
                return;
            }
            defer popVisiting();

            try writer.writeAll(desc.name);
            try writer.writeAll("{ ");
            for (desc.fields, 0..) |f, i| {
                if (i != 0) try writer.writeAll(", ");
                try writer.writeAll(vm.atomName(f.name_atom));
                try writer.writeAll(" = ");
                try writeData(instance.fields[i], writer, vm, mode);
            }
            try writer.writeAll(" }");
        },
        .struct_type => {
            const type_id = self.asStructType().?;
            const desc = vm.struct_types.getType(type_id) orelse {
                try writer.writeAll("<unknown-type>");
                return;
            };
            try writer.writeAll("#");
            try writer.writeAll(desc.name);
        },
        .foreign => try writer.print("<foreign {*}>", .{self.asForeign().?}),
    }
}

pub fn writeTuple(t: *revo.tuple.Tuple, writer: *std.Io.Writer, vm: *revo.VM, mode: Data.RenderMode) anyerror!void {
    const addr = @intFromPtr(t);
    if (isVisiting(.tuple, addr)) {
        try writer.writeAll("<circular>");
        return;
    }
    if (!pushVisiting(.tuple, addr)) {
        try writer.writeAll("<max-depth-exceeded>");
        return;
    }
    defer popVisiting();

    try writer.writeAll("(");
    for (t.items, 0..) |item, i| {
        if (i != 0) try writer.writeAll(", ");
        try writeData(item, writer, vm, mode);
    }
    if (t.items.len == 1) try writer.writeAll(",");
    try writer.writeAll(")");
}

pub fn writeTable(tbl: *revo.table.Table, writer: *std.Io.Writer, vm: *revo.VM, mode: Data.RenderMode) anyerror!void {
    // pretty mode delegates straight to writePrettyTable, which does its own
    // cycle guarding (it's also re-entered directly by writePrettyDataValue
    // for nested tables, bypassing this function, so it has to guard itself
    // regardless, guarding here too would just double-count the top level)
    if (mode == .pretty) {
        try writePrettyTable(tbl, writer, vm, 0);
        return;
    }

    const addr = @intFromPtr(tbl);
    if (isVisiting(.table, addr)) {
        try writer.writeAll("<circular>");
        return;
    }
    if (!pushVisiting(.table, addr)) {
        try writer.writeAll("<max-depth-exceeded>");
        return;
    }
    defer popVisiting();

    try writer.writeAll("{ ");
    const should_write_idx = tbl.hash.count != 0;
    for (tbl.array.items, 0..) |val, idx| {
        if (should_write_idx) {
            try writeData(Data.new.num(idx), writer, vm, mode);
            try writer.writeAll(": ");
        }
        try writeData(val, writer, vm, mode);
        try writer.writeAll(", ");
    }
    var cur = tbl.hash.first;
    while (cur != revo.table.NULL_ID) {
        const key = tbl.hash.buckets[cur].key;
        const val = tbl.hash.buckets[cur].val;
        if (should_write_idx) {
            try writeData(key, writer, vm, mode);
            try writer.writeAll(": ");
        }
        try writeData(val, writer, vm, mode);
        try writer.writeAll(", ");
        cur = tbl.hash.buckets[cur].next;
    }
    try writer.writeAll("}");
}

fn writePrettyTable(tbl: *revo.table.Table, writer: *std.Io.Writer, vm: *revo.VM, indent_level: usize) anyerror!void {
    if (write_depth >= max_write_depth) {
        try writer.writeAll("<max-depth-exceeded>");
        return;
    }
    write_depth += 1;
    defer write_depth -= 1;

    const addr = @intFromPtr(tbl);
    if (isVisiting(.table, addr)) {
        try writer.writeAll("<circular>");
        return;
    }
    if (!pushVisiting(.table, addr)) {
        try writer.writeAll("<max-depth-exceeded>");
        return;
    }
    defer popVisiting();

    const indent = "  ";
    try style(writer, color_brace);
    try writer.writeAll("{");
    try style(writer, color_reset);
    try writer.writeAll("\n");

    for (tbl.array.items, 0..) |val, idx| {
        var i: usize = 0;
        while (i < indent_level + 1) : (i += 1) {
            try writer.writeAll(indent);
        }
        try style(writer, color_accent);
        try writer.print("[{d}]", .{idx});
        try style(writer, color_reset);
        try writer.writeAll(" = ");
        try writePrettyDataValue(val, writer, vm, indent_level + 1);
        try writer.writeAll("\n");
    }

    var cur = tbl.hash.first;
    while (cur != revo.table.NULL_ID) {
        const key = tbl.hash.buckets[cur].key;
        const val = tbl.hash.buckets[cur].val;
        var i: usize = 0;
        while (i < indent_level + 1) : (i += 1) {
            try writer.writeAll(indent);
        }
        try style(writer, color_accent);
        try writeData(key, writer, vm, .debug);
        try style(writer, color_reset);
        try writer.writeAll(" = ");
        try writePrettyDataValue(val, writer, vm, indent_level + 1);
        try writer.writeAll("\n");
        cur = tbl.hash.buckets[cur].next;
    }

    var j: usize = 0;
    while (j < indent_level) : (j += 1) {
        try writer.writeAll(indent);
    }
    try style(writer, color_brace);
    try writer.writeAll("}");
    try style(writer, color_reset);
}

fn writePrettyDataValue(val: Data, writer: *std.Io.Writer, vm: *revo.VM, indent_level: usize) anyerror!void {
    if (val.isTable()) {
        const tbl = vm.tables.get(val.asTable().?) catch {
            try writer.writeAll("<dead-table>");
            return;
        };
        try writePrettyTable(tbl, writer, vm, indent_level);
    } else {
        try writeData(val, writer, vm, .pretty);
    }
}
