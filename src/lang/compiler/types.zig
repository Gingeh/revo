const std = @import("std");
const revo = @import("revo");
const ast = @import("../ast.zig");

pub const UnionVariant = struct {
    name: []const u8,
    types: []const TypeInfo,
};

pub const TypeInfo = union(enum) {
    bool,
    // TODO: maybe unify here maybe split at vm
    int,
    float,
    string,
    atom: []const u8,
    tuple: []const TypeInfo,
    @"union": []const UnionVariant,
    table: struct {
        key: ?*const TypeInfo,
        value: *const TypeInfo,
    },
    struct_type: []const u8,
    function: *const FunctionSignature,
    any,
    never,
    type_var: []const u8,

    pub fn eql(self: TypeInfo, other: TypeInfo) bool {
        return switch (self) {
            .bool => other == .bool,
            .int => other == .int,
            .float => other == .float,
            .string => other == .string,
            .atom => |a| if (other == .atom) std.mem.eql(u8, atomPayload(a), atomPayload(other.atom)) else false,
            .struct_type => |s| if (other == .struct_type) std.mem.eql(u8, s, other.struct_type) else false,
            .tuple => |ts| if (other == .tuple) blk: {
                if (ts.len != other.tuple.len) break :blk false;
                for (ts, other.tuple) |a, b| if (!eql(a, b)) break :blk false;
                break :blk true;
            } else false,
            .@"union" => |us| if (other == .@"union") blk: {
                if (us.len != other.@"union".len) break :blk false;
                for (us, other.@"union") |a, b| {
                    if (!std.mem.eql(u8, a.name, b.name)) break :blk false;
                    if (a.types.len != b.types.len) break :blk false;
                    for (a.types, b.types) |at, bt| if (!eql(at, bt)) break :blk false;
                }
                break :blk true;
            } else false,
            .table => |ti| if (other == .table) blk: {
                const o = other.table;
                if (!eql(ti.value.*, o.value.*)) break :blk false;
                if (ti.key) |tk| break :blk if (o.key) |ok| eql(tk.*, ok.*) else false;
                break :blk o.key == null;
            } else false,
            .function => |f| if (other == .function) blk: {
                const o = other.function;
                if (f == o) break :blk true;
                if (!f.return_type.eql(o.return_type)) break :blk false;
                if (f.params.len != o.params.len) break :blk false;
                for (f.params, o.params) |a, b| if (!a.eql(b)) break :blk false;
                break :blk true;
            } else false,
            .type_var => |name| if (other == .type_var) std.mem.eql(u8, name, other.type_var) else false,
            .any => true,
            .never => other == .never,
        };
    }

    /// alloc version of typeName, formats unions as well
    pub fn formatType(self: TypeInfo, alloc: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .never => try alloc.dupe(u8, "never"),
            .type_var => |n| try alloc.dupe(u8, n),
            .table => |tbl| blk: {
                var buf = try std.ArrayList(u8).initCapacity(alloc, 64);
                errdefer buf.deinit(alloc);
                try buf.appendSlice(alloc, "table<");
                if (tbl.key) |k| {
                    const kf = try k.*.formatType(alloc);
                    defer alloc.free(kf);
                    try buf.appendSlice(alloc, kf);
                    try buf.appendSlice(alloc, ", ");
                }
                const vf = try tbl.value.*.formatType(alloc);
                defer alloc.free(vf);
                try buf.appendSlice(alloc, vf);
                try buf.append(alloc, '>');
                break :blk try buf.toOwnedSlice(alloc);
            },
            .@"union" => |variants| blk: {
                var buf = try std.ArrayList(u8).initCapacity(alloc, 64);
                errdefer buf.deinit(alloc);
                for (variants, 0..) |v, i| {
                    if (i > 0) try buf.appendSlice(alloc, " | ");
                    const is_tagged = v.types.len >= 2 and v.types[0] == .atom;
                    if (is_tagged) try buf.append(alloc, '(');
                    for (v.types, 0..) |vt, j| {
                        if (j > 0) try buf.appendSlice(alloc, if (is_tagged) ", " else " ");
                        const formatted = try vt.formatType(alloc);
                        defer alloc.free(formatted);
                        try buf.appendSlice(alloc, formatted);
                    }
                    if (is_tagged) try buf.append(alloc, ')');
                }
                break :blk try buf.toOwnedSlice(alloc);
            },
            .tuple => |items| blk: {
                if (items.len == 0) break :blk try alloc.dupe(u8, "tuple");
                var buf = try std.ArrayList(u8).initCapacity(alloc, 64);
                errdefer buf.deinit(alloc);
                try buf.append(alloc, '(');
                for (items, 0..) |item, i| {
                    if (i > 0) try buf.appendSlice(alloc, ", ");
                    const formatted = try item.formatType(alloc);
                    defer alloc.free(formatted);
                    try buf.appendSlice(alloc, formatted);
                }
                try buf.append(alloc, ')');
                break :blk try buf.toOwnedSlice(alloc);
            },
            .function => |sig| blk: {
                var buf = try std.ArrayList(u8).initCapacity(alloc, 64);
                errdefer buf.deinit(alloc);
                try buf.appendSlice(alloc, "fn(");
                for (sig.params, 0..) |param, i| {
                    if (i > 0) try buf.appendSlice(alloc, ", ");
                    if (i < sig.param_names.len and sig.param_names[i].len > 0) {
                        try buf.appendSlice(alloc, sig.param_names[i]);
                        try buf.appendSlice(alloc, ": ");
                    }
                    const formatted = try param.formatType(alloc);
                    defer alloc.free(formatted);
                    try buf.appendSlice(alloc, formatted);
                }
                try buf.appendSlice(alloc, ") -> ");
                const ret = try sig.return_type.formatType(alloc);
                defer alloc.free(ret);
                try buf.appendSlice(alloc, ret);
                break :blk try buf.toOwnedSlice(alloc);
            },
            else => try alloc.dupe(u8, typeName(self)),
        };
    }
};

pub fn atomPayload(name: []const u8) []const u8 {
    return if (name.len > 0 and name[0] == ':') name[1..] else name;
}

pub const FieldDef = struct {
    name: []const u8,
    field_type: TypeInfo,
    default_val: ?revo.memory.Data = null,
    type_name: ?[]const u8 = null,
};

pub const FunctionSignature = struct {
    params: []const TypeInfo,
    return_type: TypeInfo,
    param_names: []const []const u8 = &.{},
    is_any_fn_sig: bool = false,
    required_count: usize = 0,
    type_params: []const []const u8 = &.{},
};

/// sentinel "any function" type,,, matches any callable value
/// ptr identity;; only matches when &ANY_FN_SIG is used
pub const ANY_FN_SIG: FunctionSignature = .{
    .params = &.{},
    .return_type = .any,
    .param_names = &.{},
    .is_any_fn_sig = true,
};

/// sentinel type info for `any` used by the generic table sentinel
const ANY_TI: TypeInfo = .{ .any = {} };
/// sentinel for a generic table (no key/value constraints)
pub const TABLE_GENERIC: TypeInfo = .{ .table = .{ .key = null, .value = &ANY_TI } };

pub fn typeName(T: TypeInfo) []const u8 {
    return switch (T) {
        .atom => |s| if (s.len == 0) "atom" else s,
        .struct_type, .type_var => |s| s,
        .table => "table",
        else => @tagName(T),
    };
}

/// deep-clone a TypeInfo into a new allocator
pub fn clone(ti: TypeInfo, alloc: std.mem.Allocator) !TypeInfo {
    return switch (ti) {
        .bool, .int, .float, .string, .any, .never => ti,
        .atom => |s| TypeInfo{ .atom = try alloc.dupe(u8, s) },
        .struct_type => |s| TypeInfo{ .struct_type = try alloc.dupe(u8, s) },
        .type_var => |s| TypeInfo{ .type_var = try alloc.dupe(u8, s) },
        .tuple => |items| {
            const owned = try alloc.alloc(TypeInfo, items.len);
            for (items, 0..) |item, i| owned[i] = try clone(item, alloc);
            return .{ .tuple = owned };
        },
        .@"union" => |variants| {
            const owned = try alloc.alloc(UnionVariant, variants.len);
            for (variants, 0..) |v, i| {
                const types_owned = try alloc.alloc(TypeInfo, v.types.len);
                for (v.types, 0..) |vt, j| types_owned[j] = try clone(vt, alloc);
                owned[i] = .{
                    .name = try alloc.dupe(u8, v.name),
                    .types = types_owned,
                };
            }
            return .{ .@"union" = owned };
        },
        .table => |tbl| {
            const key: ?*TypeInfo = if (tbl.key) |_| try alloc.create(TypeInfo) else null;
            if (key) |k| k.* = try clone(tbl.key.?.*, alloc);
            const value = try alloc.create(TypeInfo);
            value.* = try clone(tbl.value.*, alloc);
            return .{ .table = .{ .key = key, .value = value } };
        },
        .function => |sig| {
            const owned = try alloc.create(FunctionSignature);
            const params = try alloc.alloc(TypeInfo, sig.params.len);
            for (sig.params, 0..) |p, i| params[i] = try clone(p, alloc);
            const param_names = try alloc.alloc([]const u8, sig.param_names.len);
            for (sig.param_names, 0..) |n, i| param_names[i] = try alloc.dupe(u8, n);
            const type_params = try alloc.alloc([]const u8, sig.type_params.len);
            for (sig.type_params, 0..) |tp, i| type_params[i] = try alloc.dupe(u8, tp);
            owned.* = .{
                .params = params,
                .return_type = try clone(sig.return_type, alloc),
                .param_names = param_names,
                .is_any_fn_sig = sig.is_any_fn_sig,
                .required_count = sig.required_count,
                .type_params = type_params,
            };
            return .{ .function = owned };
        },
    };
}

/// free all heap-allocated memory owned by a TypeInfo
pub fn deinitType(ti: *TypeInfo, alloc: std.mem.Allocator) void {
    switch (ti.*) {
        .bool, .int, .float, .string, .any, .never => {},
        .atom, .struct_type, .type_var => |s| if (s.len > 0) alloc.free(s),
        .tuple => |items| {
            for (items) |*item| deinitType(@constCast(item), alloc);
            alloc.free(items);
        },
        .@"union" => |variants| {
            for (variants) |*v| {
                alloc.free(v.name);
                for (v.types) |*vt| deinitType(@constCast(vt), alloc);
                alloc.free(v.types);
            }
            alloc.free(variants);
        },
        .table => |tbl| {
            if (tbl.key) |k| {
                deinitType(@constCast(k), alloc);
                alloc.destroy(@constCast(k));
            }
            deinitType(@constCast(tbl.value), alloc);
            alloc.destroy(@constCast(tbl.value));
        },
        .function => |sig| {
            for (sig.params) |*p| deinitType(@constCast(p), alloc);
            alloc.free(sig.params);
            deinitType(@constCast(&sig.return_type), alloc);
            for (sig.param_names) |n| alloc.free(n);
            alloc.free(sig.param_names);
            for (sig.type_params) |tp| alloc.free(tp);
            alloc.free(sig.type_params);
            alloc.destroy(@constCast(sig));
        },
    }
    ti.* = .never;
}

pub fn isNumeric(T: TypeInfo) bool {
    return T == .int or T == .float;
}

pub fn canCoerce(from: TypeInfo, to: TypeInfo) bool {
    if (from == .never) return true;
    if (to == .never) return false;
    if (from.eql(to) or to == .any or from == .any or from == .type_var or to == .type_var) return true;
    if (from == .table and to == .table) {
        const from_table = from.table;
        const to_table = to.table;
        if (!canCoerce(from_table.value.*, to_table.value.*)) return false;
        if (to_table.key == null) return true;
        if (from_table.key == null) return true;
        return canCoerce(from_table.key.?.*, to_table.key.?.*);
    }
    // function subtyping: contravariant params, covariant return
    if (to == .function and from == .function) {
        const to_sig = to.function;
        const from_sig = from.function;
        // sentinel "any function" take and give any
        if (to_sig.is_any_fn_sig or from_sig.is_any_fn_sig) return true;
        // ret t: from's return must fit to's return
        if (!canCoerce(from_sig.return_type, to_sig.return_type)) return false;
        // params: to's params must fit from's params
        if (from_sig.params.len != to_sig.params.len) return false;
        for (from_sig.params, to_sig.params) |fp, tp| {
            if (!canCoerce(tp, fp)) return false;
        }
        return true;
    }
    // empty tuple (.len == 0) is a sentinel for "any tuple"
    if (to == .tuple and from == .tuple) {
        if (to.tuple.len == 0 or from.tuple.len == 0) return true;
        if (to.tuple.len != from.tuple.len) return false;
        for (to.tuple, from.tuple) |tt, ff| if (!canCoerce(ff, tt)) return false;
        return true;
    }
    // empty atom (.atom == "") is a sentinel for "any atom"
    if (to == .atom and from == .atom) {
        if (to.atom.len == 0 or from.atom.len == 0) return true;
        return std.mem.eql(u8, to.atom, from.atom);
    }
    // :true and :false are bool
    if (to == .bool and from == .atom) {
        const name = atomPayload(from.atom);
        return std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false");
    }
    if (to == .@"union") {
        // fast-path for atom literals vs atom-only variants
        if (from == .atom) {
            for (to.@"union") |variant| {
                if (variant.types.len == 1 and variant.types[0] == .atom) {
                    if (std.mem.eql(u8, atomPayload(variant.types[0].atom), atomPayload(from.atom))) return true;
                }
            }
        }
        for (to.@"union") |variant| {
            if (unionVariantAccepts(variant, from)) return true;
        }
    }
    if (from == .@"union") {
        if (from.@"union".len == 0) return false;
        for (from.@"union") |variant| {
            if (!targetAcceptsVariant(variant, to)) return false;
        }
        return true;
    }
    return from == .int and to == .float;
}

fn unionVariantAccepts(variant: UnionVariant, value: TypeInfo) bool {
    if (variant.types.len == 1) return canCoerce(value, variant.types[0]);
    if (value != .tuple) return false;
    if (value.tuple.len != variant.types.len) return false;
    for (variant.types, value.tuple) |expected, actual| {
        // numbers are a single runtime type,,,, int/float payloads are
        // interchangeable inside a tagged union
        if (numericCompatible(actual, expected)) continue;
        if (!canCoerce(actual, expected)) return false;
    }
    return true;
}

fn targetAcceptsVariant(variant: UnionVariant, target: TypeInfo) bool {
    if (variant.types.len == 1) return canCoerce(variant.types[0], target);
    if (target != .tuple) return false;
    if (target.tuple.len != variant.types.len) return false;
    for (variant.types, target.tuple) |source, expected| {
        if (numericCompatible(source, expected)) continue;
        if (!canCoerce(source, expected)) return false;
    }
    return true;
}

/// int and float are the same runtime type,,, inside a tagged union a
/// payload annotated with either accepts the other
fn numericCompatible(a: TypeInfo, b: TypeInfo) bool {
    return (a == .int or a == .float) and (b == .int or b == .float);
}

pub fn inferBinaryOp(op: ast.BinOp, l: TypeInfo, r: TypeInfo) TypeInfo {
    return switch (op) {
        .@"union", .concat => .any,
        .add, .sub, .mul, .div, .mod, .pow => blk: {
            if (l == .int and r == .int) break :blk .int;
            if (isNumeric(l) and isNumeric(r)) break :blk .float;
            break :blk .any;
        },
        .int_div => blk: {
            if (l == .int and r == .int) break :blk .int;
            if (isNumeric(l) and isNumeric(r)) break :blk .float;
            break :blk .any;
        },
        .band, .bor, .bxor, .shl, .shr => if (l == .int and r == .int) .int else .any,
        .eq, .neq, .lt, .gt, .lte, .gte => .bool,
    };
}

pub fn inferUnaryOp(op: ast.UnOp, T: TypeInfo) TypeInfo {
    return switch (op) {
        .negate => if (isNumeric(T)) T else .any,
        .not => .bool,
        else => .any,
    };
}

pub fn inferIfType(then_type: TypeInfo, else_type: ?TypeInfo) TypeInfo {
    if (else_type) |et| return unifyBranchType(then_type, et);
    return .any;
}

/// unify a branch type into the running if/orelse/match result:
/// `never` branches diverge and contribute nothing; a leading `any` is
/// overwritten by a later concrete type (pattern vars narrow only while
/// their scope is live, so re-inference after scope pop sees `any`)
pub fn unifyBranchType(acc: TypeInfo, branch: TypeInfo) TypeInfo {
    if (branch == .never) return acc;
    if (acc == .never) return branch;
    if (acc == .any) return branch;
    if (branch == .any) return acc;
    if (acc.eql(branch)) return acc;
    return .any;
}

pub fn inferMatchType(ctx: anytype, subject: *const ast.Node, arms: []const ast.MatchArm) TypeInfo {
    _ = subject;
    var result: TypeInfo = .never;
    for (arms) |arm| {
        result = unifyBranchType(result, inferExprType(ctx, arm.then));
    }
    return result;
}

pub fn inferOrelseType(left: TypeInfo, right: TypeInfo) TypeInfo {
    const unwrapped = if (isResultType(left)) okTypeFrom(left) else left;
    return unifyBranchType(unwrapped, right);
}

fn isResultTag(name: []const u8) bool {
    return std.mem.eql(u8, name, ":ok") or std.mem.eql(u8, name, "ok") or
        std.mem.eql(u8, name, ":err") or std.mem.eql(u8, name, "err");
}

fn isOkTag(name: []const u8) bool {
    return std.mem.eql(u8, name, ":ok") or std.mem.eql(u8, name, "ok");
}

/// `(:ok, T) | (:err, any)` unions (both the `!T` sugar and the literal
/// form) and `(:ok, T)` / `(:err, E)` tagged tuples
///
/// the shapes `?` and `orelse` unwrap at runtime
pub fn isResultType(ti: TypeInfo) bool {
    return switch (ti) {
        .@"union" => |us| blk: {
            for (us) |v| {
                if (v.types.len >= 2 and v.types[0] == .atom and isResultTag(atomPayload(v.types[0].atom))) {
                    break :blk true;
                }
            }
            break :blk false;
        },
        .tuple => |items| items.len >= 1 and items[0] == .atom and blk: {
            const tag = atomPayload(items[0].atom);
            break :blk isResultTag(tag);
        },
        else => false,
    };
}

/// unwrap the `:ok` payload from a `(:ok, T) | (:err, any)` union or a
/// `(:ok, T)` tagged tuple; mirrors the runtime, which yields only the
/// first payload element
pub fn okTypeFrom(ti: TypeInfo) TypeInfo {
    return switch (ti) {
        .@"union" => |variants| blk: {
            for (variants) |v| {
                if (v.types.len >= 2 and v.types[0] == .atom and isOkTag(atomPayload(v.types[0].atom))) {
                    break :blk v.types[1];
                }
            }
            break :blk .any;
        },
        .tuple => |items| blk: {
            if (items.len < 2 or items[0] != .atom) break :blk .any;
            const tag = atomPayload(items[0].atom);
            if (!isOkTag(tag)) break :blk .any;
            break :blk items[1];
        },
        else => .any,
    };
}

pub fn collectVariants(alloc: std.mem.Allocator, ti: TypeInfo, variants: *std.ArrayList(UnionVariant)) !void {
    switch (ti) {
        .@"union" => |us| for (us) |u| try variants.append(alloc, u),
        .tuple => |types| try variants.append(alloc, .{ .name = "", .types = types }),
        else => {
            var one = try std.ArrayList(TypeInfo).initCapacity(alloc, 1);
            errdefer one.deinit(alloc);
            try one.append(alloc, ti);
            try variants.append(alloc, .{ .name = "", .types = try one.toOwnedSlice(alloc) });
        },
    }
}

pub const type_name_map: std.StaticStringMap(TypeInfo) = std.StaticStringMap(TypeInfo).initComptime(.{
    .{ "int", .int },
    .{ "float", .float },
    .{ "num", .int },
    .{ "number", .int },
    .{ "string", .string },
    .{ "bool", .bool },
    .{ "any", .any },
    .{ "nil", TypeInfo{ .atom = ":nil" } },
    .{ "tuple", TypeInfo{ .tuple = &.{} } }, // empty tuple is the "any tuple" sentinel
    .{ "table", TABLE_GENERIC },
    .{ "function", TypeInfo{ .function = &ANY_FN_SIG } },
    .{ "atom", TypeInfo{ .atom = "" } }, // empty atom payload is the "any atom" sentinel
    .{ "never", .never },
    .{ "parked", .any },
});

pub fn resolveTypeName(ctx: anytype, name: []const u8) TypeInfo {
    if (type_name_map.get(name)) |res| return res;
    if (name.len > 0 and name[0] == ':') return .{ .atom = name };
    if (ctx.resolveTypeAlias(name)) |aliased| return aliased;
    return .{ .struct_type = name };
}

pub fn inferExprType(ctx: anytype, node: *const ast.Node) TypeInfo {
    return switch (node.expr) {
        .number => |n| if (n.is_float) .float else .int,
        .string, .multiline_string => .string,
        .hash => |name| .{ .atom = name },
        .nil => .{ .atom = ":nil" },
        .ident => |name| ctx.inferIdentType(name),
        .unary => |u| inferUnaryOp(u.op, inferExprType(ctx, u.expr)),
        .binary => |b| inferBinaryOp(b.op, inferExprType(ctx, b.left), inferExprType(ctx, b.right)),
        .and_expr, .or_expr => .bool,
        .if_expr => |v| inferIfType(
            inferExprType(ctx, v.then_expr),
            if (v.else_expr) |e| inferExprType(ctx, e) else null,
        ),

        .tuple => |items| inferTupleType(ctx, items),
        .table => |entries| inferTableType(ctx, entries),
        .call => |call| ctx.inferCallReturnType(call.callee, @as([]const *ast.Node, call.args), call.type_args),
        .field => |field| ctx.inferFieldType(field.object, field.name),
        .index => |index| inferIndexType(ctx, index.object, index.key),
        .fn_expr => |fn_expr| ctx.inferFnType(fn_expr.params, fn_expr.return_type, fn_expr.type_params),
        .block => |exprs| inferBlockResultType(ctx, exprs),
        .return_expr => .any,
        .loop_expr => |v| inferExprType(ctx, v.body),
        .for_loop => |v| inferExprType(ctx, v.body),
        .while_loop => |v| inferExprType(ctx, v.body),
        .break_expr => |b| if (b.value) |v| inferExprType(ctx, v) else .any,
        .continue_expr => |c| if (c.value) |v| inferExprType(ctx, v) else .any,
        .labeled_block => |lb| inferExprType(ctx, lb.body),
        .try_expr => |inner| blk: {
            const it = inferExprType(ctx, inner);
            break :blk switch (it) {
                .@"union", .tuple => okTypeFrom(it),
                else => it,
            };
        },
        .orelse_expr => |v| inferOrelseType(inferExprType(ctx, v.left), inferExprType(ctx, v.right)),
        .comp_block => |cb| inferExprType(ctx, cb.expr),
        .import_stmt, .test_block, .test_suite, .macro_expr, .proc_macro, .quasiquote => .any,
        .match_expr => |v| inferMatchType(ctx, v.subject, v.arms),
        .range_literal, .slice_literal => .int,
        .assign_expr, .decl, .binding, .tuple_pattern, .type_alias => .any,
        .struct_def => |def| .{ .struct_type = def.name },
    };
}

fn inferTableType(ctx: anytype, entries: []const ast.TableEntry) TypeInfo {
    var value_type: TypeInfo = .any;
    var key_type: TypeInfo = .any;
    var saw_explicit_key = false;
    var saw_implicit_key = false;

    for (entries) |entry| {
        value_type = mergeInferredType(value_type, inferExprType(ctx, entry.value));
        if (entry.key) |key| {
            const inferred_key = inferTableKeyType(ctx, key, entry.computed);
            key_type = if (saw_explicit_key) mergeInferredType(key_type, inferred_key) else inferred_key;
            saw_explicit_key = true;
        } else {
            saw_implicit_key = true;
        }
    }

    const value_ptr = ctx.alloc.create(TypeInfo) catch return .any;
    value_ptr.* = value_type;

    if (!saw_explicit_key) {
        return .{ .table = .{ .key = null, .value = value_ptr } };
    }

    if (saw_implicit_key) key_type = mergeInferredType(key_type, .int);
    const key_ptr = ctx.alloc.create(TypeInfo) catch return .any;
    key_ptr.* = key_type;
    return .{ .table = .{ .key = key_ptr, .value = value_ptr } };
}

fn inferTableKeyType(ctx: anytype, key: *const ast.Node, computed: bool) TypeInfo {
    if (!computed) {
        return switch (key.expr) {
            .ident, .hash => .string,
            else => inferExprType(ctx, key),
        };
    }
    return inferExprType(ctx, key);
}

fn mergeInferredType(current: TypeInfo, next: TypeInfo) TypeInfo {
    if (current == .any) return next;
    if (next == .any) return current;
    if (current.eql(next)) return current;
    if ((current == .int and next == .float) or (current == .float and next == .int)) return .float;
    return .any;
}

pub fn inferTupleType(ctx: anytype, items: []const *ast.Node) TypeInfo {
    if (items.len == 0) return .{ .tuple = &.{} };
    const types = ctx.alloc.alloc(TypeInfo, items.len) catch return .any;
    for (items, types) |item, *dst| dst.* = inferExprType(ctx, item);
    return .{ .tuple = types };
}

pub fn inferIndexType(ctx: anytype, object: *const ast.Node, key: *const ast.Node) TypeInfo {
    if (key.expr == .range_literal or key.expr == .slice_literal) {
        return switch (inferExprType(ctx, object)) {
            .string => .string,
            .tuple => |items| .{ .tuple = items },
            else => .any,
        };
    }
    return switch (inferExprType(ctx, object)) {
        .tuple => |items| if (key.expr == .number) blk: {
            const key_num = key.expr.number.value;
            if (std.math.isFinite(key_num) and @floor(key_num) == key_num and key_num >= 0) {
                const idx: usize = @intFromFloat(key_num);
                if (object.expr == .tuple) {
                    const tuple_items = object.expr.tuple;
                    if (idx < tuple_items.len) break :blk inferExprType(ctx, tuple_items[idx]);
                } else if (idx < items.len) {
                    break :blk items[idx];
                }
            }
            break :blk .any;
        } else .any,
        .string => .string,
        else => .any,
    };
}

pub fn inferBlockResultType(ctx: anytype, exprs: []const *ast.Node) TypeInfo {
    if (exprs.len == 0) return .any;
    return inferExprType(ctx, exprs[exprs.len - 1]);
}

/// substitute type params in a TypeInfo tree
/// subst is any type with `get(key: []const u8) ?TypeInfo`
pub fn substituteTypeParams(alloc: std.mem.Allocator, ti: TypeInfo, subst: anytype) !TypeInfo {
    return switch (ti) {
        .type_var => |name| subst.get(name) orelse .any,
        .tuple => |items| blk: {
            const new_items = try alloc.alloc(TypeInfo, items.len);
            for (items, new_items) |item, *dst| dst.* = try substituteTypeParams(alloc, item, subst);
            break :blk TypeInfo{ .tuple = new_items };
        },
        .function => |fsig| blk: {
            const new_params = try alloc.alloc(TypeInfo, fsig.params.len);
            for (fsig.params, new_params) |p, *np| np.* = try substituteTypeParams(alloc, p, subst);
            const new_ret = try substituteTypeParams(alloc, fsig.return_type, subst);
            const new_sig = try alloc.create(FunctionSignature);
            new_sig.* = FunctionSignature{
                .params = new_params,
                .return_type = new_ret,
                .param_names = fsig.param_names,
                .type_params = fsig.type_params,
            };
            break :blk TypeInfo{ .function = new_sig };
        },
        else => ti,
    };
}

test "types: TypeInfo equality" {
    const int_type: revo.lang.compiler.types.TypeInfo = .int;
    const any_type: revo.lang.compiler.types.TypeInfo = .any;

    try std.testing.expect(int_type.eql(.int));
    try std.testing.expect(!int_type.eql(.float));
    try std.testing.expect(any_type.eql(.any));
}

test "types: numeric type check" {
    const types = revo.lang.compiler.types;
    try std.testing.expect(types.isNumeric(.int));
    try std.testing.expect(types.isNumeric(.float));
    try std.testing.expect(!types.isNumeric(.string));
    try std.testing.expect(!types.isNumeric(.any));
}

test "types: type coercion" {
    const types = revo.lang.compiler.types;
    try std.testing.expect(types.canCoerce(.int, .int));
    try std.testing.expect(types.canCoerce(.int, .float));
    try std.testing.expect(!types.canCoerce(.float, .int)); // float doesn't coerce to int
    try std.testing.expect(types.canCoerce(.int, .any)); // anything to any
    try std.testing.expect(types.canCoerce(.any, .int)); // any to anything (optimistic)
}

test "types: binary op inference - arithmetic" {
    const types = revo.lang.compiler.types;
    const add_int_int = types.inferBinaryOp(.add, .int, .int);
    try std.testing.expect(add_int_int.eql(.int));

    const add_float_float = types.inferBinaryOp(.add, .float, .float);
    try std.testing.expect(add_float_float.eql(.float));

    const add_int_float = types.inferBinaryOp(.add, .int, .float);
    try std.testing.expect(add_int_float.eql(.float));
}

test "types: binary op inference - comparison" {
    const types = revo.lang.compiler.types;
    const cmp = types.inferBinaryOp(.eq, .int, .int);
    try std.testing.expect(cmp.eql(.bool));

    const cmp2 = types.inferBinaryOp(.lt, .float, .float);
    try std.testing.expect(cmp2.eql(.bool));
}

test "types: empty tuple/atom sentinel coercion" {
    const types = revo.lang.compiler.types;
    const empty_tuple: types.TypeInfo = .{ .tuple = &.{} };
    const int_tuple: types.TypeInfo = .{ .tuple = &.{.int} };
    try std.testing.expect(types.canCoerce(empty_tuple, int_tuple));
    try std.testing.expect(types.canCoerce(int_tuple, empty_tuple));
    try std.testing.expect(types.canCoerce(empty_tuple, empty_tuple));

    const empty_atom: types.TypeInfo = .{ .atom = "" };
    const named_atom: types.TypeInfo = .{ .atom = ":foo" };
    try std.testing.expect(types.canCoerce(empty_atom, named_atom));
    try std.testing.expect(types.canCoerce(named_atom, empty_atom));
    try std.testing.expect(types.canCoerce(empty_atom, empty_atom));
}

test "types: unary op inference" {
    const types = revo.lang.compiler.types;
    const negate_int = types.inferUnaryOp(.negate, .int);
    try std.testing.expect(negate_int.eql(.int));

    const not_bool = types.inferUnaryOp(.not, .bool);
    try std.testing.expect(not_bool.eql(.bool));
}

//
// type system
//
const lang = revo.lang;
const t = lang.testing;
const VM = revo.VM;

test "typed binding int accepts int literal" {
    try t.topNumber(
        \\ let x: int = 42
        \\ x
    , 42);
}

test "typed binding float accepts float literal" {
    try t.topNumber(
        \\ let x: float = 3.14
        \\ x
    , 3.14);
}

test "typed binding int accepts int literal coerced to float" {
    try t.topNumber(
        \\ let x: float = 10
        \\ x
    , 10.0);
}

test "typed binding rejects string for int" {
    try t.expectCompileError(
        \\ let x: int = "hello"
    , .ParseError);
}

test "typed binding rejects float for int" {
    try t.expectCompileError(
        \\ let x: int = 3.14
    , .ParseError);
}

test "typed binding rejects int for string" {
    try t.expectCompileError(
        \\ let x: string = 42
    , .ParseError);
}

test "typed binding table<int> accepts positional table literal" {
    try t.topNumber(
        \\ let nums: table<int> = { 1, 2, 3 }
        \\ 1
    , 1);
}

test "typed binding table<string, int> accepts keyed table literal" {
    try t.topNumber(
        \\ let pairs: table<string, int> = { a = 1, b = 2 }
        \\ 1
    , 1);
}

test "typed function params accept correct types" {
    try t.topNumber(
        \\ const add = fn(a: int, b: int) a + b
        \\ add(3, 4)
    , 7);
}

test "typed function rejects wrong arg type" {
    try t.expectCompileError(
        \\ const add = fn(a: int, b: int) a + b
        \\ add(3, "wrong")
    , .ParseError);
}

test "typed function rejects first arg wrong type" {
    try t.expectCompileError(
        \\ const add = fn(a: int, b: int) a + b
        \\ add("wrong", 4)
    , .ParseError);
}

test "atom union alias accepts literal and alias value in calls" {
    try t.topAtom(
        \\ type A = :one | :two
        \\ fn pick(how: A) -> any do
        \\   how
        \\ end
        \\ let pred: A = :one
        \\ pick(pred)
    , "one");

    try t.topAtom(
        \\ type A = :one | :two
        \\ fn pick(how: A) -> any do
        \\   how
        \\ end
        \\ let pred: A = :one
        \\ pick(:two)
    , "two");
}

test "typed struct field access" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ struct User {
        \\     name: string = "",
        \\     age: number = 0,
        \\ }
        \\ let u: User = User { name = "alice", age = 30 }
        \\ u.age
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_get = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .struct_get_offset) saw_get = true;
    }
    try std.testing.expect(saw_get);
}

test "typed struct field assignment rejects wrong type" {
    try t.expectCompileError(
        \\ struct User {
        \\     name: string = "",
        \\     age: int = 0,
        \\ }
        \\ let u: User = User { name = "alice", age = 30 }
        \\ u.name = 42
    , .ParseError);
}

test "typed struct field assignment accepts correct type" {
    try t.topNumber(
        \\ struct User {
        \\     name: string = "",
        \\     age: number = 0,
        \\ }
        \\ let u: User = User { name = "alice", age = 30 }
        \\ u.age = 42
        \\ u.age
    , 42);
}

test "binary int + int emits add" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: int = 5
        \\ let b: int = 3
        \\ a + b
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int) saw_add = true;
    }
    try std.testing.expect(saw_add);
}

test "binary float + float emits add" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: float = 1.5
        \\ let b: float = 2.5
        \\ a + b
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add) saw_add = true;
    }
    try std.testing.expect(saw_add);
}

test "negate int emits negate_int" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let x: int = 5
        \\ let y = -x
        \\ y
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_neg = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .negate_int) saw_neg = true;
    }
    try std.testing.expect(saw_neg);
}

test "comparison int == int emits eq_int" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: int = 5
        \\ let b: int = 5
        \\ a == b
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_eq = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .eq_int) saw_eq = true;
    }
    try std.testing.expect(saw_eq);
}

test "untyped code still works" {
    try t.topNumber("1 + 2 * 3", 7);
    try t.topNumber(
        \\ let x = 10
        \\ x + 5
    , 15);
    try t.topString(
        \\ let s = "hello"
        \\ s
    , "hello");
}

test "mixed int and float falls back to generic add" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: int = 5
        \\ let b: float = 2.5
        \\ a + b
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_generic_add = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add) saw_generic_add = true;
    }
    try std.testing.expect(saw_generic_add);
}

test "nested function with typed params" {
    try t.topNumber(
        \\ const outer = fn(x: int) do
        \\     const inner = fn(y: int) y * 2
        \\     inner(x) + 1
        \\ end
        \\ outer(5)
    , 11);
}

test "function call with multiple typed params" {
    try t.topNumber(
        \\ const calc = fn(a: int, b: float, c: int) do
        \\     a + b + c
        \\ end
        \\ calc(1, 2.5, 3)
    , 6.5);
}

test "return type validation accepts correct type" {
    try t.topNumber(
        \\ const get_num = fn() -> int do
        \\     return 42
        \\ end
        \\ get_num()
    , 42);
}

test "atoms<->any relationship" {
    try t.topNumber(
        \\ const get_num = fn() -> int do
        \\     return 42
        \\ end
        \\ get_num()
    , 42);
}

//
// typed const bindings
//
test "typed const binding int" {
    try t.topNumber(
        \\ const x: int = 42
        \\ x
    , 42);
}

test "typed const binding string" {
    try t.topString(
        \\ const s: string = "hello"
        \\ s
    , "hello");
}

test "typed const binding float" {
    try t.topNumber(
        \\ const x: float = 3.14
        \\ x
    , 3.14);
}

test "typed const binding rejects wrong type" {
    try t.expectCompileError(
        \\ const x: int = "hello"
    , .ParseError);
}

//
// typed global bindings
//
test "typed global binding int" {
    try t.topNumber(
        \\ global x: int = 42
        \\ x
    , 42);
}

test "typed global binding float" {
    try t.topNumber(
        \\ global x: float = 1.5
        \\ x
    , 1.5);
}

//
// type alias at call sites
//
test "type alias used in function param" {
    try t.topNumber(
        \\ type MyInt = int
        \\ const double = fn(x: MyInt) -> MyInt x * 2
        \\ double(21)
    , 42);
}

test "type alias used in binding" {
    try t.topString(
        \\ type Name = string
        \\ let s: Name = "alice"
        \\ s
    , "alice");
}

test "type alias int | float accepts int" {
    try t.topNumber(
        \\ type Num = int | float
        \\ const add = fn(a: Num, b: Num) -> float a + b
        \\ add(3, 4)
    , 7);
}

test "type alias int | float accepts float" {
    try t.topNumber(
        \\ type Num = int | float
        \\ const add = fn(a: Num, b: Num) -> float a + b
        \\ add(3.5, 4.2)
    , 7.7);
}

test "type alias rejects type not in union" {
    try t.expectCompileError(
        \\ type MyInt = int
        \\ const x: MyInt = "string"
    , .ParseError);
}

//
// named union variants with payloads
//
test "named union variant ok result" {
    try t.topAtom(
        \\ type Result = :ok | :err
        \\ match 0
        \\ | 0 => :ok
        \\ | _ => :err
    , "ok");
}

test "named union variant err result" {
    try t.topAtom(
        \\ type Result = :ok | :err
        \\ match 1
        \\ | 0 => :ok
        \\ | _ => :err
    , "err");
}

//
// return type validation
//
test "return type mismatch detects wrong explicit return" {
    try t.expectCompileError(
        \\ fn get() -> int do
        \\     return "hello"
        \\ end
    , .ParseError);
}

test "coercion in return type int to float" {
    try t.topNumber(
        \\ fn get() -> float do
        \\     return 42
        \\ end
        \\ get()
    , 42);
}

test "explicit return matches return type" {
    try t.topNumber(
        \\ fn get() -> int do
        \\     return 99
        \\ end
        \\ get()
    , 99);
}

//
// if/else branch type unification
//
test "if/else typed branches unify to number" {
    try t.topNumber(
        \\ let x: int = 5
        \\ let y = if x > 0 10 else 20
        \\ y
    , 10);
}

test "if/else typed branches unify to string" {
    try t.topString(
        \\ let x: int = 0
        \\ let y = if x > 0 "pos" else "non-pos"
        \\ y
    , "non-pos");
}

//
// tuple type inference
//
test "tuple type inference and access" {
    try t.topNumber(
        \\ let t = (1, "hi", 3.5)
        \\ t[0] + t[2]
    , 4.5);
}

test "tuple type with different types" {
    try t.topNumber(
        \\ let t = (10, 20, 30)
        \\ t[0] + t[1] + t[2]
    , 60);
}

test "nested tuple type" {
    try t.topNumber(
        \\ let t = ((1, 2), (3, 4))
        \\ t[0][0] + t[1][1]
    , 5);
}

//
// string indexing
//
test "string indexing returns string" {
    try t.topString(
        \\ let s: string = "hello"
        \\ s[0]
    , "h");
}

test "string slicing uses half-open range bounds" {
    try t.topString(
        \\ let s: string = "hello"
        \\ s[1..4]
    , "ell");
}

test "stepped string slicing" {
    try t.topString(
        \\ let s: string = "abcdef"
        \\ s[5..-1..1]
    , "fedc");
}

test "tuple slicing returns a tuple" {
    try t.topNumber(
        \\ let t = (10, 20, 30, 40)
        \\ t[1..3][1]
    , 30);
}

//
// open-bound slicing
//
test "string slice open start [..n]" {
    try t.topString(
        \\ let s: string = "hello"
        \\ s[..4]
    , "hell");
}

test "string slice open end [n..]" {
    try t.topString(
        \\ let s: string = "hello"
        \\ s[2..]
    , "llo");
}

test "string slice open both [..]" {
    try t.topString(
        \\ let s: string = "hello"
        \\ s[..]
    , "hello");
}

test "tuple slice open start [..n]" {
    try t.topNumber(
        \\ let t = (10, 20, 30, 40)
        \\ t[..3][1]
    , 20);
}

test "tuple slice open end [n..]" {
    try t.topNumber(
        \\ let t = (10, 20, 30, 40)
        \\ t[2..][0]
    , 30);
}

test "tuple slice open both [..]" {
    try t.topNumber(
        \\ let t = (10, 20, 30, 40)
        \\ len(t[..])
    , 4);
}

test "string slice open step [n..step..m]" {
    try t.topString(
        \\ let s: string = "abcdef"
        \\ s[0..2..5]
    , "ace");
}

test "tuple slice open negative step [n..-step..m]" {
    try t.topNumber(
        \\ let t = (1, 2, 3, 4, 5)
        \\ t[4..-2..0][0]
    , 5);
}

test "string slice empty result" {
    try t.topString(
        \\ let s: string = "abc"
        \\ s[2..2]
    , "");
}

test "tuple slice empty result" {
    try t.topNumber(
        \\ let t = (1, 2, 3)
        \\ len(t[2..2])
    , 0);
}

//
// struct with nested struct fields
//
test "struct field access returns correct type" {
    try t.topNumber(
        \\ struct User { name: string = "", age: int = 0 }
        \\ let u = User { name = "alice", age = 30 }
        \\ u.age + 12
    , 42);
}

//
// any type accepts everything
//
test "any typed param accepts int" {
    try t.topNumber(
        \\ const id = fn(x: any) x
        \\ id(42)
    , 42);
}

test "any typed param accepts string" {
    try t.topString(
        \\ const id = fn(x: any) x
        \\ id("hello")
    , "hello");
}

test "any typed param accepts table" {
    try t.topNumber(
        \\ const get = fn(t: any, k: any) t[k]
        \\ get({x = 99}, :x)
    , 99);
}

test "any typed binding accepts anything" {
    try t.topNumber(
        \\ let x: any = 42
        \\ let y: any = "str"
        \\ let z: any = {a = 1}
        \\ x
    , 42);
}

//
// block type propagation
//
test "block type propagates last expression type" {
    try t.topNumber(
        \\ let x: int = do
        \\     let a = 1
        \\     let b = 2
        \\     a + b
        \\ end
        \\ x
    , 3);
}

test "block type error on type mismatch" {
    try t.expectCompileError(
        \\ let x: int = do
        \\     "hello"
        \\ end
    , .ParseError);
}

//
// chained typed ops preserve specialization
//
test "chained typed math emits add and mul" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let a: int = 1
        \\ let b: int = 2
        \\ let c: int = 3
        \\ a + b * c
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add = false;
    var saw_mul = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int) saw_add = true;
        if (inst.op == .mul_int) saw_mul = true;
    }
    try std.testing.expect(saw_add);
    try std.testing.expect(saw_mul);
}

//
// type alias union with multiple atom variants
//
test "multi-atom union alias in match" {
    try t.topAtom(
        \\ type Color = :red | :green | :blue
        \\ match :red
        \\ | :red => :green
        \\ | :green => :red
        \\ | _ => :blue
    , "green");
}

test "multi-atom union fn param accepts valid atom" {
    try t.topAtom(
        \\ type Color = :red | :green
        \\ fn pick(c: Color) c
        \\ pick(:green)
    , "green");
}

//
// void / nil type
//
test "nil typed fn body" {
    try t.topNil(
        \\ fn nothing() do :nil end
        \\ nothing()
    );
}

test "typed binding with void returns nil" {
    try t.topNil(
        \\ let x: any = :nil
        \\ x
    );
}

test "global typed binding rejects type mismatch" {
    try t.expectCompileError(
        \\ const x: int = "hello"
    , .ParseError);
}

test "global typed binding accepts matching type" {
    try t.topNumber(
        \\ const x: int = 42
        \\ x
    , 42);
}

test "typed assignment rejects type mismatch" {
    try t.expectCompileError(
        \\ let x: int = 5
        \\ x = "hello"
    , .ParseError);
}

test "untyped assignment allows type change" {
    try t.topString(
        \\ let x = 5
        \\ x = "hello"
        \\ x
    , "hello");
}

//
// bool type
//
test "bool typed binding" {
    try t.topTrue(
        \\ let b: bool = 1 == 1
        \\ b
    );
}

test "bool typed binding rejects non-bool" {
    try t.expectCompileError(
        \\ let b: bool = 42
    , .ParseError);
}

test "not operator on bool stays bool" {
    try t.topFalse(
        \\ let b: bool = not (1 == 1)
        \\ b
    );
}

test "implicit return validates block-local variable type" {
    try t.expectCompileError(
        \\ fn f() -> int do
        \\   let x = "hello"
        \\   x
        \\ end
    , .ParseError);
}

test "loop expression infers correct return type" {
    try t.expectCompileError(
        \\ fn f() -> string do
        \\   for i in 0..10 do i end
        \\ end
    , .ParseError);
}

test "upvalue assignment respects type annotation" {
    try t.expectCompileError(
        \\ const outer = fn() do
        \\     let x: int = 5
        \\     const inner = fn() do x = "hello" end
        \\ end
    , .ParseError);
}

test "dynamic callee validates argument types" {
    try t.expectCompileError(
        \\ const f: function = fn(x: int) x
        \\ f("hello")
    , .ParseError);
}

test "tuple pattern binding respects type annotation" {
    try t.expectCompileError(
        \\ const tup: string = (1, 2)
    , .ParseError);
}

test "for loop expression produces int type" {
    try t.topNumber(
        \\ fn f() -> int do
        \\   for i in 0..5 do i end
        \\ end
        \\ f()
    , 4);
}

test "type alias gets unaliased" {
    try t.topTrue(
        \\ type Als =
        \\       (:aa, int)
        \\     | (:bb, float)
        \\ 
        \\ let x: Als = (:aa, 55)
        \\ let y: Als = (:bb, 100.1)
        \\ 
        \\ x[1] + y[1] == 155.1
    );
}

test "tuple type annotation" {
    try t.topTrue(
        \\ let x: (:aa, int) | (:bb, float) = (:aa, 55)
        \\ let y: (:aa, int) | (:bb, float) = (:bb, 100.1)
        \\ 
        \\ x[1] + y[1] == 155.1
    );
}

test "comp block infers int from literal" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ let x = comp 42
        \\ x + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int or inst.op == .add_int_imm) saw_add_int = true;
    }
    try std.testing.expect(saw_add_int);
}

test "never collapses in if and orelse inference" {
    // `panic` is `never`: a branch that diverges contributes no type
    try std.testing.expectEqual(TypeInfo{ .int = {} }, inferIfType(.never, .{ .int = {} }));
    try std.testing.expectEqual(TypeInfo{ .int = {} }, inferIfType(.{ .int = {} }, .never));
    try std.testing.expectEqual(TypeInfo{ .never = {} }, inferIfType(.never, .never));
    try std.testing.expectEqual(TypeInfo{ .int = {} }, inferOrelseType(.never, .{ .int = {} }));
    try std.testing.expectEqual(TypeInfo{ .int = {} }, inferOrelseType(.{ .int = {} }, .never));
    // unknown left stays unknown: the value may be anything or diverge
    try std.testing.expectEqual(TypeInfo{ .any = {} }, inferOrelseType(.any, .never));
}

test "never arms don't poison match result type" {
    // the panic arm is `never`: the match result is the `:ok` payload (int),
    // so `?` on it is rejected as a non-result (it would pass as `.any`)
    try t.expectCompileError(
        \\ type Res = (:ok, int) | (:err, string)
        \\ let x: Res = (:ok, 42)
        \\ let r = match x
        \\ | (:ok, v) => v
        \\ | (:err, e) => panic(e)
        \\ r?
    , .ParseError);
}

test "match narrowing enables specialized add_int from union payload" {
    // narrowing should make `v` int instead of any, so `v + 1` should emit add_int
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ type Res = (:ok, int) | (:err, string)
        \\ let x: Res = (:ok, 42)
        \\ match x
        \\ | (:ok, v) => v + 1
        \\ | (:err, _) => 0
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int or inst.op == .add_int_imm) saw_add_int = true;
    }
    try std.testing.expect(saw_add_int);
}

test "match narrowing works for call subjects" {
    // the subject is a call, not an ident: `v` still narrows to the payload
    // type (from the fn's declared return) and `v + 1` emits add_int
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ type Res = (:ok, int) | (:err, string)
        \\ fn g() -> Res do (:ok, 42) end
        \\ match g()
        \\ | (:ok, v) => v + 1
        \\ | (:err, _) => 0
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int or inst.op == .add_int_imm) saw_add_int = true;
    }
    try std.testing.expect(saw_add_int);
}

test "return type propagation: const binding with annotated fn" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ const add = fn(a: int, b: int) a + b
        \\ let x = add(3, 4)
        \\ x + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int or inst.op == .add_int_imm) saw_add_int = true;
    }
    try std.testing.expect(saw_add_int);
}

test "return type propagation: fn five() 5" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn five() 5
        \\ let x = five()
        \\ x + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int or inst.op == .add_int_imm) saw_add_int = true;
    }
    try std.testing.expect(saw_add_int);
}

test "annotated function return type propagates to caller via pointer" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn add(a: int, b: int) a + b
        \\ let x = add(3, 4)
        \\ x + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int or inst.op == .add_int_imm) saw_add_int = true;
    }
    try std.testing.expect(saw_add_int);
}

//
// generics / type_var tests
//

fn testRuntime() revo.Runtime {
    return .{
        .alloc = std.testing.allocator,
        .io = std.testing.io,
        .diag_alloc = std.testing.allocator,
        .diag_arena = null,
    };
}

test "types: type_var equality" {
    const TI = revo.lang.compiler.types.TypeInfo;
    const a = TI{ .type_var = "T" };
    const b = TI{ .type_var = "T" };
    const c = TI{ .type_var = "U" };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(.int));
}

test "types: type_var coercion" {
    const types = revo.lang.compiler.types;
    const tv = types.TypeInfo{ .type_var = "T" };
    try std.testing.expect(types.canCoerce(tv, .int));
    try std.testing.expect(types.canCoerce(.int, tv));
    try std.testing.expect(types.canCoerce(tv, .any));
    try std.testing.expect(types.canCoerce(.any, tv));
    try std.testing.expect(types.canCoerce(tv, tv));
}

test "substituteTypeParams direct type var" {
    const types = revo.lang.compiler.types;
    const alloc = std.testing.allocator;
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();
    try subst.put("T", .int);

    const result = try types.substituteTypeParams(alloc, types.TypeInfo{ .type_var = "T" }, subst);
    try std.testing.expect(result.eql(.int));
}

test "substituteTypeParams unknown type var becomes any" {
    const types = revo.lang.compiler.types;
    const alloc = std.testing.allocator;
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();

    const result = try types.substituteTypeParams(alloc, types.TypeInfo{ .type_var = "T" }, subst);
    try std.testing.expect(result.eql(.any));
}

test "substituteTypeParams tuple with type var" {
    const types = revo.lang.compiler.types;
    const alloc = std.testing.allocator;
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();
    try subst.put("T", .int);

    const input = types.TypeInfo{ .tuple = &.{ types.TypeInfo{ .type_var = "T" }, .string } };
    const result = try types.substituteTypeParams(alloc, input, subst);
    try std.testing.expect(result == .tuple);
    try std.testing.expect(result.tuple.len == 2);
    try std.testing.expect(result.tuple[0].eql(.int));
    try std.testing.expect(result.tuple[1].eql(.string));
    alloc.free(result.tuple);
}

test "substituteTypeParams multiple type vars" {
    const types = revo.lang.compiler.types;
    const alloc = std.testing.allocator;
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();
    try subst.put("T", .int);
    try subst.put("U", .string);

    const input = types.TypeInfo{ .tuple = &.{ types.TypeInfo{ .type_var = "T" }, types.TypeInfo{ .type_var = "U" } } };
    const result = try types.substituteTypeParams(alloc, input, subst);
    try std.testing.expect(result == .tuple);
    try std.testing.expect(result.tuple.len == 2);
    try std.testing.expect(result.tuple[0].eql(.int));
    try std.testing.expect(result.tuple[1].eql(.string));
    alloc.free(result.tuple);
}

test "substituteTypeParams function sig with type var" {
    const types = revo.lang.compiler.types;
    const alloc = std.testing.allocator;
    var subst = std.StringHashMap(types.TypeInfo).init(alloc);
    defer subst.deinit();
    try subst.put("T", .int);

    const sig = try alloc.create(types.FunctionSignature);
    sig.* = .{
        .params = &.{types.TypeInfo{ .type_var = "T" }},
        .return_type = types.TypeInfo{ .type_var = "T" },
        .param_names = &.{"x"},
    };
    const input = types.TypeInfo{ .function = sig };
    const result = try types.substituteTypeParams(alloc, input, subst);
    try std.testing.expect(result == .function);
    try std.testing.expect(result.function.params.len == 1);
    try std.testing.expect(result.function.params[0].eql(.int));
    try std.testing.expect(result.function.return_type.eql(.int));
    alloc.destroy(sig);
    alloc.free(result.function.params);
    alloc.destroy(result.function);
}

test "generics identity fn enables add_int" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn id[T](x: T) x
        \\ let y = id(42)
        \\ y + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int or inst.op == .add_int_imm) saw_add_int = true;
    }
    try std.testing.expect(saw_add_int);
}

test "generics identity fn with string compiles and runs" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn id[T](x: T) x
        \\ id("hello")
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics compound return type (:ok, T) propagates inner type" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn wrap[T](x: T) -> (:ok, T) (:ok, x)
        \\ let r = wrap(42)
        \\ r[1] + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics multiple type params with tuple return compile" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn pair[T, U](a: T, b: U) -> (T, U)
        \\ pair(1, "hi")
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics non-inferrable type param (return-only) compiles" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn make[T]() 5
        \\ make()
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);
}

test "generics repeated type param works" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ fn same[T](a: T, b: T) a
        \\ let x = same(42, 99)
        \\ x + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int or inst.op == .add_int_imm) saw_add_int = true;
    }
    try std.testing.expect(saw_add_int);
}

test "explicit call-site type args make[int]() resolves return type" {
    try t.topNumber(
        \\ fn make[T]() -> T 5
        \\ make[int]()
    , 5);
}

test "explicit call-site type args id[int](42) resolves return type" {
    try t.topNumber(
        \\ fn id[T](x: T) -> T x
        \\ id[int](42)
    , 42);
}

//
// stdlib signatures flow from the semantic checker through the
// annotation bridge into the compiler
//

test "stdlib sigs: method return types reach the compiler" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{
        .text =
        \\ "abc":len() + 1
        ,
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var saw_add_int = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .add_int or inst.op == .add_int_imm) saw_add_int = true;
    }
    try std.testing.expect(saw_add_int);
}

test "stdlib sigs: global return types reach the compiler" {
    // semantic knows read/cwd from root_specs_os; misuse that compiled
    // against .any now errors before codegen
    try t.expectCompileError(
        \\ let x = cwd()
        \\ let n: int = x
    , .ParseError);
    try t.expectCompileError(
        \\ let x = read({delimiter = :eof})
        \\ let n: int = x?
    , .ParseError);
}

test "stdlib sigs source fn shadows stdlib global" {
    try t.topNumber(
        \\ const cwd = fn(x: int) x + 1
        \\ cwd(41)
    , 42);
    try t.expectCompileError(
        \\ const cwd = fn(x: int) x + 1
        \\ cwd("nope")
    , .ParseError);
}

test "stdlib sigs variadic global keeps accepting extra args" {
    try t.topString("fmt(\"%v\", 1, 2, 3)", "1");
    try t.expectCompileError(
        \\ fmt()
    , .ParseError);
}

test "stdlib sigs untyped call still validates arg count" {
    try t.expectCompileError(
        \\ cwd("nope", "more")
    , .ParseError);
}

test "stdlib sigs: module field calls resolve to spec sigs" {
    try t.topAtom("fs.exists?(\"/definitely/not/a/real/path_xyz\")?", "false");
    try t.topNumber(
        \\ table.len({1, 2}) + 1
    , 3);
    try t.expectCompileError(
        \\ let b: bool = fs.exists?("/tmp")
    , .ParseError);
}

test "stdlib sigs: module result flows through match" {
    try t.topAtom(
        \\ let r = fs.exists?("/tmp")
        \\ match r | (:ok, v) => v | (:err, e) => panic(e)
    , "true");
}

test "stdlib sigs: local binding shadows stdlib module" {
    // `fs` here is a local table, not the module: no stdlib sig is
    // applied (no static error) and the missing field fails at runtime
    try t.expectRuntimeError(
        \\ let fs = {}
        \\ fs.exists?("/tmp")
    , .NotAFunction);
}

test "stdlib sigs: try unwraps tagged tuples" {
    try t.topNumber("(:ok, 5)? + 1", 6);
    try t.topNumber(
        \\ fn res() (:ok, 5)
        \\ res()? + 1
    , 6);
    try t.topTrue("let b: bool = fs.exists?(\"/tmp\")?");
}

test "stdlib sigs: orelse unwraps results" {
    try t.topTrue("fs.exists?(\"/tmp\") orelse :false");
    try t.topNumber("(:err, \"boom\") orelse 5", 5);
}

test "stdlib sigs: try rejects non-result unions" {
    // `?` on it is a lie
    try t.expectCompileError(
        \\ "abc":find("b")?
    , .ParseError);
}

test "stdlib sigs: match narrows call-subject payloads" {
    // the subject is a call, not an ident: the payload still narrows to
    // bool, so the match result is bool (not a result) and `?` is rejected
    try t.expectCompileError(
        \\ (match fs.exists?("/tmp")
        \\ | (:ok, v) => v
        \\ | (:err, e) => panic(e))?
    , .ParseError);
}

test "eu.rv: result types flow end to end" {
    // every line of the eu.rv table: the result binds as !bool, `?` unwraps
    // to bool, and the match over it is the :ok payload
    try t.topTrue(
        \\ let x: !bool = fs.exists?("/tmp")
        \\ let b: bool = fs.exists?("/tmp")?
        \\ let r = fs.exists?("/tmp")
        \\ match r
        \\ | (:ok, v) => v
        \\ | (:err, e) => panic(e)
    );
}

test "error-union sugar and the literal form are the same union" {
    // `!bool` and `(:ok, bool) | (:err, any)` are structurally identical, so
    // a value typed with one can be bound to a slot typed with the other
    try t.topTrue(
        \\ let x: (:ok, bool) | (:err, any) = fs.exists?("/tmp")
        \\ let y: !bool = x
        \\ match y
        \\ | (:ok, v) => v
        \\ | (:err, e) => panic(e)
    );
}
