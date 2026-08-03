const std = @import("std");
const VM = @import("VM.zig").VM;
const print_mod = @import("print.zig");

pub const core_atoms = @import("core.zig").core_atoms;

pub const StringID = usize;
pub const AtomID = usize;
pub const FunctionID = usize;
pub const TableID = usize;
pub const TupleID = usize;
pub const StructTypeID = usize;
pub const StructInstanceID = usize;

// nanbox layout: numbers stored as raw f64; boxed values set BOX_MASK and hold tag+payload
// canonicalize NaN to CANONICAL_NAN for stable bitwise checks
pub const Type = enum(u4) {
    number = 0,
    string = 1,
    atom = 2,
    function = 3,
    table = 4,
    tuple = 5,
    struct_val = 6,
    struct_type = 7,
    foreign = 8,
};

pub const PAYLOAD_MASK: u64 = 0x0000_FFFF_FFFF_FFFF;
pub const BOX_MASK: u64 = 0x7FF0_0000_0000_0000;
const TAG_SHIFT: u6 = 48;
const TAG_MASK: u64 = 0x000F;
const CANONICAL_NAN: u64 = 0x7FF8_0000_0000_0000;

pub const Data = struct {
    bits: u64,

    pub const new = struct {
        pub inline fn num(val: anytype) Data {
            const n: f64 = switch (@typeInfo(@TypeOf(val))) {
                .comptime_int, .int => @as(f64, @floatFromInt(val)),
                .comptime_float, .float => val,
                else => @compileError("new.num expects int or float"),
            };
            return Data.numberRaw(n);
        }
        pub inline fn core(comptime a: core_atoms) Data {
            return Data.new.atom(a.atomId());
        }

        pub inline fn nil() Data {
            return Data.new.core(.nil);
        }
        pub inline fn str(id: StringID) Data {
            return Data.boxed(.string, id);
        }
        pub inline fn atom(id: AtomID) Data {
            return Data.boxed(.atom, id);
        }
        pub inline fn function(id: FunctionID) Data {
            return Data.boxed(.function, id);
        }
        pub inline fn boolean(val: bool) Data {
            return if (val) Data.new.core(.true) else Data.new.core(.false);
        }
        pub inline fn table(id: TableID) Data {
            return Data.boxed(.table, id);
        }
        pub inline fn tuple(id: TupleID) Data {
            return Data.boxed(.tuple, id);
        }
        pub inline fn structVal(id: StructInstanceID) Data {
            return Data.boxed(.struct_val, id);
        }
        pub inline fn structType(id: StructTypeID) Data {
            return Data.boxed(.struct_type, id);
        }
        pub inline fn foreign(ptr: ?*anyopaque) Data {
            return Data.boxed(.foreign, @intFromPtr(ptr));
        }
    };

    pub const RenderMode = enum(u2) { display, decimal, debug, pretty };

    // canonicalize NaN to a stable quiet-NaN bit pattern
    pub inline fn numberRaw(n: f64) Data {
        var bits: u64 = @bitCast(n);
        if (std.math.isNan(n)) bits = CANONICAL_NAN;
        return .{ .bits = bits };
    }

    // pack type+payload into nanbox. debug-assert payload fits PAYLOAD_MASK
    inline fn boxed(t: Type, val: usize) Data {
        if (val != std.math.maxInt(usize)) std.debug.assert(val <= PAYLOAD_MASK);
        const pl = @as(u64, @intCast(val)) & PAYLOAD_MASK;
        return .{ .bits = BOX_MASK | (@as(u64, @intFromEnum(t)) << TAG_SHIFT) | pl };
    }

    pub inline fn tag(self: Data) Type {
        if ((self.bits & BOX_MASK) != BOX_MASK) return .number;
        if (self.bits == CANONICAL_NAN) return .number;
        const raw = (self.bits >> TAG_SHIFT) & TAG_MASK;
        if (raw > @intFromEnum(Type.foreign)) return .number;
        return @enumFromInt(raw);
    }

    pub inline fn is(self: Data, t: Type) bool {
        return self.tag() == t;
    }
    pub inline fn isNumber(self: Data) bool {
        return self.tag() == .number;
    }
    pub inline fn isString(self: Data) bool {
        return self.tag() == .string;
    }
    pub inline fn isAtom(self: Data) bool {
        return self.tag() == .atom;
    }
    pub inline fn isFunction(self: Data) bool {
        return self.tag() == .function;
    }
    pub inline fn isTable(self: Data) bool {
        return self.tag() == .table;
    }
    pub inline fn isTuple(self: Data) bool {
        return self.tag() == .tuple;
    }
    pub inline fn isStructVal(self: Data) bool {
        return self.tag() == .struct_val;
    }
    pub inline fn isStructType(self: Data) bool {
        return self.tag() == .struct_type;
    }
    pub inline fn isForeign(self: Data) bool {
        return self.tag() == .foreign;
    }

    pub inline fn asStr(self: Data) ?StringID {
        if ((self.bits & BOX_MASK) == BOX_MASK and ((self.bits >> TAG_SHIFT) & TAG_MASK) == @intFromEnum(Type.string))
            return @intCast(self.bits & PAYLOAD_MASK);
        return null;
    }

    // inline numeric accessors used in hot paths
    // asNum -> ?f64, asNumber -> error-union
    //
    // fast path: unboxed bits (ordinary f64s, including +/-inf and -nan)
    // never match BOX_MASK. only the canonical NaN (tag nibble 8, empty
    // payload) and boxed values share that pattern, so one compare separates
    // them from every real number
    pub inline fn asNum(self: Data) ?f64 {
        if ((self.bits & BOX_MASK) == BOX_MASK) {
            if (self.bits != CANONICAL_NAN)
                return null;
        }
        return @bitCast(self.bits);
    }

    pub inline fn asNumber(self: Data) !f64 {
        if (!self.isNumber()) return error.TypeError;
        return @bitCast(self.bits);
    }

    pub inline fn unboxed(self: Data) u64 {
        return @intCast(self.bits & PAYLOAD_MASK);
    }
    pub fn asString(self: Data) ?StringID {
        return if (self.isString()) @intCast(self.bits & PAYLOAD_MASK) else null;
    }

    // direct bit checks (matching asStr) so the hot accessors don't pay for
    // tag()'s canonical-nan and range guards; equivalent by construction:
    // `tag() == X` holds exactly when boxed and the tag nibble (lol nibble) is X
    pub inline fn asAtom(self: Data) ?AtomID {
        if ((self.bits & BOX_MASK) == BOX_MASK and ((self.bits >> TAG_SHIFT) & TAG_MASK) == @intFromEnum(Type.atom))
            return @intCast(self.bits & PAYLOAD_MASK);
        return null;
    }
    pub inline fn asFunction(self: Data) ?FunctionID {
        if ((self.bits & BOX_MASK) == BOX_MASK and ((self.bits >> TAG_SHIFT) & TAG_MASK) == @intFromEnum(Type.function))
            return @intCast(self.bits & PAYLOAD_MASK);
        return null;
    }
    pub inline fn asTable(self: Data) ?TableID {
        if ((self.bits & BOX_MASK) == BOX_MASK and ((self.bits >> TAG_SHIFT) & TAG_MASK) == @intFromEnum(Type.table))
            return @intCast(self.bits & PAYLOAD_MASK);
        return null;
    }
    pub inline fn asTuple(self: Data) ?TupleID {
        if ((self.bits & BOX_MASK) == BOX_MASK and ((self.bits >> TAG_SHIFT) & TAG_MASK) == @intFromEnum(Type.tuple))
            return @intCast(self.bits & PAYLOAD_MASK);
        return null;
    }
    pub inline fn asStructVal(self: Data) ?StructInstanceID {
        if ((self.bits & BOX_MASK) == BOX_MASK and
            ((self.bits >> TAG_SHIFT) & TAG_MASK) == @intFromEnum(Type.struct_val))
            return @intCast(self.bits & PAYLOAD_MASK);
        return null;
    }
    pub inline fn asStructType(self: Data) ?StructTypeID {
        if ((self.bits & BOX_MASK) == BOX_MASK and
            ((self.bits >> TAG_SHIFT) & TAG_MASK) == @intFromEnum(Type.struct_type))
            return @intCast(self.bits & PAYLOAD_MASK);
        return null;
    }
    pub fn asForeign(self: Data) ?*anyopaque {
        if ((self.bits & BOX_MASK) == BOX_MASK and ((self.bits >> TAG_SHIFT) & TAG_MASK) == @intFromEnum(Type.foreign))
            return @ptrFromInt(@as(usize, @intCast(self.bits & PAYLOAD_MASK)));
        return null;
    }

    pub inline fn rawBits(self: Data) u64 {
        return self.bits;
    }

    pub fn write(self: Data, writer: *std.Io.Writer, v: *VM, mode: RenderMode) anyerror!void {
        return print_mod.writeData(self, writer, v, mode);
    }

    pub fn print(self: Data, vm: *VM) void {
        var buf: [16]u8 = undefined;
        var stdout = vm.runtime.stdout.writer(vm.runtime.io, &buf);
        self.write(&stdout.interface, vm, .debug) catch {
            std.debug.print("<print-error>", .{});
            return;
        };
    }
};

/// integral f64 -> i64, else null (used by bitwise ops and `//`)
pub fn numToI64(n: f64) ?i64 {
    if (!std.math.isFinite(n)) return null;
    if (n < @as(f64, @floatFromInt(std.math.minInt(i64)))) return null;
    if (n >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return null;
    const t: i64 = @intFromFloat(n);
    if (@as(f64, @floatFromInt(t)) != n) return null;
    return t;
}

/// b ** e for non-negative int exponents, wrapping on overflow
pub fn ipow(base: i64, exponent: i64) i64 {
    var acc: i64 = 1;
    var b: i64 = base;
    var e: i64 = exponent;
    while (e > 0) {
        if (e & 1 == 1) acc = acc *% b;
        e >>= 1;
        if (e > 0) b = b *% b;
    }
    return acc;
}

pub inline fn isFalse(val: Data) bool {
    return ( //
        (val.bits >= Data.new.atom(0).bits //
        and val.bits <= Data.new.atom(core_atoms.lastFalse).bits) //
        or val.bits == Data.new.num(0).bits //
    );
}
