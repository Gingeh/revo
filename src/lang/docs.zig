//! doc extraction and docgen markdown rendering

const std = @import("std");
const revo = @import("../root.zig");
const api = revo.std_lib.api;
const Writer = std.Io.Writer;
pub const FnSpec = api.FnSpec;
const headOf = api.headOf;

// -- [extract] ---------------------------------------------------------------

/// `#* ... *#`-attributed fn bindings and `pub declare` aliases
pub fn docsExtract(alloc: std.mem.Allocator, src: []const u8) ![]FnSpec {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try revo.lang.parseSourceReport(a, src);
    const root_node = switch (parsed) {
        .ok => |node| node,
        .err => return error.IfaceParseFailed,
    };

    const specs = try api.collectSpecs(alloc, root_node, false);
    errdefer freeSpecs(alloc, specs);

    // `__internal*` decls are runtime plumbing, not reference material
    var kept = std.ArrayList(FnSpec).empty;
    errdefer kept.deinit(alloc);
    for (specs) |s| {
        if (std.mem.startsWith(u8, s.name, "__internal")) {
            s.deinit(alloc);
            continue;
        }
        try kept.append(alloc, s);
    }
    alloc.free(specs);
    return kept.toOwnedSlice(alloc);
}

pub fn freeSpecs(alloc: std.mem.Allocator, specs: []const FnSpec) void {
    for (specs) |s| s.deinit(alloc);
    alloc.free(specs);
}

// -- [docgen] ----------------------------------------------------------------

const docgen_start_marker = "<!-- docgen:start -->";
const docgen_end_marker = "<!-- docgen:end -->";

pub fn spliceMarkdown(alloc: std.mem.Allocator, old: []const u8, body: []const u8) ![]const u8 {
    const s = std.mem.indexOf(u8, old, docgen_start_marker) orelse return error.MissingDocgenMarker;
    const e = std.mem.indexOfPos(u8, old, s + docgen_start_marker.len, docgen_end_marker) orelse return error.MissingDocgenMarker;

    return std.mem.concat(alloc, u8, &.{
        old[0..s],
        docgen_start_marker,
        "\n",
        body,
        "\n",
        docgen_end_marker,
        old[e + docgen_end_marker.len ..],
    });
}

/// render the stdlib reference: `globals`/`modules`/`methods` sections
/// with per-fn anchors, toc links, `<details>` collapsibles, and the
/// prose/code doc split. hugo-goldmark-compatible slugs
pub fn renderMarkdown(alloc: std.mem.Allocator, w: *Writer, specs: []*const FnSpec) !void {
    var slugs = SlugSet{};
    defer slugs.deinit(alloc);
    try renderGlobals(alloc, w, specs, &slugs);
    try renderModules(alloc, w, specs, &slugs);
    try renderMethods(alloc, w, specs, &slugs);
}

const Planned = struct {
    spec: *const FnSpec,
    slug: []const u8,
};

fn renderGlobals(alloc: std.mem.Allocator, w: *Writer, specs: []*const FnSpec, slugs: *SlugSet) !void {
    var planned = std.ArrayList(Planned).empty;
    defer planned.deinit(alloc);
    for (specs) |s| {
        if (headOf(s.sig).kind == .global) {
            try planned.append(alloc, .{ .spec = s, .slug = "" });
        }
    }

    try collectAndSort(alloc, &planned, slugs);
    try renderSection(w, "globals", planned.items);
}

fn renderModules(alloc: std.mem.Allocator, w: *Writer, list: []*const FnSpec, slugs: *SlugSet) !void {
    try w.writeAll("## modules\n\n");

    var mod_set = std.StringHashMapUnmanaged(void).empty;
    defer mod_set.deinit(alloc);
    for (list) |s| {
        const head = headOf(s.sig);
        if (head.kind == .module) try mod_set.put(alloc, head.module.?, {});
    }

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(alloc);
    {
        var it = mod_set.keyIterator();
        while (it.next()) |k| try names.append(alloc, k.*);
    }
    std.mem.sort([]const u8, names.items, {}, lessStr);

    for (names.items) |mod_name| {
        var planned = std.ArrayList(Planned).empty;
        defer planned.deinit(alloc);
        for (list) |s| {
            const head = headOf(s.sig);
            if (head.kind == .module and std.mem.eql(u8, head.module.?, mod_name)) {
                try planned.append(alloc, .{ .spec = s, .slug = "" });
            }
        }
        try collectAndSort(alloc, &planned, slugs);
        try renderGroup(w, mod_name, planned.items);
    }
}

fn renderMethods(alloc: std.mem.Allocator, w: *Writer, specs: []*const FnSpec, slugs: *SlugSet) !void {
    try w.writeAll("## methods\n\n");

    var target_set = std.StringHashMapUnmanaged(void).empty;
    defer target_set.deinit(alloc);
    for (specs) |s| {
        if (methodPrefix(s.sig)) |prefix| try target_set.put(alloc, prefix, {});
    }

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(alloc);
    {
        var it = target_set.keyIterator();
        while (it.next()) |k| try names.append(alloc, k.*);
    }
    std.mem.sort([]const u8, names.items, {}, lessStr);

    for (names.items) |target_name| {
        var planned = std.ArrayList(Planned).empty;
        defer planned.deinit(alloc);
        for (specs) |s| {
            if (std.mem.eql(u8, methodPrefix(s.sig) orelse "", target_name)) {
                try planned.append(alloc, .{ .spec = s, .slug = "" });
            }
        }
        try collectAndSort(alloc, &planned, slugs);
        try renderGroup(w, target_name, planned.items);
    }
}

fn methodPrefix(sig: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, sig, '(') orelse sig.len;
    const head = sig[0..end];
    const i = std.mem.indexOfScalar(u8, head, ':') orelse return null;
    return head[0..i];
}

/// a `###` group (module or target) with toc, collapsible, and `---`-separated fns
fn renderGroup(w: *Writer, title: []const u8, planned: []const Planned) !void {
    try w.print("### {s}\n\n", .{title});
    try renderToc(w, planned);
    try w.print("<details>\n<summary>{d} entries</summary>\n\n", .{planned.len});
    for (planned, 0..) |p, i| {
        try renderFn(w, p);
        if (i + 1 < planned.len) try w.writeAll("---\n\n");
    }
    try w.writeAll("</details>\n\n");
}

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
    list: *std.ArrayList(Planned),
    slugs: *SlugSet,
) !void {
    std.mem.sort(Planned, list.items, {}, struct {
        fn less(_: void, a: Planned, b: Planned) bool {
            return std.mem.order(u8, a.spec.name, b.spec.name) == .lt;
        }
    }.less);
    for (list.items) |*p| {
        p.slug = try slugs.assign(alloc, p.spec.name);
    }
}

fn renderToc(w: *Writer, planned: []const Planned) !void {
    for (planned, 0..) |p, i| {
        if (i > 0) try w.writeAll(" | ");
        try w.print("[{s}](#{s})", .{ p.spec.name, p.slug });
    }
    try w.writeAll("\n\n");
}

fn renderFn(w: *Writer, p: Planned) !void {
    const spec = p.spec;

    try w.print("#### {s}\n\n", .{spec.name});

    if (spec.is_value) {
        try w.writeAll("(value)\n\n");
    } else {
        try w.writeAll("```ruby\n");
        try w.writeAll(spec.sig);
        try w.writeAll("\n```\n\n");
    }

    if (spec.core_key) |k| try w.print("metatable key: `{s}`\n\n", .{@tagName(k)});

    if (spec.doc.len == 0) {
        try w.writeAll("> undocumented :(\n\n");
    } else {
        try renderDoc(w, spec.doc);
    }
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
        var min_indent: usize = std.math.maxInt(usize);
        var lines = std.mem.splitScalar(u8, prose, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var n: usize = 0;
            while (n < line.len and line[n] == ' ') n += 1;
            if (n < min_indent) min_indent = n;
        }
        if (min_indent == std.math.maxInt(usize)) min_indent = 0;

        var it = std.mem.splitScalar(u8, prose, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try w.writeAll("\n");
            first = false;
            try w.writeAll(if (line.len >= min_indent) line[min_indent..] else line);
        }
        try w.writeAll("\n\n");
    }

    if (code.len > 0) {
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

const SlugSet = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,

    fn deinit(self: *SlugSet, alloc: std.mem.Allocator) void {
        self.map.deinit(alloc);
    }

    fn assign(self: *SlugSet, alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
        const base = try slugify(alloc, name);
        const n = self.map.get(base) orelse 0;
        try self.map.put(alloc, base, n + 1);
        if (n == 0) return base;

        std.debug.print("docgen warning: duplicate slug \"{s}\", becomes \"{s}-{d}\"\n", .{ base, base, n });

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

pub fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// -- [test] ------------------------------------------------------------------

const testing = @import("std").testing;

test "docsExtract specs plain fn bindings" {
    const src =
        \\#* adds two *#
        \\const add = fn(a: int, b: int) a + b
        \\
        \\#* unttyped *#
        \\const laz = fn(x, y) x
        \\
        \\const hidden = fn() 1
    ;
    const specs = try docsExtract(testing.allocator, src);
    defer freeSpecs(testing.allocator, specs);
    try testing.expectEqual(@as(usize, 2), specs.len);
    try testing.expectEqualStrings("add", specs[0].name);
    try testing.expectEqualStrings("add(a: int, b: int)", specs[0].sig);
    try testing.expectEqualStrings("laz(x, y)", specs[1].sig);
    try testing.expectEqualStrings("adds two", specs[0].doc);
}

test "docsExtract specs documented non-fn bindings" {
    const src =
        \\#* a plain constant *#
        \\const a = 5
        \\
        \\#* not collected *#
        \\const hidden = 9
        \\
        \\#* typed *#
        \\const b: number = 1
    ;
    const specs = try docsExtract(testing.allocator, src);
    defer freeSpecs(testing.allocator, specs);
    try testing.expectEqual(@as(usize, 3), specs.len);
    try testing.expectEqualStrings("a", specs[0].name);
    try testing.expectEqualStrings("a", specs[0].sig);
    try testing.expectEqualStrings("a plain constant", specs[0].doc);
    try testing.expectEqualStrings("b", specs[2].name);
}

test "spliceMarkdown round trips through the markers" {
    const old =
        \\# std
        \\
        \\intro
        \\
        \\<!-- docgen:start -->
        \\stale body
        \\<!-- docgen:end -->
        \\
        \\tail
    ;
    const out = try spliceMarkdown(testing.allocator, old, "fresh");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\# std
        \\
        \\intro
        \\
        \\<!-- docgen:start -->
        \\fresh
        \\<!-- docgen:end -->
        \\
        \\tail
    , out);
    try testing.expectError(error.MissingDocgenMarker, spliceMarkdown(testing.allocator, "no markers here", "x"));
}

test "renderMarkdown emits docgen sections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const put = struct {
        fn put(alloc_in: std.mem.Allocator, list: *std.ArrayList(*const FnSpec), name: []const u8, sig: []const u8, doc: []const u8) !void {
            const s = try alloc_in.create(FnSpec);
            // SAFETY: shut up zlint
            s.* = .{ .name = name, .sig = sig, .doc = doc, .params = &.{}, .ret = "", .f = undefined };
            try list.append(alloc_in, s);
        }
    }.put;

    var list = std.ArrayList(*const FnSpec).empty;
    defer list.deinit(alloc);
    try put(alloc, &list, "floor", "floor(n: number) -> number", "rounds down");
    try put(alloc, &list, "iter.range", "iter.range(bound: number) -> function", "yields numbers");
    try put(alloc, &list, "string.len", "string.len(self: string) -> int", "counts chars");
    try put(alloc, &list, "width", "width", "how wide");
    // SAFETY: renderMarkdown never mutates specs
    @constCast(list.items[3]).is_value = true;

    var buf = Writer.Allocating.init(alloc);
    defer buf.deinit();
    try renderMarkdown(alloc, &buf.writer, list.items);
    const out = buf.written();
    try testing.expect(std.mem.indexOf(u8, out, "## globals") != null);
    try testing.expect(std.mem.indexOf(u8, out, "## modules") != null);
    try testing.expect(std.mem.indexOf(u8, out, "## methods") != null);
    try testing.expect(std.mem.indexOf(u8, out, "#### string.len") != null);
    try testing.expect(std.mem.indexOf(u8, out, "```ruby\nfloor(n: number) -> number\n```") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[floor](#floor)") != null);

    // values get a marker instead of a fn signature block
    try testing.expect(std.mem.indexOf(u8, out, "#### width\n\n(value)") != null);
}
