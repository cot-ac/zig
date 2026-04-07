//! Transform authoring — create CIR passes from Zig callbacks.

const c = @import("c.zig").cir;
const ir = @import("ir.zig");
const Operation = ir.Operation;

/// Create a module-level pass. The callback receives the module op.
pub fn createModulePass(
    name: [*:0]const u8,
    description: [*:0]const u8,
    comptime run: fn (Operation) void,
) Pass {
    const Wrapper = struct {
        fn cb(op: c.MlirOperation, _: ?*anyopaque) callconv(.c) void {
            run(.{ .raw = op });
        }
    };
    return .{ .raw = c.cotCreateModulePass(name, description, Wrapper.cb, null) };
}

/// Create a function-level pass. The callback runs for each func.func.
pub fn createFuncPass(
    name: [*:0]const u8,
    description: [*:0]const u8,
    comptime run: fn (Operation) void,
) Pass {
    const Wrapper = struct {
        fn cb(op: c.MlirOperation, _: ?*anyopaque) callconv(.c) void {
            run(.{ .raw = op });
        }
    };
    return .{ .raw = c.cotCreateFuncPass(name, description, Wrapper.cb, null) };
}

pub const Pass = struct {
    raw: c.MlirPass,
};
