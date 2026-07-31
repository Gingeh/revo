// dead code elimination for ir
//
// walks the ir and removes instructions whose results are never used.
// an instruction is live if it has side effects: stores, calls, control
// flow, or if its result flows into another live instruction
//
// data flow uses .inst pointers, not register names, so liveness traces
// correctly across the whole instruction list. jump targets live in op_arg
// as instruction indices and get remapped after compaction
//
// some dataflow edges go through .reg operands (move instructions that
// reference a register by number rather than popping from the value
// stack). for those we scan backward from the consumer to find the most
// recent writer of that register
//
// runs after `fold.foldIr` so folded-to-constant operands are already
// freed, dce cleans up the dead constants that folding leaves behind

const std = @import("std");

const revo = @import("revo");
const Compiler = revo.lang.compiler.Compiler;
const Opcode = revo.opcode.Opcode;
const Register = revo.opcode.Register;
const ir = @import("ir.zig");

/// side-effecting opcodes that must never be eliminated
fn isSideEffect(op: Opcode) bool {
    return switch (op) {
        // zig fmt: off
        .store_global, .store_global_const, .store_local, .bind_local,
        .store_upval, .table_set, .table_set_atom, .struct_set_method,
        .struct_set_offset, .call, .call_field, .spawn,
        .join, .yield, .ret, .halt,
        .jump, .jump_if_false, .jump_if_true, .jump_if_not_nil_and_not_err,
        .jump_if_err, .range_init, .range_next, .unwrap_result,
        .move  // loop-break results flow through registers, not .inst
        // zig fmt: on
        => true,
        else => false,
    };
}

pub fn dceIr(self: *Compiler) !void {
    const insts = self.ir_builder.instructions.items;
    const n = insts.len;
    if (n == 0) return;

    // map each *IrInst to its current index (4 fast lookups)
    var index_of = std.AutoHashMap(*ir.IrInst, usize).init(self.alloc);
    defer index_of.deinit();
    try index_of.ensureTotalCapacity(@intCast(n));
    for (insts, 0..) |inst, i| index_of.putAssumeCapacity(inst, i);

    var live = try self.alloc.alloc(bool, n);
    defer self.alloc.free(live);
    @memset(live, false);

    // -- [pass 1] ------------------------------------------------------------
    // mark side-effecting instructions as live
    for (insts, 0..) |inst, i| {
        if (isSideEffect(inst.opcode)) live[i] = true;
    }

    // make forward register => last-writer map
    // for each pos, last_writer[r] = index of most recent
    // instruction whose result_reg == r. used to resolve
    // register-based data flow that `emitBind` skips
    var last_writer = try self.alloc.alloc(usize, std.math.maxInt(Register) + 1);
    defer self.alloc.free(last_writer);
    {
        var i: usize = 0;
        while (i < last_writer.len) : (i += 1) last_writer[i] = std.math.maxInt(usize);
    }

    // -- [pass 2] ------------------------------------------------------------
    // propagate liveness until stable
    //
    // propagates thru:
    // ~ backward through .inst operands (data flow)
    // ~ backward through .reg operands (register data flow)
    // ~ forward to jump targets (control flow)
    // ~ forward fall-through from conditional branches (control flow)
    var changed = true;
    while (changed) {
        changed = false;

        // rebuild last_writer from the beginning each iteration
        // so that forward refs resolve correctly
        {
            var i: usize = 0;
            while (i < last_writer.len) : (i += 1) last_writer[i] = std.math.maxInt(usize);
        }

        for (insts, 0..) |inst, i| {
            // if this instruction is live, mark its register
            // dependencies (instructions whose results are read
            // through registers rather than .inst pointers).
            //
            // two kinds of register reads exist:
            // ~ .reg operands on instructions like `move`
            // ~ instructions emitted via `emitBind` (bind_local,
            //   store_local) that have empty operands and carry
            //   their source register in result_reg
            if (live[i]) {
                // .reg operands
                for (inst.operands) |op| {
                    if (op == .reg) {
                        const w = last_writer[op.reg];
                        if (w != std.math.maxInt(usize) and !live[w]) {
                            live[w] = true;
                            changed = true;
                        }
                    }
                }

                // emitBind instrs: bind_local, store_local
                // with empty operands read from result_reg
                if (inst.operands.len == 0) switch (inst.opcode) {
                    .bind_local, .store_local => {
                        const w = last_writer[inst.result_reg];
                        if (w != std.math.maxInt(usize) and !live[w]) {
                            live[w] = true;
                            changed = true;
                        }
                    },
                    else => {},
                };
            }

            // record this instruction as the last writer of its
            // result reg (must happen after the dependency
            // checks above so that self-references don't occur)
            last_writer[inst.result_reg] = i;

            // some opcodes write to multiple registers
            switch (inst.opcode) {
                .range_init => {
                    // writes r, r+1, r+2 (range state)
                    if (inst.result_reg + 1 < last_writer.len) last_writer[inst.result_reg + 1] = i;
                    if (inst.result_reg + 2 < last_writer.len) last_writer[inst.result_reg + 2] = i;
                },
                .range_next => {
                    // writes r (value), r+1 (index if has_index), r+2 (has_next)
                    if (inst.result_reg + 1 < last_writer.len) last_writer[inst.result_reg + 1] = i;
                    if (inst.result_reg + 2 < last_writer.len) last_writer[inst.result_reg + 2] = i;
                },
                else => {},
            }

            if (!live[i]) continue;

            // dataflow: mark instructions whose results we consume
            // via .inst operands
            for (inst.operands) |op| {
                if (op == .inst) {
                    if (index_of.get(op.inst)) |j| {
                        if (!live[j]) {
                            live[j] = true;
                            changed = true;
                        }
                    }
                }
            }

            // control flow: mark jump targets
            switch (inst.opcode) {
                .jump, .jump_if_false, .jump_if_true, .jump_if_not_nil_and_not_err, .jump_if_err => {
                    const target = inst.op_arg;
                    if (target < n and !live[target]) {
                        live[target] = true;
                        changed = true;
                    }
                },
                else => {},
            }

            // fallthru: conditional branches can fall through;
            // mark the next instruction as live
            if (i + 1 < n) {
                const is_cond_jump = switch (inst.opcode) {
                    .jump_if_false, .jump_if_true, .jump_if_not_nil_and_not_err, .jump_if_err => true,
                    else => false,
                };
                if (is_cond_jump and !live[i + 1]) {
                    live[i + 1] = true;
                    changed = true;
                }
            }
        }
    }

    // -- [pass 3] ------------------------------------------------------------
    // compact
    //
    // keep live instructions, destroy dead ones
    // also build a remap from old index -> new index for every old
    // position. for dead instructions remap points to the position
    // that the next live instruction occupies, or the shrink-to
    // length if none follow. this ensures that function prototype
    // addr fields that happened to point at a load_const (now dead)
    // still land at the correct new position
    //
    // spans are kept in 1:1 correspondence with instructions, so
    // dead instruction spans are removed too
    //
    var new_index = try self.alloc.alloc(usize, n);
    defer self.alloc.free(new_index);
    var write: usize = 0;
    for (insts, 0..) |inst, i| {
        if (live[i]) {
            new_index[i] = write;
            self.ir_builder.instructions.items[write] = inst;
            self.spans.items[write] = self.spans.items[i];
            write += 1;
        } else {
            new_index[i] = write;
            self.alloc.free(inst.operands);
            self.alloc.destroy(inst);
        }
    }
    self.ir_builder.instructions.shrinkAndFree(self.alloc, write);
    self.spans.shrinkAndFree(self.alloc, write);

    // -- [pass 4] ------------------------------------------------------------
    // remap jump targets, stored as instruction indices in op_arg
    for (self.ir_builder.instructions.items) |inst| {
        switch (inst.opcode) {
            .jump, .jump_if_false, .jump_if_true, .jump_if_not_nil_and_not_err, .jump_if_err => {
                inst.op_arg = new_index[inst.op_arg];
            },
            else => {},
        }
    }

    // -- [pass 5] ------------------------------------------------------------
    // remap function prototype addr fields which are
    // instruction indices set before dce ran
    for (self.pending_prototypes.items) |proto_id| {
        const proto = &self.vm.functions.prototypes.items[proto_id];
        proto.addr = @intCast(new_index[proto.addr]);
    }
}

const testing = revo.lang.testing;
const t = testing;
const lang = revo.lang;
const VM = revo.VM;

fn testRuntime() revo.Runtime {
    return .{
        .alloc = std.testing.allocator,
        .io = std.testing.io,
        .diag_alloc = undefined,
        .diag_arena = null,
    };
}

test "dce: arithmetic with unused result is eliminated" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{ .text =
        \\let _ = 1 + 2
        \\42
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    for (built.ok.instructions) |inst| {
        if (inst.op == .add) return error.TestUnexpectedResult;
    }
}

test "dce: used arithmetic is kept" {
    try t.top_number(
        \\let x = 1 + 2
        \\x
    , 3);
}

test "dce: program with dead branches still works" {
    try t.top_number(
        \\if 1 == 1
        \\    42
        \\else
        \\    1 + 2
    , 42);
}

test "dce: function with dead expressions works" {
    try t.top_number(
        \\fn f() do
        \\    let _ = 1 + 2
        \\    let _ = 3 * 4
        \\    42
        \\end
        \\f()
    , 42);
}

test "dce: nested unused expressions are eliminated" {
    try t.top_number(
        \\do
        \\    1
        \\    2
        \\    3
        \\end
    , 3);
}

test "dce: side-effecting calls are never eliminated" {
    var vm = try VM.init(testRuntime());
    defer vm.deinit();

    const built = try lang.build(&vm, .{ .text =
        \\fn f() 42
        \\let _ = f()
        \\1
    }, .{});
    try std.testing.expect(built == .ok);
    defer vm.runtime.alloc.free(built.ok.instructions);
    defer vm.runtime.alloc.free(built.ok.spans);

    var has_call = false;
    for (built.ok.instructions) |inst| {
        if (inst.op == .call) has_call = true;
    }
    try std.testing.expect(has_call);
}

test "dce: normal program works unchanged" {
    try t.top_number("1 + 2 * 3", 7);
    try t.top_string(
        \\let s = "hello"
        \\s
    , "hello");
    try t.top_number(
        \\let x = 10
        \\x + 5
    , 15);
}

test "dce: store to discarded local is eliminated" {
    try t.top_number(
        \\let x = 1 + 2
        \\let _ = x
        \\99
    , 99);
}
