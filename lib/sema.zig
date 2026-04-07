//! SemanticAnalysis — type checking and cast insertion for CIR.
//!
//! This is the Zig implementation of the SemanticAnalysis pass,
//! originally written in C++ in core/arith/lib/Transform.cpp.
//! It validates that the "transforms in any language" promise works.
//!
//! What it does:
//! 1. Walks all operations in a function
//! 2. Finds func.call ops
//! 3. Looks up callee function signature via SymbolTable
//! 4. Compares each argument type vs parameter type
//! 5. Inserts cast ops (extsi, trunci, sitofp, fptosi, extf, truncf)

const c = @import("c.zig").cir;
const ir = @import("ir.zig");
const types = @import("types.zig");
const transform = @import("transform.zig");

const Operation = ir.Operation;
const Value = ir.Value;
const Type = ir.Type;
const Block = ir.Block;
const Location = ir.Location;

/// Create the SemanticAnalysis pass as a COT module pass.
/// Register this with pipeline.addPreSemaPass().
pub fn createPass() transform.Pass {
    return transform.createModulePass(
        "zig-semantic-analysis",
        "Type checking and cast insertion (Zig)",
        runOnModule,
    );
}

fn runOnModule(module_op: Operation) void {
    // Build symbol table from the module.
    const sym_table = ir.SymbolTable.create(module_op);
    defer sym_table.destroy();

    // Walk all operations in the module looking for func.call.
    module_op.walk(struct {
        fn callback(op: Operation) ir.WalkResult {
            if (!op.nameIs("func.call")) return .advance;

            // Get callee name from the "callee" attribute.
            const callee_attr = c.mlirOperationGetAttributeByName(
                op.raw,
                c.mlirStringRefCreateFromCString("callee"),
            );
            if (c.mlirAttributeIsNull(callee_attr)) return .advance;

            // FlatSymbolRef -> string
            if (!c.mlirAttributeIsAFlatSymbolRef(callee_attr)) return .advance;
            const callee_ref = c.mlirFlatSymbolRefAttrGetValue(callee_attr);
            const callee_name = callee_ref.data[0..callee_ref.length];

            // Look up callee in the parent module's symbol table.
            // We need the module op to create the symbol table.
            const parent_func = op.getParentOperation() orelse return .advance;
            const module = parent_func.getParentOperation() orelse return .advance;
            const st = ir.SymbolTable.create(module);
            defer st.destroy();

            const callee_op = st.lookup(callee_name) orelse return .advance;
            if (!callee_op.nameIs("func.func")) return .advance;

            // Get callee function type.
            const callee_type = callee_op.getFunctionType() orelse return .advance;
            if (!types.isFunction(callee_type)) return .advance;

            const num_inputs = types.functionNumInputs(callee_type);
            const num_args = op.getNumOperands();
            const count = @min(num_args, num_inputs);

            var i: usize = 0;
            while (i < count) : (i += 1) {
                const arg = op.getOperand(i);
                const arg_type = arg.getType();
                const param_type = types.functionInput(callee_type, i);

                if (types.typeEqual(arg_type, param_type)) continue;

                // Insert cast before the call op.
                const cast_result = insertCast(op, arg, arg_type, param_type);
                if (cast_result) |cast_val| {
                    op.setOperand(i, cast_val);
                }
            }

            return .advance;
        }
    }.callback);
}

/// Insert the correct cast op for a type pair.
/// Builds the new op and inserts it before `before_op`.
fn insertCast(
    before_op: Operation,
    input: Value,
    src_type: Type,
    dst_type: Type,
) ?Value {
    const loc = before_op.getLocation();
    const block = before_op.getBlock();

    if (types.isInteger(src_type)) {
        if (types.isInteger(dst_type)) {
            const src_w = types.integerWidth(src_type);
            const dst_w = types.integerWidth(dst_type);
            if (src_w < dst_w) {
                return buildCastOp(block, before_op, "cir.extsi", loc, input, dst_type);
            }
            if (src_w > dst_w) {
                return buildCastOp(block, before_op, "cir.trunci", loc, input, dst_type);
            }
        }
        if (types.isFloat(dst_type)) {
            return buildCastOp(block, before_op, "cir.sitofp", loc, input, dst_type);
        }
    }

    if (types.isFloat(src_type)) {
        if (types.isInteger(dst_type)) {
            return buildCastOp(block, before_op, "cir.fptosi", loc, input, dst_type);
        }
        if (types.isFloat(dst_type)) {
            const src_w = types.floatWidth(src_type);
            const dst_w = types.floatWidth(dst_type);
            if (src_w < dst_w) {
                return buildCastOp(block, before_op, "cir.extf", loc, input, dst_type);
            }
            if (src_w > dst_w) {
                return buildCastOp(block, before_op, "cir.truncf", loc, input, dst_type);
            }
        }
    }

    return null;
}

/// Build a unary cast op (1 operand, 1 result) and insert before ref_op.
fn buildCastOp(
    block: Block,
    ref_op: Operation,
    op_name: [*:0]const u8,
    loc: Location,
    input: Value,
    result_type: Type,
) Value {
    var state = ir.OperationState.get(op_name, loc);
    state.addOperands(&.{input});
    state.addResults(&.{result_type});
    const new_op = state.create();
    block.insertOwnedOperationBefore(ref_op, new_op);
    return .{ .raw = c.mlirOperationGetResult(new_op.raw, 0) };
}
