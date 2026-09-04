const std = @import("std");
const revo = @import("../root.zig");
const root = @import("root.zig");
const api = @import("api.zig");

const Data = revo.Data;
const testing = revo.lang.testing;
const VM = revo.VM;
const HostResult = root.HostResult;
const Uri = std.Uri;
const Component = std.Uri.Component;
const Table = revo.table.Table;

pub const impls: []const api.Impl = &.{
    .{ .name = "decode", .f = root.define(&.{.any}, decode) },
    .{ .name = "encode", .f = root.define(&.{.any}, encode) },
};

fn decode(args: []const Data, vm: *VM) !HostResult {
    const source = vm.stringValue(args[0].asString().?);
    const uri = try std.Uri.parse(source);
    const root_id = try vm.tables.create();

    try parseScheme(&uri, root_id, vm);
    try parseComponent(uri.host, "host", root_id, vm);
    try parseComponent(uri.fragment, "fragment", root_id, vm);
    try parseComponent(uri.user, "user", root_id, vm);
    try parseComponent(uri.path, "path", root_id, vm);
    try parseQuery(&uri, root_id, vm);
    try parsePort(&uri, root_id, vm);

    const data = Data.new.table(root_id);
    return HostResult.okData(data);
}

fn encode(args: []const Data, vm: *VM) !HostResult {
    var out = std.Io.Writer.Allocating.init(vm.runtime.alloc);
    defer out.deinit();
    const table = try vm.tables.get(args[0].asTable().?);

    try writePart(table, "scheme", null, ":", &out.writer, vm);
    try writeAuthority(table, &out.writer, vm);
    try writePart(table, "user", null, "@", &out.writer, vm);
    try writePart(table, "host", null, null, &out.writer, vm);
    try writePort(table, &out.writer, vm);
    try writePart(table, "path", null, null, &out.writer, vm);
    try writeQuery(table, &out.writer, vm);
    try writePart(table, "fragment", "#", null, &out.writer, vm);

    const slice = try out.toOwnedSlice();
    const data = try vm.adoptDataString(slice);
    return root.resultTuple(vm, .ok, data);
}

fn writePart(table: *Table, name: []const u8, prefix: ?[]const u8, postfix: ?[]const u8, w: *std.Io.Writer, vm: *VM) !void {
    const key = try vm.internAtom(name);
    if (table.getRawAtom(key, vm)) |part| {
        if (part.asString()) |val| {
            if (prefix) |pre| try w.writeAll(pre);
            try w.writeAll(vm.stringValue(val));
            if (postfix) |post| try w.writeAll(post);
        }
    }
}

fn writePort(table: *Table, w: *std.Io.Writer, vm: *VM) !void {
    const key = try vm.internAtom("port");
    if (table.getRawAtom(key, vm)) |port| {
        if (port.asNum()) |num| {
            try w.writeAll(":");
            try w.print("{d}", .{num});
        }
    }
}

/// write `//` if a user or host exist to indicate the start of the authority
fn writeAuthority(table: *Table, w: *std.Io.Writer, vm: *VM) !void {
    const user_id = try vm.internAtom("user");
    const host_id = try vm.internAtom("host");

    if (table.getRawAtom(user_id, vm) != null or table.getRawAtom(host_id, vm) != null) {
        try w.writeAll("//");
    }
}

fn writeQuery(table: *Table, w: *std.Io.Writer, vm: *VM) !void {
    if (table.getRawAtom(try vm.internAtom("query"), vm)) |query| {
        if (query.asTable()) |query_id| {
            const query_table = try vm.tables.get(query_id);
            try w.writeAll("?");
            var first = true;
            try writeArrayQuery(query_table, w, &first, vm);
            try writeHashQuery(query_table, w, &first, vm);
        }
    }
}

fn writeArrayQuery(table: *Table, w: *std.Io.Writer, first: *bool, vm: *VM) !void {
    for (table.array.items) |item| {
        const item_id = item.asStr();
        const num_id = item.asNum();
        if ((item_id != null or num_id != null) and !first.*) {
            try w.writeAll("&");
        }
        if (num_id) |id| {
            try w.print("{d}", .{id});
            first.* = false;
        } else if (item_id) |id| {
            try w.writeAll(vm.stringValue(id));
            first.* = false;
        }
    }
}

fn writeHashQuery(table: *Table, w: *std.Io.Writer, first: *bool, vm: *VM) !void {
    var it = table.hash.orderedIterator();
    while (it.next()) |param| {
        if (param.key.asAtom()) |key| {
            if (param.val.asTable()) |param_id| {
                if (vm.tables.get(param_id)) |param_table| {
                    for (param_table.array.items) |item| {
                        if (!first.*) try w.writeAll("&");
                        try w.writeAll(vm.stringValue(key));
                        try w.writeAll("=");

                        if (item.asStr()) |val| {
                            try w.writeAll(vm.stringValue(val));
                        } else if (item.asNum()) |val| {
                            try w.print("{d}", .{val});
                        }
                        first.* = false;
                    }
                } else |_| {}
            } else {
                if (!first.*) try w.writeAll("&");
                try w.writeAll(vm.stringValue(key));
                try w.writeAll("=");

                if (param.val.asStr()) |val| {
                    try w.writeAll(vm.stringValue(val));
                } else if (param.val.asNum()) |val| {
                    try w.print("{d}", .{val});
                }
                first.* = false;
            }
        }
    }
}

fn parseScheme(uri: *const Uri, root_id: usize, vm: *VM) !void {
    var root_table = try vm.tables.get(root_id);
    try root_table.putRawAtom(try vm.internAtom("scheme"), try vm.ownDataString(uri.scheme), vm);
}

fn parseParam(param: []const u8, query_id: usize, vm: *VM) !void {
    var query = try vm.tables.get(query_id);
    if (std.mem.indexOfScalar(u8, param, '=')) |i| {
        const raw_key = param[0..i];
        const key = try vm.internAtom(raw_key);
        const val = param[i + 1 ..];
        const data = if (val.len == 0) Data.new.nil() else try valData(val, vm);
        if (query.getRawAtom(key, vm)) |existing| {
            // key exists, add to or create a table
            if (existing.asTable()) |id| {
                var table = try vm.tables.get(id);
                try table.push(data);
            } else {
                const id = try vm.tables.create();
                var table = try vm.tables.get(id);

                try table.push(existing);
                try table.push(data);
                try query.putRawAtom(key, Data.new.table(id), vm);
            }
        } else {
            try query.putRawAtom(key, data, vm);
        }
    } else {
        try query.push(try vm.ownDataString(param));
    }
}

fn valData(val: []const u8, vm: *VM) !Data {
    const num = std.fmt.parseFloat(f64, val) catch return try vm.ownDataString(val);
    return Data.new.num(num);
}

fn parseQuery(uri: *const Uri, root_id: usize, vm: *VM) !void {
    if (uri.query) |query| {
        // parse query parameters
        var params = std.mem.tokenizeScalar(u8, query.percent_encoded, '&');
        const table_id = try vm.tables.create();
        while (params.peek() != null) {
            const param = params.next().?;
            try parseParam(param, table_id, vm);
        }
        var root_table = try vm.tables.get(root_id);
        try root_table.putRawAtom(try vm.internAtom("query"), Data.new.table(table_id), vm);
    }
}

fn parsePort(uri: *const Uri, root_id: usize, vm: *VM) !void {
    if (uri.port) |port| {
        const port_data = Data.new.num(port);
        var root_table = try vm.tables.get(root_id);
        try root_table.putRawAtom(try vm.internAtom("port"), port_data, vm);
    }
}

fn parseComponent(component: ?Component, name: []const u8, root_id: usize, vm: *VM) !void {
    if (component) |c| {
        const key = try vm.internAtom(name);
        const value = try vm.ownDataString(c.percent_encoded);
        var root_table = try vm.tables.get(root_id);
        try root_table.putRawAtom(key, value, vm);
    }
}

test "encode url" {
    const src =
        \\ uri.encode({
        \\   scheme = "https",
        \\   host = "example.com",
        \\   fragment = "woah",
        \\   user = "username",
        \\   path = "/p/TRUE",
        \\   query = { "1", "2", chilling = "yeah", t = { "y", "n" } },
        \\   port = 67
        \\ })?
    ;
    try testing.topString(src, "https://username@example.com:67/p/TRUE?1&2&chilling=yeah&t=y&t=n#woah");
}
