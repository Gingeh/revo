const std = @import("std");
const revo = @import("revo");
const api = revo.std_lib.api;
const FnSpec = api.FnSpec;
const Writer = std.Io.Writer;

const start_marker = "<!-- docgen:start -->";
const end_marker = "<!-- docgen:end -->";

const Planned = struct {
    spec: *const FnSpec,
    slug: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var arena_i = std.heap.ArenaAllocator.init(alloc);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const stdin_file = std.Io.File.stdin();
    if (try stdin_file.isTty(init.io)) {
        var msg_buf: [512]u8 = undefined;
        var msg = std.Io.File.stderr().writer(init.io, &msg_buf);
        try msg.interface.writeAll(
            \\ docgen: pipe a markdown file in
            \\ like `zig build docs < std.md > /tmp/std.new && mv /tmp/std.new std.md`
        );
        try msg.flush();
        std.process.exit(1);
    }

    const old = try std.Io.Dir.cwd().readFileAlloc(init.io, "/dev/stdin", arena, std.Io.Limit.unlimited);

    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();
    try renderBody(alloc, arena, init.io, &buf.writer);

    const target = try splice(arena, old, std.mem.trim(u8, buf.written(), "\n"));

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    try out.interface.writeAll(target);
    try out.flush();
}

fn splice(alloc: std.mem.Allocator, old: []const u8, body: []const u8) ![]const u8 {
    const s = std.mem.indexOf(u8, old, start_marker) orelse return error.MissingDocgenMarker;
    const e = std.mem.indexOfPos(u8, old, s + start_marker.len, end_marker) orelse return error.MissingDocgenMarker;
    return std.mem.concat(alloc, u8, &.{
        old[0..s],
        start_marker,
        "\n",
        body,
        "\n",
        end_marker,
        old[e + end_marker.len ..],
    });
}

fn renderBody(alloc: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, w: *Writer) !void {
    var flat = std.ArrayList(*const FnSpec).empty;
    defer flat.deinit(alloc);
    for (api.full_specs) |group| {
        for (group) |*s| try flat.append(alloc, s);
    }

    var slugs = SlugSet{};
    defer slugs.deinit(arena);
    // globals
    var planned = std.ArrayList(Planned).empty;
    defer planned.deinit(alloc);
    for (&slugs) |s| {
        for (s.placements) |p| {
            if (p.kind == .global) {
                try planned.append(alloc, .{ .spec = s, .slug = try slugs.assign(alloc, arena, io, s.name) });
                break;
            }
        }
    }

    try collectAndSort(alloc, arena, io, &planned, slugs);
    try renderSection(w, "globals", planned.items);
    try renderModules(alloc, arena, io, w, flat.items, &slugs);
    try renderMethods(alloc, arena, io, w, flat.items, &slugs);
}

// -- [section rendering] -----------------------------------------------------

fn renderSection(
    w: *Writer,
    title: []const u8,
    planned: []const Planned,
) !void {
    try w.print("## {s}\n\n", .{title});
    if (planned.len == 0) {
        try w.writeAll("(none)\n\n");
        return;
    }
    try renderToc(w, planned);
    try w.print("<details>\n<summary>{d} entries</summary>\n\n", .{planned.len});
    for (planned, 0..) |p, i| {
        try renderFn(w, p);
        if (i + 1 < planned.len) try w.writeAll("---\n\n");
    }
    try w.writeAll("</details>\n\n");
}

fn collectAndSort(
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    list: *std.ArrayList(Planned),
    slugs: *SlugSet,
) !void {
    std.mem.sort(Planned, list.items, {}, struct {
        fn less(_: void, a: Planned, b: Planned) bool {
            return std.mem.order(u8, a.spec.name, b.spec.name) == .lt;
        }
    }.less);
    for (list.items) |*p| {
        p.slug = try slugs.assign(alloc, arena, io, p.spec.name);
    }
}

// -- [section collectors] ----------------------------------------------------

fn renderModules(alloc: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, w: *Writer, list: []*const FnSpec, slugs: *SlugSet) !void {
    try w.writeAll("## modules\n\n");

    var mod_set = std.StringHashMapUnmanaged(void).empty;
    defer mod_set.deinit(alloc);
    for (list) |s| {
        for (s.placements) |p| {
            if (p.kind == .module) try mod_set.put(alloc, p.module.?, {});
        }
    }

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(alloc);
    var it = mod_set.keyIterator();
    while (it.next()) |k| try names.append(alloc, k.*);

    std.mem.sort([]const u8, names.items, {}, lessStr);
    for (names.items) |mod_name| {
        try w.print("### {s}\n\n", .{mod_name});
        var planned = std.ArrayList(Planned).empty;
        defer planned.deinit(alloc);

        for (list) |s| {
            for (s.placements) |p| {
                if (p.kind == .module and std.mem.eql(u8, p.module.?, mod_name)) {
                    try planned.append(alloc, .{ .spec = s, .slug = try slugs.assign(alloc, arena, io, s.name) });
                    break;
                }
            }
        }

        try collectAndSort(alloc, arena, io, &planned, slugs);
        if (planned.items.len == 0) {
            try w.writeAll("(none)\n\n");
        } else {
            try renderToc(w, planned.items);
            try w.print("<details>\n<summary>{d} entries</summary>\n\n", .{planned.items.len});
            for (planned.items, 0..) |p, i| {
                try renderFn(w, p);
                if (i + 1 < planned.items.len) try w.writeAll("---\n\n");
            }

            try w.writeAll("</details>\n\n");
        }
    }
}

fn renderMethods(alloc: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, w: *Writer, specs: []*const FnSpec, slugs: *SlugSet) !void {
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
        try w.print("### {s}\n\n", .{target_name});
        var planned = std.ArrayList(Planned).empty;
        defer planned.deinit(alloc);
        for (specs) |s| {
            for (s.placements) |p| {
                if (p.kind == .method and p.target != null and std.mem.eql(u8, @tagName(p.target.?), target_name)) {
                    try planned.append(alloc, .{ .spec = s, .slug = try slugs.assign(alloc, arena, io, s.name) });
                    break;
                }
            }
        }
        try collectAndSort(alloc, arena, io, &planned, slugs);
        if (planned.items.len == 0) {
            try w.writeAll("(none)\n\n");
        } else {
            try renderToc(w, planned.items);
            try w.print("<details>\n<summary>{d} entries</summary>\n\n", .{planned.items.len});
            for (planned.items, 0..) |p, i| {
                try renderFn(w, p);
                if (i + 1 < planned.items.len) try w.writeAll("---\n\n");
            }
            try w.writeAll("</details>\n\n");
        }
    }
}

// -- [helpers] ---------------------------------------------------------------

fn renderToc(w: *Writer, planned: []const Planned) !void {
    for (planned, 0..) |p, i| {
        if (i > 0) try w.writeAll(" | ");
        try w.print("[{s}](#{s})", .{ p.spec.name, p.slug });
    }
    try w.writeAll("\n\n");
}

fn renderFn(w: *Writer, p: Planned) !void {
    const spec = p.spec;

    // heading
    try w.print("#### {s} <a href=\"#{s}\" class=\"anchor\">#</a>\n", .{ p.spec.name, p.slug });

    // ruby because we dont need the editor but need highlighter
    try w.writeAll("```ruby\n");
    try renderSig(w, spec.*);
    try w.writeAll("\n```\n\n");

    if (spec.core_key) |k| try w.print("metatable key: `{s}`\n\n", .{@tagName(k)});

    if (spec.doc.len == 0) {
        try w.writeAll("> undocumented :(\n\n");
    } else {
        try renderDoc(w, spec.doc);
    }
}

fn renderSig(w: *Writer, spec: FnSpec) !void {
    try w.print("{s}(", .{spec.name});
    for (spec.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{s}: {s}", .{ p[0], p[1] });
        if (spec.variadic and i + 1 == spec.params.len and !std.mem.endsWith(u8, p[1], "...")) try w.writeAll("...");
    }
    try w.writeAll(")");
    if (spec.ret.len > 0) try w.print(" -> {s}", .{spec.ret});
}

fn renderDoc(w: *Writer, doc: []const u8) !void {
    const trimmed = std.mem.trim(u8, doc, "\n");

    var prose: []const u8 = trimmed;
    var code: []const u8 = "";
    if (std.mem.indexOf(u8, trimmed, "\n\n")) |idx| {
        prose = trimmed[0..idx];
        code = std.mem.trim(u8, trimmed[idx + 2 ..], "\n");
    }

    {
        var lines = std.mem.splitScalar(u8, prose, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try w.writeAll("\n");
            first = false;
            const l = if (line.len > 0 and line[0] == ' ') line[1..] else line;
            try w.writeAll(l);
        }
        try w.writeAll("\n\n");
    }

    if (code.len > 0) {
        // dedent by the smallest indentation among non-blank lines
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

        try w.writeAll("```revo\n");
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
        try w.writeAll("\n```\n\n");
    }
}

// -- [slugs and collisions] --------------------------------------------------

const SlugSet = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,

    fn deinit(self: *SlugSet, alloc: std.mem.Allocator) void {
        self.map.deinit(alloc);
    }

    fn assign(self: *SlugSet, alloc: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
        const n = self.map.get(name) orelse 0;
        try self.map.put(alloc, name, n + 1);
        const base = try slugify(arena, name);
        if (n == 0) return base;

        var err_buf: [256]u8 = undefined;
        var ew = std.Io.File.stderr().writer(io, &err_buf);

        ew.interface.print("docgen warning: duplicate name \"{s}\", slug becomes \"{s}-{d}\"\n", .{ name, base, n }) catch {};
        ew.flush() catch {};

        return std.fmt.allocPrint(alloc, "{s}-{d}", .{ base, n });
    }
};

fn slugify(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try out.append(alloc, std.ascii.toLower(c));
        } else if (c == '_' or c == '-') {
            try out.append(alloc, c);
        } else if (c == ' ') {
            try out.append(alloc, '-');
        }
    }

    if (out.items.len == 0) try out.appendSlice(alloc, "anonymous");
    return out.toOwnedSlice(alloc);
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
