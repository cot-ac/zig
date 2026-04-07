//! Zig SemanticAnalysis Integration Test
//!
//! Builds a CIR module with a type mismatch in a function call,
//! runs the Zig-written SemanticAnalysis pass, and verifies the
//! pipeline inserts the correct cast and produces a valid binary.
//!
//! The program:
//!   func @add_i64(%a: i64, %b: i64) -> i64 {
//!     %r = cir.add %a, %b : i64
//!     return %r : i64
//!   }
//!   func @main() -> i32 {
//!     %x = cir.constant 20 : i32      // i32, but callee wants i64
//!     %y = cir.constant 22 : i32      // same
//!     %r64 = call @add_i64(%x, %y)    // sema should insert extsi i32->i64
//!     %r = cir.trunci %r64 : i32      // truncate back for return
//!     return %r : i32
//!   }
//!
//! Without sema: call would fail (type mismatch i32 vs i64).
//! With sema: extsi inserted, call works, result = 42, trunci -> i32.
//! Expected exit code: 42.

const std = @import("std");
const cot = @import("cot");

pub fn main() !void {
    const ctx = cot.Context.create();
    defer ctx.destroy();
    const loc = cot.Location.fileLineCol(ctx, "sema_test.ac", 1, 1);

    const module = cot.Module.createEmpty(loc);
    defer module.destroy();
    const module_body = module.body();

    const i32ty = cot.types.i32Type(ctx);
    const i64ty = cot.types.i64Type(ctx);

    // --- func @add_i64(%a: i64, %b: i64) -> i64 ---
    {
        const func_type = cot.types.functionType(ctx, &.{ i64ty, i64ty }, &.{i64ty});
        const body_region = cot.ir.Region.create();
        const entry = cot.Block.create(2, &.{ i64ty, i64ty }, &.{ loc, loc });
        body_region.appendOwnedBlock(entry);

        var state = cot.ir.OperationState.get("func.func", loc);
        state.addAttribute(ctx, "sym_name", cot.ir.Attribute.string(ctx, "add_i64"));
        state.addAttribute(ctx, "function_type", cot.ir.Attribute.typeAttr(func_type));
        state.addOwnedRegions(&.{body_region});
        const func_op = state.create();
        module_body.appendOwnedOperation(func_op);

        // %r = cir.add %a, %b
        const arg_a = cot.Value{ .raw = cot.c.cir.mlirBlockGetArgument(entry.raw, 0) };
        const arg_b = cot.Value{ .raw = cot.c.cir.mlirBlockGetArgument(entry.raw, 1) };
        const r = cot.arith.add(entry, loc, arg_a, arg_b);

        var ret_state = cot.ir.OperationState.get("func.return", loc);
        ret_state.addOperands(&.{r});
        entry.appendOwnedOperation(ret_state.create());
    }

    // --- func @main() -> i32 ---
    {
        const func_type = cot.types.functionType(ctx, &.{}, &.{i32ty});
        const body_region = cot.ir.Region.create();
        const entry = cot.Block.create(0, null, null);
        body_region.appendOwnedBlock(entry);

        var state = cot.ir.OperationState.get("func.func", loc);
        state.addAttribute(ctx, "sym_name", cot.ir.Attribute.string(ctx, "main"));
        state.addAttribute(ctx, "function_type", cot.ir.Attribute.typeAttr(func_type));
        state.addOwnedRegions(&.{body_region});
        const func_op = state.create();
        module_body.appendOwnedOperation(func_op);

        // %x = cir.constant 20 : i32
        const x = cot.arith.constant.int(entry, loc, i32ty, 20);
        // %y = cir.constant 22 : i32
        const y = cot.arith.constant.int(entry, loc, i32ty, 22);

        // %r64 = call @add_i64(%x, %y) -> i64
        // (type mismatch: passing i32 to i64 param — sema should fix this)
        var call_state = cot.ir.OperationState.get("func.call", loc);
        call_state.addOperands(&.{ x, y });
        call_state.addResults(&.{i64ty});
        call_state.addAttribute(ctx, "callee", cot.ir.Attribute{ .raw = cot.c.cir.mlirFlatSymbolRefAttrGet(
            ctx.raw,
            cot.c.cir.mlirStringRefCreateFromCString("add_i64"),
        ) });
        const call_op = call_state.create();
        entry.appendOwnedOperation(call_op);
        const r64 = cot.Value{ .raw = cot.c.cir.mlirOperationGetResult(call_op.raw, 0) };

        // %r = cir.trunci %r64 : i64 to i32
        const r = cot.arith.truncI(entry, loc, r64, i32ty);

        var ret_state = cot.ir.OperationState.get("func.return", loc);
        ret_state.addOperands(&.{r});
        entry.appendOwnedOperation(ret_state.create());
    }

    // --- Run pipeline with Zig sema ---
    const pipe = cot.pipeline.Pipeline.create(ctx);
    defer pipe.destroy();

    // Add Zig-written SemanticAnalysis as a pre-sema pass.
    pipe.addPreSemaPass(cot.sema.createPass());

    try pipe.emitBinary(module, "/tmp/cot_zig_sema_test");

    // Verify output.
    const exit_raw = cot.c.cir.system("/tmp/cot_zig_sema_test");
    const exit_code: u8 = @truncate(@as(u32, @bitCast(exit_raw)) >> 8);
    if (exit_code == 42) {
        std.debug.print("PASS: zig sema test (exit code = {d})\n", .{exit_code});
    } else {
        std.debug.print("FAIL: expected exit code 42, got {d}\n", .{exit_code});
        std.process.exit(1);
    }
}
