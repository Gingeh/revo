const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const api = @import("api.zig");

const Data = revo.Data;
const VM = revo.VM;
const HostResult = root.HostResult;

const csv = VM.csv;
const Reader = csv.Reader;
const Writer = csv.Writer;
const Record = csv.Record;

pub const impls: []const api.Impl = &.{
    .{ .name = "encode", .f = root.define(&.{.any}, encode) },
    .{ .name = "decode", .f = root.define(&.{.string}, decode) },
};

fn encode(args: []const Data, vm: *VM) !HostResult {
    var buffer = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer buffer.deinit();
    var writer = Writer.init(&buffer.writer, .{});
    try writeCsvValue(args[0], vm, &writer, false);

    const slice = try buffer.toOwnedSlice();
    const data = try vm.adoptDataString(slice);
    return root.resultTuple(vm, .ok, data);
}

fn decode(args: []const Data, vm: *VM) !HostResult {
    const source = vm.stringValue(args[0].asString().?);
    var fixed_reader = std.Io.Reader.fixed(source);
    var reader = Reader.init(&fixed_reader, .{});

    const table_id = try vm.tables.create();

    var record = Record.init(vm.runtime.alloc);
    defer record.deinit();

    while (try reader.next(&record)) {
        const data = try recordToData(record, vm);
        const table = try vm.tables.get(table_id);
        try table.push(data);
    }

    const data = Data.new.table(table_id);
    return HostResult.okData(data);
}

fn recordToData(record: Record, vm: *VM) anyerror!Data {
    const table_id = try vm.tables.create();
    const table = try vm.tables.get(table_id);
    for (0..record.len()) |i| {
        const field = record.get(i);
        const data = try fieldToData(field, vm);
        try table.array.append(vm.runtime.alloc, data);
    }
    return Data.new.table(table_id);
}

fn fieldToData(field: []const u8, vm: *VM) !Data {
    // attempt to parse a number, or just use a string
    if (std.fmt.parseInt(i64, field, 10) catch null) |num| {
        return Data.new.num(num);
    } else if (std.fmt.parseFloat(f64, field) catch null) |float| {
        return Data.new.num(float);
    } else {
        const string = try vm.ownDataString(field);
        return string;
    }
}

fn writeCsvValue(data: Data, vm: *VM, writer: *Writer, nested: bool) anyerror!void {
    switch (data.tag()) {
        .number => {
            try writeNum(data, vm, writer);
            if (!nested) try writer.terminateRecord();
        },
        .string => {
            try writeString(data, vm, writer);
            if (!nested) try writer.terminateRecord();
        },
        .atom => {
            try writeString(data, vm, writer);
            if (!nested) try writer.terminateRecord();
        },
        .table => {
            const table_id = data.asTable().?;
            const table = try vm.tables.get(table_id);
            for (table.array.items) |item| {
                try writeCsvValue(item, vm, writer, true);
            }
            try writer.terminateRecord();
        },
        .struct_val => {
            const struct_val_id = data.asStructVal().?;
            const struct_val = try vm.struct_instances.get(struct_val_id);
            for (struct_val.fields) |field| {
                try writeCsvValue(field, vm, writer, true);
            }
            try writer.terminateRecord();
        },
        .tuple => {
            const tuple_id = data.asTuple().?;
            const tuple = try vm.tuples.get(tuple_id);
            for (tuple.items) |item| {
                try writeCsvValue(item, vm, writer, true);
            }
            try writer.terminateRecord();
        },
        .struct_type => return error.UnsupportedCsvValue,
        .function => return error.UnsupportedCsvValue,
        .foreign => return error.UnsupportedCsvValue,
    }
}

fn writeString(data: Data, vm: *VM, writer: *Writer) anyerror!void {
    try writer.writeField(vm.stringValue(data.asString().?));
}

fn writeNum(data: Data, vm: *VM, writer: *Writer) anyerror!void {
    const num = data.asNum().?;
    const str = try std.fmt.allocPrint(vm.runtime.alloc, "{d}", .{num});
    defer vm.runtime.alloc.free(str);
    try writer.writeField(str);
}
