const std = @import("std");
const lsp = @import("lsp");
const revo = @import("revo");

const T = lsp.types;
const Lexer = revo.lang.Lexer;
const Workspace = revo.lang.Workspace;

const keywords = Lexer.TokenType.of_string.keys();

const CallSig = struct {
    detail: []const u8,
    insert_text: []const u8,
    format: T.InsertTextFormat,
};

/// `detail` = name(p1: t1, ...) -> ret, `insert_text` = snippet name(${1:p1}, ...)
fn callSignature(
    arena: std.mem.Allocator,
    name: []const u8,
    param_names: []const []const u8,
    param_types: []const []const u8,
    ret: ?[]const u8,
) !CallSig {
    var buf = std.Io.Writer.Allocating.init(arena);
    try buf.writer.print("{s}(", .{name});
    for (param_names, 0..) |n, i| {
        if (i > 0) try buf.writer.print(", ", .{});
        try buf.writer.print("{s}: {s}", .{ n, param_types[i] });
    }
    try buf.writer.print(")", .{});
    if (ret) |r| try buf.writer.print(" -> {s}", .{r});
    const detail = buf.written();

    if (param_names.len == 0) return .{
        .detail = detail,
        .insert_text = try std.fmt.allocPrint(arena, "{s}()", .{name}),
        .format = .PlainText,
    };

    var sbuf = std.Io.Writer.Allocating.init(arena);
    try sbuf.writer.print("{s}(", .{name});
    for (param_names, 1..) |n, i| {
        if (i > 1) try sbuf.writer.print(", ", .{});
        try sbuf.writer.writeByte('$');
        try sbuf.writer.writeByte('{');
        try sbuf.writer.print("{d}", .{i});
        try sbuf.writer.writeByte(':');
        try sbuf.writer.print("{s}", .{n});
        try sbuf.writer.writeByte('}');
    }
    try sbuf.writer.print(")", .{});
    return .{ .detail = detail, .insert_text = sbuf.written(), .format = .Snippet };
}

/// complete identifiers at cursor position in `text`
pub fn completions(
    vm: *revo.VM,
    workspace: *Workspace.Workspace,
    arena: std.mem.Allocator,
    file_id: Workspace.FileId,
    text: []const u8,
    cursor_off: usize,
) !T.completion.Result {
    // scan backward from cursor to find prefix start
    var start = cursor_off;
    while (start > 0 and Lexer.isIdentContinue(text[start - 1])) start -= 1;
    const prefix = text[start..cursor_off];

    // check for '.' before the prefix (field completion)
    const dot_target = if (start > 0 and text[start - 1] == '.') blk: {
        var dot_start = start - 1;
        while (dot_start > 0 and Lexer.isIdentContinue(text[dot_start - 1])) dot_start -= 1;
        break :blk text[dot_start .. start - 1];
    } else null;

    var items = std.ArrayList(T.completion.Item).initCapacity(arena, 128) catch {
        return T.completion.Result{ .completion_items = &.{} };
    };

    if (dot_target) |target| {
        try addFieldCompletions(vm, workspace, arena, &items, target, prefix, file_id);
    } else {
        try addGeneralCompletions(vm, workspace, arena, &items, prefix, file_id);
    }

    return T.completion.Result{ .completion_items = items.items };
}

/// completions for fields of a table or struct (after a dot)
fn addFieldCompletions(
    vm: *revo.VM,
    workspace: *Workspace,
    arena: std.mem.Allocator,
    items: *std.ArrayList(T.completion.Item),
    target: []const u8,
    prefix: []const u8,
    file_id: Workspace.FileId,
) !void {
    const target_atom = vm.internAtom(target) catch return;
    // stdlib modules registered as globals (string, table, math, etc.)
    if (vm.globals.get(target_atom)) |val| {
        if (val.isTable()) {
            const table = try vm.tables.get(val.asTable().?);
            var hash_it = table.hash.orderedIterator();
            while (hash_it.next()) |entry| {
                if (entry.key.isAtom()) {
                    const name = vm.atomName(entry.key.asAtom().?);
                    if (std.mem.startsWith(u8, name, prefix)) {
                        items.append(arena, .{
                            .label = name,
                            .kind = .Field,
                        }) catch return;
                    }
                }
            }
            return;
        }
    }
    // user-imported modules (e.g. `import "one.rv"` creates a local binding)
    const imported_syms = workspace.importedModuleSymbols(arena, file_id, target) catch return;
    for (imported_syms) |sym| {
        if (std.mem.startsWith(u8, sym.name, prefix)) {
            items.append(arena, .{
                .label = sym.name,
                .kind = .Field,
            }) catch return;
        }
    }
}

/// completions from keywords, globals, and document symbols
fn addGeneralCompletions(
    vm: *revo.VM,
    workspace: *Workspace,
    arena: std.mem.Allocator,
    items: *std.ArrayList(T.completion.Item),
    prefix: []const u8,
    file_id: Workspace.FileId,
) !void {
    // keywords
    inline for (keywords) |kw| {
        if (std.mem.startsWith(u8, kw, prefix)) {
            items.append(arena, .{ .label = kw, .kind = .Keyword }) catch return;
        }
    }

    // globals from vm (stdlib + user)
    {
        var git = vm.globals.iterator();
        while (git.next()) |entry| {
            const name = vm.atomName(entry.key_ptr.*);
            if (!std.mem.startsWith(u8, name, prefix)) continue;
            const kind: ?T.completion.Item.Kind = if (entry.value_ptr.isFunction())
                .Function
            else if (entry.value_ptr.isTable())
                .Module
            else if (entry.value_ptr.isStructType())
                .Struct
            else
                .Variable;

            var insert_text: ?[]const u8 = null;
            var insert_text_format: ?T.InsertTextFormat = null;
            var detail: ?[]const u8 = null;
            var doc_copy: ?[]const u8 = null;

            if (entry.value_ptr.isFunction()) {
                if (revo.std_lib.api.find(name)) |spec| {
                    doc_copy = if (spec.doc.len > 0) (arena.dupe(u8, spec.doc) catch null) else null;
                    const names = try arena.alloc([]const u8, spec.params.len);
                    const types = try arena.alloc([]const u8, spec.params.len);
                    for (spec.params, 0..) |p, i| {
                        names[i] = p[0];
                        types[i] = p[1];
                    }
                    const sig = try callSignature(
                        arena,
                        name,
                        names,
                        types,
                        if (spec.ret.len > 0) spec.ret else null,
                    );
                    detail = sig.detail;
                    insert_text = sig.insert_text;
                    insert_text_format = sig.format;
                }
            }

            items.append(arena, .{
                .label = name,
                .kind = kind,
                .detail = detail,
                .insertText = insert_text,
                .insertTextFormat = insert_text_format,
                .documentation = if (doc_copy) |d|
                    .{ .markup_content = .{ .kind = .markdown, .value = d } }
                else
                    null,
            }) catch return;
        }
    }

    // document-local symbols (from inspect cache)
    {
        var analysis = workspace.inspectDetailed(arena, file_id, .{}) catch return;
        defer analysis.deinit(arena);
        for (analysis.symbols) |sym| {
            if (!std.mem.startsWith(u8, sym.name, prefix)) continue;
            const kind: T.completion.Item.Kind = switch (sym.kind) {
                .function => .Function,
                .struct_type => .Struct,
                .type_alias => .Class,
                .binding, .param => .Variable,
            };
            // avoid exact dupes with globals (prefer local)
            var duped = false;
            var git = vm.globals.iterator();
            while (git.next()) |entry| {
                if (std.mem.eql(u8, sym.name, vm.atomName(entry.key_ptr.*))) {
                    duped = true;
                    break;
                }
            }
            if (!duped) {
                const label = try arena.dupe(u8, sym.name);

                var insert_text: ?[]const u8 = null;
                var insert_text_format: ?T.InsertTextFormat = null;
                var detail: ?[]const u8 = null;

                if (kind == .Function) {
                    if (try workspace.fnSig(arena, file_id, sym.name)) |sig| {
                        const names = try arena.alloc([]const u8, sig.params.len);
                        const types = try arena.alloc([]const u8, sig.params.len);
                        for (sig.params, 0..) |p, i| {
                            names[i] = p.name;
                            types[i] = if (p.type_name) |ti| try ti.formatType(arena) else "";
                        }
                        const cs = try callSignature(
                            arena,
                            sym.name,
                            names,
                            types,
                            if (sig.return_type) |rt| try rt.formatType(arena) else null,
                        );
                        detail = cs.detail;
                        insert_text = cs.insert_text;
                        insert_text_format = cs.format;
                    }
                }

                items.append(arena, .{
                    .label = label,
                    .kind = kind,
                    .detail = detail,
                    .insertText = insert_text,
                    .insertTextFormat = insert_text_format,
                }) catch return;
            }
        }
    }
}
