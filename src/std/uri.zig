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
    try parsePath(&uri, root_id, vm);
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
    try writePath(table, &out.writer, vm);
    try writeQuery(table, &out.writer, vm);
    try writePart(table, "fragment", "#", null, &out.writer, vm);

    const slice = try out.toOwnedSlice();
    const data = try vm.adoptDataString(slice);
    return root.resultTuple(vm, .ok, data);
}

fn writePart(table: *Table, name: []const u8, prefix: ?[]const u8, postfix: ?[]const u8, w: *std.Io.Writer, vm: *VM) !void {
    const key = try vm.internAtom(name);
    const part = table.getRawAtom(key, vm);
    if (part) |p| {
        const value_string = p.asString();
        if (value_string) |val| {
            if (prefix) |pre| try w.writeAll(pre);
            try w.writeAll(vm.stringValue(val));
            if (postfix) |post| try w.writeAll(post);
        }
    }
}

fn writePort(table: *Table, w: *std.Io.Writer, vm: *VM) !void {
    const key = try vm.internAtom("port");
    const port = table.getRawAtom(key, vm);
    if (port) |p| {
        const port_num = p.asNum();
        if (port_num) |n| {
            try w.writeAll(":");
            try w.print("{d}", .{n});
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

fn writePath(table: *Table, w: *std.Io.Writer, vm: *VM) !void {
    const key = try vm.internAtom("path");
    const path = table.getRawAtom(key, vm);
    if (path) |p| {
        const path_id = p.asTable();
        if (path_id) |p_id| {
            const path_table = try vm.tables.get(p_id);
            for (path_table.array.items) |item| {
                const item_id = item.asStr();
                if (item_id) |id| {
                    try w.writeAll("/");
                    try w.writeAll(vm.stringValue(id));
                }
            }
        }
    }
}

fn writeQuery(table: *Table, w: *std.Io.Writer, vm: *VM) !void {
    const key = try vm.internAtom("query");
    const query = table.getRawAtom(key, vm);
    if (query) |q| {
        const query_id = q.asTable();
        if (query_id) |q_id| {
            const query_table = try vm.tables.get(q_id);
            try w.writeAll("?");
            for (query_table.array.items, 0..) |item, idx| {
                const item_id = item.asStr();
                if (item_id) |id| {
                    if (idx != 0) {
                        try w.writeAll("&");
                    }
                    try w.writeAll(vm.stringValue(id));
                }
            }
            // add separator if previous items were written
            if (query_table.array.items.len > 0 and query_table.hash.count > 0) try w.writeAll("&");
            var idx: usize = 0;
            var it = query_table.hash.orderedIterator();
            while (it.next()) |param| {
                const param_key = param.key.asAtom();
                if (param_key) |k| {
                    if (idx != 0) {
                        try w.writeAll("&");
                    }
                    try w.writeAll(vm.stringValue(k));
                    try w.writeAll("=");
                    const param_val = param.val.asStr();
                    if (param_val) |val| {
                        try w.writeAll(vm.stringValue(val));
                    }
                }
                idx += 1;
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
        const raw_value = param[i + 1 ..];

        if (raw_value.len == 0) {
            try query.putRawAtom(key, Data.new.nil(), vm);
        } else {
            try query.putRawAtom(key, try vm.ownDataString(raw_value), vm);
        }
    } else {
        try query.push(try vm.ownDataString(param));
    }
}

fn parsePath(uri: *const Uri, root_id: usize, vm: *VM) !void {
    // split path into parts
    var parts = std.mem.tokenizeScalar(u8, uri.path.percent_encoded, '/');
    const table_id = try vm.tables.create();
    var path = try vm.tables.get(table_id);
    while (parts.next()) |part| {
        try path.push(try vm.ownDataString(part));
    }
    var root_table = try vm.tables.get(root_id);
    try root_table.putRawAtom(try vm.internAtom("path"), Data.new.table(table_id), vm);
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
    if (uri.port) |p| {
        const port = Data.new.num(p);
        var root_table = try vm.tables.get(root_id);
        try root_table.putRawAtom(try vm.internAtom("port"), port, vm);
    }
}

fn parseComponent(component: ?Component, name: []const u8, root_id: usize, vm: *VM) !void {
    if (component) |c| {
        const value = try vm.ownDataString(c.percent_encoded);
        var root_table = try vm.tables.get(root_id);
        try root_table.putRawAtom(try vm.internAtom(name), value, vm);
    }
}

test "encode url" {
    const src =
        \\ uri.encode({
        \\   scheme = "https",
        \\   host = "example.com",
        \\   fragment = "woah",
        \\   user = "username",
        \\   path = { "p", "TRUE" },
        \\   query = { "1", "2", chilling = "yeah" },
        \\   port = 67
        \\ })?
    ;
    try testing.topString(src, "https://username@example.com:67/p/TRUE?1&2&chilling=yeah#woah");
}
