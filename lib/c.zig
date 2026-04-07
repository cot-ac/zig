//! Raw C API imports. Internal — use the typed wrappers in types.zig,
//! ops.zig, ir.zig, transform.zig, pipeline.zig instead.

pub const cir = @cImport({
    @cInclude("cot-c/CIRCApi.h");
    @cInclude("cot-c/COTCApi.h");
    @cInclude("mlir-c/IR.h");
    @cInclude("mlir-c/BuiltinTypes.h");
    @cInclude("mlir-c/BuiltinAttributes.h");
    @cInclude("mlir-c/Pass.h");
    @cInclude("mlir-c/Support.h");
});
