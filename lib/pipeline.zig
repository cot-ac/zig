//! COT compilation pipeline — sema, lowering, codegen.

const c = @import("c.zig").cir;
const ir = @import("ir.zig");
const transform = @import("transform.zig");

const Context = ir.Context;
const Module = ir.Module;

pub const Pipeline = struct {
    raw: c.CotPipelineBuilder,

    pub fn create(ctx: Context) Pipeline {
        return .{ .raw = c.cotPipelineBuilderCreate(ctx.raw) };
    }

    pub fn destroy(self: Pipeline) void {
        c.cotPipelineBuilderDestroy(self.raw);
    }

    pub fn addPreSemaPass(self: Pipeline, pass: transform.Pass) void {
        c.cotPipelineBuilderAddPreSemaPass(self.raw, pass.raw);
    }

    pub fn addPostSemaPass(self: Pipeline, pass: transform.Pass) void {
        c.cotPipelineBuilderAddPostSemaPass(self.raw, pass.raw);
    }

    pub fn addPostLoweringPass(self: Pipeline, pass: transform.Pass) void {
        c.cotPipelineBuilderAddPostLoweringPass(self.raw, pass.raw);
    }

    pub fn runToTypedCIR(self: Pipeline, module: Module) !void {
        const result = c.cotPipelineBuilderRunToTypedCIR(self.raw, module.raw);
        if (result.value == 0) return error.PipelineFailed;
    }

    pub fn runToLLVM(self: Pipeline, module: Module) !void {
        const result = c.cotPipelineBuilderRunToLLVM(self.raw, module.raw);
        if (result.value == 0) return error.PipelineFailed;
    }

    pub fn emitBinary(self: Pipeline, module: Module, output_path: [*:0]const u8) !void {
        const result = c.cotPipelineBuilderEmitBinary(self.raw, module.raw, output_path);
        if (result.value == 0) return error.PipelineFailed;
    }
};

/// Convenience: run full pipeline without a custom PipelineBuilder.
pub fn runSema(module: Module) !void {
    const result = c.cotRunSema(module.raw);
    if (result.value == 0) return error.SemaFailed;
}

pub fn lowerToLLVM(module: Module) !void {
    const result = c.cotLowerToLLVM(module.raw);
    if (result.value == 0) return error.LoweringFailed;
}

pub fn emitBinary(module: Module, output_path: [*:0]const u8) !void {
    const result = c.cotEmitBinary(module.raw, output_path);
    if (result.value == 0) return error.CodegenFailed;
}
