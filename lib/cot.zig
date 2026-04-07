//! COT — Construct Transformer Zig Bindings
//!
//! @import("cot") gives idiomatic Zig access to the CIR dialect and
//! COT compilation pipeline. Types and ops are organized by construct.
//!
//! Usage:
//!   const cot = @import("cot");
//!   const ctx = cot.Context.create();
//!   defer ctx.destroy();
//!   const i32ty = cot.types.i32Type(ctx);
//!   const val = cot.arith.constant.int(block, loc, i32ty, 42);

pub const c = @import("c.zig");
pub const types = @import("types.zig");
pub const ops = @import("ops.zig");
pub const ir = @import("ir.zig");
pub const transform = @import("transform.zig");
pub const pipeline = @import("pipeline.zig");
pub const sema = @import("sema.zig");

// Re-export core handle types at the top level for convenience.
pub const Context = ir.Context;
pub const Module = ir.Module;
pub const Block = ir.Block;
pub const Value = ir.Value;
pub const Type = ir.Type;
pub const Location = ir.Location;
pub const Operation = ir.Operation;

// Construct-namespaced op builders.
pub const arith = ops.arith;
pub const memory = ops.memory;
pub const flow = ops.flow;
pub const structs = ops.structs;
pub const arrays = ops.arrays;
pub const slices = ops.slices;
pub const optionals = ops.optionals;
pub const errors = ops.errors;
pub const enums = ops.enums;
pub const unions = ops.unions;
pub const testing = ops.testing;
