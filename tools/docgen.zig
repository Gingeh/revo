const std = @import("std");
const revo = @import("revo");
const api = revo.std_lib.api;
const FnSpec = api.FnSpec;
const Writer = std.Io.Writer;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    try renderAll(&buf.writer, alloc);

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    try out.interface.writeAll(buf.written());
    try out.flush();
}

fn renderAll(w: *Writer, alloc: std.mem.Allocator) !void {
    var flat = std.ArrayList(*const FnSpec).empty;
    defer flat.deinit(alloc);
    for (api.all_specs) |group| {
        for (group) |*s| try flat.append(alloc, s);
    }
    for (revo.std_lib.root_specs_os) |*s| try flat.append(alloc, s);

    try renderGlobals(w, flat.items);
    try renderModules(w, flat.items, alloc);
    try renderMethods(w, flat.items, alloc);
}

fn renderGlobals(w: *Writer, specs: []*const FnSpec) !void {
    try w.writeAll("## globals\n\n");
    var n: usize = 0;
    for (specs) |s| {
        for (s.placements) |p| {
            if (p.kind == .global) {
                try renderFn(w, s.*);
                n += 1;
                break;
            }
        }
    }
    if (n == 0) try w.writeAll("(none)\n");
    try w.writeAll("\n");
}

fn renderModules(w: *Writer, specs: []*const FnSpec, alloc: std.mem.Allocator) !void {
    try w.writeAll("## modules\n\n");

    var mod_set = std.StringHashMapUnmanaged(void).empty;
    defer mod_set.deinit(alloc);
    for (specs) |s| {
        for (s.placements) |p| {
            if (p.kind == .module) try mod_set.put(alloc, p.module.?, {});
        }
    }

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(alloc);
    {
        var it = mod_set.keyIterator();
        while (it.next()) |k| try names.append(alloc, k.*);
    }
    std.mem.sort([]const u8, names.items, {}, lessStr);

    for (names.items) |mod_name| {
        try w.print("### {s}\n\n", .{mod_name});
        for (specs) |s| {
            for (s.placements) |p| {
                if (p.kind == .module and std.mem.eql(u8, p.module.?, mod_name)) {
                    try renderFn(w, s.*);
                    break;
                }
            }
        }
        try w.writeAll("\n");
    }
}

fn renderMethods(w: *Writer, specs: []*const FnSpec, alloc: std.mem.Allocator) !void {
    try w.writeAll("## methods\n\n");

    var target_set = std.StringHashMapUnmanaged(void).empty;
    defer target_set.deinit(alloc);
    for (specs) |s| {
        for (s.placements) |p| {
            if (p.kind == .method and p.target != null) {
                try target_set.put(alloc, @tagName(p.target.?), {});
            }
        }
    }

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(alloc);
    {
        var it = target_set.keyIterator();
        while (it.next()) |k| try names.append(alloc, k.*);
    }
    std.mem.sort([]const u8, names.items, {}, lessStr);

    for (names.items) |target_name| {
        try w.print("### {s} methods\n\n", .{target_name});
        var n: usize = 0;
        for (specs) |s| {
            for (s.placements) |p| {
                if (p.kind == .method and p.target != null and std.mem.eql(u8, @tagName(p.target.?), target_name)) {
                    try renderFn(w, s.*);
                    n += 1;
                    break;
                }
            }
        }
        if (n == 0) try w.writeAll("(none)\n");
        try w.writeAll("\n");
    }
}

fn renderFn(w: *Writer, spec: FnSpec) !void {
    try w.writeAll("```rb\n");
    try api.renderSignature(w, spec);
    if (spec.variadic) {
        try w.writeAll("# variadic");
    }
    try w.writeAll("\n```\n");

    if (spec.doc.len > 0) {
        try w.writeAll("\n");
        try renderDoc(w, spec.doc);
    }
    try w.writeAll("\n");
}

fn renderDoc(w: *Writer, doc: []const u8) !void {
    const trimmed = std.mem.trim(u8, doc, "\n");

    var prose: []const u8 = trimmed;
    var code: []const u8 = "";
    if (std.mem.indexOf(u8, trimmed, "\n\n")) |idx| {
        prose = trimmed[0..idx];
        code = std.mem.trim(u8, trimmed[idx + 2 ..], "\n");
    }

    // for prose each line has a single leading space from the \\ literal; strip it.
    {
        var lines = std.mem.splitScalar(u8, prose, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try w.writeAll("\n");
            first = false;
            const l = if (line.len > 0 and line[0] == ' ') line[1..] else line;
            try w.writeAll(l);
        }
        try w.writeAll("\n");
    }

    if (code.len > 0) {
        // dedent by the smallest indentation among non-blank lines
        // preserving any blank lines inside the example as-is
        var min_indent: usize = std.math.maxInt(usize);
        {
            var it = std.mem.splitScalar(u8, code, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                var n: usize = 0;
                while (n < line.len and line[n] == ' ') n += 1;
                if (n < min_indent) min_indent = n;
            }
        }
        if (min_indent == std.math.maxInt(usize)) min_indent = 0;

        try w.writeAll("\n```rb\n");
        var it = std.mem.splitScalar(u8, code, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try w.writeAll("\n");
            first = false;
            if (line.len >= min_indent) {
                try w.writeAll(line[min_indent..]);
            } else {
                try w.writeAll(line);
            }
        }
        try w.writeAll("\n```\n");
    }
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
