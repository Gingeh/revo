//!
//! zig extension, for revo
//! build: zig build   (produces zrevo.so, revo as a module dependency)
//!
//! the shared lib exports revo_bindings which import(".so") picks up
//!
const std = @import("std");
const revo = @import("revo");

const RevoBinding = revo.functions.RevoBinding;
const CRevoData = revo.functions.CRevoData;
const Data = revo.Data;
const VM = revo.VM;
const mem = revo.memory;

const nil_c = CRevoData{
    .tag = @intFromEnum(mem.Type.atom),
    .value = @intFromEnum(revo.core_atoms.nil),
};

fn num(v: f64) CRevoData {
    return .{ .tag = @intFromEnum(mem.Type.number), .value = @bitCast(v) };
}

/// > zadd(a: number, b: number) -> number
fn zadd(vm_ptr: *anyopaque, argc: usize, argv: [*]CRevoData, out: *CRevoData) callconv(.c) void {
    _ = vm_ptr;
    if (argc < 2) {
        out.* = nil_c;
        return;
    }
    const a: f64 = @bitCast(argv[0].value);
    const b: f64 = @bitCast(argv[1].value);
    out.* = num(a + b);
}

/// > zecho(s: string) -> string
/// like the c example: .value holds a string id (not a pointer),
/// so go through the vm to get the bytes
fn zecho(vm_ptr: *anyopaque, argc: usize, argv: [*]CRevoData, out: *CRevoData) callconv(.c) void {
    if (argc < 1) {
        out.* = nil_c;
        return;
    }
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const d = argv[0].toData(v) catch {
        out.* = nil_c;
        return;
    };
    const id = d.asString() orelse {
        out.* = nil_c;
        return;
    };
    const bytes = v.stringValue(id);
    const new_id = revo.ffi.revo_intern(@ptrCast(v), @intFromPtr(bytes.ptr), bytes.len);
    out.* = .{ .tag = @intFromEnum(mem.Type.string), .value = new_id };
}

/// > zsetglobal(name: string, value) -> number
/// full vm access: cast the opaque vm pointer and use the normal api
fn zsetglobal(vm_ptr: *anyopaque, argc: usize, argv: [*]CRevoData, out: *CRevoData) callconv(.c) void {
    if (argc < 2) {
        out.* = nil_c;
        return;
    }
    const v: *VM = @ptrCast(@alignCast(vm_ptr));
    const name_d = argv[0].toData(v) catch {
        out.* = nil_c;
        return;
    };
    const val = argv[1].toData(v) catch {
        out.* = nil_c;
        return;
    };
    v.setGlobal(v.stringValue(name_d.asString().?), val) catch {
        out.* = nil_c;
        return;
    };
    out.* = num(1);
}

pub export const revo_bindings = [_]RevoBinding{
    .{ .name = "zadd", .fn_ptr = @ptrCast(&zadd) },
    .{ .name = "zecho", .fn_ptr = @ptrCast(&zecho) },
    .{ .name = "zsetglobal", .fn_ptr = @ptrCast(&zsetglobal) },
    std.mem.zeroes(RevoBinding),
};
