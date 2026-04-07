//! COT Zig Binding Test
//!
//! Builds a CIR module in pure Zig, runs the pipeline, and produces a
//! native binary — proving @import("cot") works end-to-end.
//!
//! The program:
//!   func @main() -> i32 {
//!     %a = cir.constant 30 : i32
//!     %b = cir.constant 12 : i32
//!     %r = cir.add %a, %b : i32
//!     return %r : i32
//!   }

const std = @import("std");
const cot = @import("cot");

pub fn main() !void {
    // 1. Create context (registers CIR dialect + all constructs).
    const ctx = cot.Context.create();
    defer ctx.destroy();

    const loc = cot.Location.fileLineCol(ctx, "zig_test.ac", 1, 1);

    // 2. Create module.
    const module = cot.Module.createEmpty(loc);
    defer module.destroy();
    const module_body = module.body();

    // 3. Build func @main() -> i32.
    const i32ty = cot.types.i32Type(ctx);
    const func_type = cot.types.functionType(ctx, &.{}, &.{i32ty});

    const body_region = cot.ir.Region.create();
    const entry_block = cot.Block.create(0, null, null);
    body_region.appendOwnedBlock(entry_block);

    var func_state = cot.ir.OperationState.get("func.func", loc);
    func_state.addAttribute(ctx, "sym_name", cot.ir.Attribute.string(ctx, "main"));
    func_state.addAttribute(ctx, "function_type", cot.ir.Attribute.typeAttr(func_type));
    func_state.addOwnedRegions(&.{body_region});
    const func_op = func_state.create();
    module_body.appendOwnedOperation(func_op);

    // 4. Build ops in the entry block.
    const a = cot.arith.constant.int(entry_block, loc, i32ty, 30);
    const b = cot.arith.constant.int(entry_block, loc, i32ty, 12);
    const r = cot.arith.add(entry_block, loc, a, b);

    // return %r
    var ret_state = cot.ir.OperationState.get("func.return", loc);
    ret_state.addOperands(&.{r});
    const ret_op = ret_state.create();
    entry_block.appendOwnedOperation(ret_op);

    // 5. Run pipeline -> emit binary.
    const pipe = cot.pipeline.Pipeline.create(ctx);
    defer pipe.destroy();
    try pipe.emitBinary(module, "/tmp/cot_zig_binding_test");

    std.debug.print("PASS: zig binding test (binary at /tmp/cot_zig_binding_test)\n", .{});
}
