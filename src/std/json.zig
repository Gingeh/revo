const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const api = @import("api.zig");

const Data = revo.Data;
const VM = revo.VM;
const HostResult = root.HostResult;

const json = std.json;

pub const impls: []const api.Impl = &.{
    .{ .name = "encode", .f = root.define(&.{.any}, encode) },
    .{ .name = "decode", .f = root.define(&.{.string}, decode) },
};

fn encode(args: []const Data, vm: *VM) !HostResult {
    var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer out.deinit();
    try writeJsonValue(args[0], vm, &out.writer);
    const slice = try out.toOwnedSlice();
    const data = try vm.adoptDataString(slice);
    return root.resultTuple(vm, .ok, data);
}

fn decode(args: []const Data, vm: *VM) !HostResult {
    const source = vm.stringValue(args[0].asString().?);
    var parsed = json.parseFromSlice(json.Value, vm.runtime.alloc, source, .{}) catch |err| {
        return resultErr(vm, @errorName(err));
    };
    defer parsed.deinit();

    const value = try fromJsonValue(parsed.value, vm);
    return root.resultTuple(vm, .ok, value);
}

fn resultErr(vm: *VM, message: []const u8) !HostResult {
    return root.resultTuple(vm, .err, try vm.ownDataString(message));
}

fn writeJsonValue(data: Data, vm: *VM, writer: *std.Io.Writer) anyerror!void {
    return switch (data.tag()) {
        .number => blk: {
            const n = data.asNum().?;
            if (!std.math.isFinite(n)) return error.UnsupportedJsonValue;
            if (@trunc(n) == n and @abs(n) < 9.0e18) {
                break :blk try writer.print("{d}", .{@as(i64, @intFromFloat(n))});
            }
            break :blk try writer.print("{d}", .{n});
        },
        .string => try writeJsonString(writer, vm.stringValue(data.asString().?)),
        .atom => blk: {
            const id = data.asAtom().?;
            const atom = vm.stringValue(id);
            if (std.mem.eql(u8, atom, "nil")) break :blk try writer.writeAll("null");
            if (std.mem.eql(u8, atom, "true")) break :blk try writer.writeAll("true");
            if (std.mem.eql(u8, atom, "false")) break :blk try writer.writeAll("false");
            break :blk try writeJsonString(writer, atom);
        },
        .table => try writeTableJson(data.asTable().?, vm, writer),
        .tuple => try writeTupleJson(data.asTuple().?, vm, writer),
        .function => return error.UnsupportedJsonValue,
        .struct_val => return error.UnsupportedJsonValue,
        .struct_type => return error.UnsupportedJsonValue,
        .foreign => return error.UnsupportedJsonValue,
    };
}

fn writeTupleJson(id: revo.memory.TupleID, vm: *VM, writer: *std.Io.Writer) anyerror!void {
    const tuple = try vm.tuples.get(id);
    try writeArrayJson(tuple.items, vm, writer);
}

fn writeArrayJson(items: []const Data, vm: *VM, writer: *std.Io.Writer) anyerror!void {
    try writer.writeByte('[');
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonValue(item, vm, writer);
    }
    try writer.writeByte(']');
}

fn writeTableJson(id: revo.memory.TableID, vm: *VM, writer: *std.Io.Writer) anyerror!void {
    const table = try vm.tables.get(id);
    if (table.hash.count == 0) return writeArrayJson(table.array.items, vm, writer);

    // keyed entries encoded as a json object; integer slots become "0".."n-1"
    // keys so nothing is dropped
    try writer.writeByte('{');
    var first = true;
    for (table.array.items, 0..) |item, idx| {
        if (!first) try writer.writeByte(',');
        first = false;
        var buf: [20]u8 = undefined;
        const key_str = try std.fmt.bufPrint(&buf, "{d}", .{idx});
        try writeJsonString(writer, key_str);
        try writer.writeByte(':');
        try writeJsonValue(item, vm, writer);
    }

    const entries = try table.keyedEntries(vm.runtime.alloc);
    defer vm.runtime.alloc.free(entries);
    for (entries) |entry| {
        if (!first) try writer.writeByte(',');
        first = false;
        const key_str = switch (entry.key.tag()) {
            .atom => vm.stringValue(entry.key.asAtom().?),
            .string => vm.stringValue(entry.key.asString().?),
            else => return error.UnsupportedJsonValue,
        };
        try writeJsonString(writer, key_str);
        try writer.writeByte(':');
        try writeJsonValue(entry.value, vm, writer);
    }
    try writer.writeByte('}');
}

fn writeJsonString(writer: *std.Io.Writer, str: []const u8) anyerror!void {
    try writer.writeByte('"');
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => if (c < 0x20)
                try writer.print("\\u{x:0>4}", .{c})
            else
                try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn fromJsonValue(value: json.Value, vm: *VM) anyerror!Data {
    return switch (value) {
        .null => revo.Data.new.core(.nil),
        .bool => |b| Data.new.boolean(b),
        .integer => |n| Data.new.num(n),
        .float => |n| Data.new.num(n),
        .number_string => |s| Data.new.num(try std.fmt.parseFloat(f64, s)),
        .string => |s| try vm.ownDataString(s),
        .array => |array| try arrayToData(array.items, vm),
        .object => |object| try objectToData(object, vm),
    };
}

fn arrayToData(items: []const json.Value, vm: *VM) anyerror!Data {
    var tuples = try std.ArrayList(Data).initCapacity(vm.runtime.alloc, items.len);
    defer tuples.deinit(vm.runtime.alloc);
    for (items) |item| try tuples.append(vm.runtime.alloc, try fromJsonValue(item, vm));
    return Data.new.tuple(try vm.tuples.create(tuples.items));
}

fn objectToData(object: json.ObjectMap, vm: *VM) anyerror!Data {
    const table_id = try vm.tables.create();
    const table = try vm.tables.get(table_id);
    var it = object.iterator();
    while (it.next()) |entry| {
        try table.putRawAtom(try vm.internAtom(entry.key_ptr.*), try fromJsonValue(entry.value_ptr.*, vm), vm);
    }
    return Data.new.table(table_id);
}

test "json encode and decode round trip" {
    const testing = revo.lang.testing;

    try testing.topString(
        \\ json.encode(("a", "b", "c")):unwrap()
    , "[\"a\",\"b\",\"c\"]");

    try testing.topNumber(
        \\ json.decode("{{ \"a\" : 1}}"):unwrap().a
    , 1);
}
