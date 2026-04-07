//! IR handle types and inspection functions.
//! Wraps mlir-c/IR.h with Zig-idiomatic types.

const c = @import("c.zig").cir;

// ===----------------------------------------------------------------------===
// Handle types — zero-cost wrappers around MLIR C opaque pointers.
// ===----------------------------------------------------------------------===

pub const Context = struct {
    raw: c.MlirContext,

    pub fn create() Context {
        c.cirForceConstructLink();
        const ctx = c.mlirContextCreate();
        c.cotInitContext(ctx);
        c.cirRegisterDialect(ctx);
        c.cirRegisterConstructs(ctx);
        return .{ .raw = ctx };
    }

    pub fn destroy(self: Context) void {
        c.mlirContextDestroy(self.raw);
    }
};

pub const Location = struct {
    raw: c.MlirLocation,

    pub fn fileLineCol(ctx: Context, filename: [*:0]const u8, line: u32, col: u32) Location {
        return .{ .raw = c.cirLocationFileLineCol(ctx.raw, filename, line, col) };
    }

    pub fn unknown(ctx: Context) Location {
        return .{ .raw = c.mlirLocationUnknownGet(ctx.raw) };
    }
};

pub const Module = struct {
    raw: c.MlirModule,

    pub fn createEmpty(loc: Location) Module {
        return .{ .raw = c.mlirModuleCreateEmpty(loc.raw) };
    }

    pub fn destroy(self: Module) void {
        c.mlirModuleDestroy(self.raw);
    }

    pub fn body(self: Module) Block {
        return .{ .raw = c.mlirModuleGetBody(self.raw) };
    }

    pub fn getOperation(self: Module) Operation {
        return .{ .raw = c.mlirModuleGetOperation(self.raw) };
    }
};

pub const Block = struct {
    raw: c.MlirBlock,

    pub fn create(nArgs: usize, argTypes: ?[*]const Type, argLocs: ?[*]const Location) Block {
        return .{ .raw = c.mlirBlockCreate(
            @intCast(nArgs),
            if (argTypes) |a| @ptrCast(a) else null,
            if (argLocs) |l| @ptrCast(l) else null,
        ) };
    }

    pub fn appendOwnedOperation(self: Block, op: Operation) void {
        c.mlirBlockAppendOwnedOperation(self.raw, op.raw);
    }

    pub fn insertOwnedOperationBefore(self: Block, ref: Operation, op: Operation) void {
        c.mlirBlockInsertOwnedOperationBefore(self.raw, ref.raw, op.raw);
    }

    pub fn firstOperation(self: Block) ?Operation {
        const op = c.mlirBlockGetFirstOperation(self.raw);
        return if (c.mlirOperationIsNull(op)) null else .{ .raw = op };
    }

    /// Get the block argument at the given index.
    pub fn getArgument(self: Block, index: usize) Value {
        return .{ .raw = c.cirBlockGetArgument(self.raw, @intCast(index)) };
    }
};

pub const Region = struct {
    raw: c.MlirRegion,

    pub fn create() Region {
        return .{ .raw = c.mlirRegionCreate() };
    }

    pub fn appendOwnedBlock(self: Region, block: Block) void {
        c.mlirRegionAppendOwnedBlock(self.raw, block.raw);
    }
};

pub const Value = struct {
    raw: c.MlirValue,

    pub fn getType(self: Value) Type {
        return .{ .raw = c.mlirValueGetType(self.raw) };
    }

    pub fn replaceAllUsesWith(self: Value, replacement: Value) void {
        c.mlirValueReplaceAllUsesOfWith(self.raw, replacement.raw);
    }

    pub fn isNull(self: Value) bool {
        return self.raw.ptr == null;
    }
};

pub const Type = struct {
    raw: c.MlirType,
};

pub const Operation = struct {
    raw: c.MlirOperation,

    pub fn isNull(self: Operation) bool {
        return c.mlirOperationIsNull(self.raw);
    }

    pub fn getName(self: Operation) []const u8 {
        const ident = c.mlirOperationGetName(self.raw);
        const str = c.mlirIdentifierStr(ident);
        return str.data[0..str.length];
    }

    pub fn nameIs(self: Operation, name: [*:0]const u8) bool {
        return c.cirOperationIsA(self.raw, name);
    }

    pub fn getOperand(self: Operation, index: usize) Value {
        return .{ .raw = c.mlirOperationGetOperand(self.raw, @intCast(index)) };
    }

    pub fn getResult(self: Operation, index: usize) Value {
        return .{ .raw = c.mlirOperationGetResult(self.raw, @intCast(index)) };
    }

    pub fn getNumOperands(self: Operation) usize {
        return @intCast(c.mlirOperationGetNumOperands(self.raw));
    }

    pub fn getNumResults(self: Operation) usize {
        return @intCast(c.mlirOperationGetNumResults(self.raw));
    }

    pub fn getResultType(self: Operation) Type {
        return .{ .raw = c.cirOperationGetResultType(self.raw) };
    }

    pub fn getLocation(self: Operation) Location {
        return .{ .raw = c.mlirOperationGetLocation(self.raw) };
    }

    pub fn getBlock(self: Operation) Block {
        return .{ .raw = c.mlirOperationGetBlock(self.raw) };
    }

    pub fn nextInBlock(self: Operation) ?Operation {
        const next = c.mlirOperationGetNextInBlock(self.raw);
        return if (c.mlirOperationIsNull(next)) null else .{ .raw = next };
    }

    pub fn removeFromParent(self: Operation) void {
        c.mlirOperationRemoveFromParent(self.raw);
    }

    pub fn erase(self: Operation) void {
        c.mlirOperationDestroy(self.raw);
    }

    pub fn getRegion(self: Operation, index: usize) Region {
        return .{ .raw = c.mlirOperationGetRegion(self.raw, @intCast(index)) };
    }

    pub fn setOperand(self: Operation, index: usize, value: Value) void {
        c.mlirOperationSetOperand(self.raw, @intCast(index), value.raw);
    }

    pub fn getParentOperation(self: Operation) ?Operation {
        const parent = c.mlirOperationGetParentOperation(self.raw);
        return if (c.mlirOperationIsNull(parent)) null else .{ .raw = parent };
    }

    /// Get an attribute by name, returning the function type if it's a TypeAttr.
    pub fn getFunctionType(self: Operation) ?Type {
        const attr = c.mlirOperationGetAttributeByName(
            self.raw,
            c.mlirStringRefCreateFromCString("function_type"),
        );
        if (c.mlirAttributeIsNull(attr)) return null;
        // TypeAttr wraps a Type.
        if (!c.mlirAttributeIsAType(attr)) return null;
        return .{ .raw = c.mlirTypeAttrGetValue(attr) };
    }

    /// Walk all operations in post-order.
    pub fn walk(self: Operation, comptime callback: fn (Operation) WalkResult) void {
        const Wrapper = struct {
            fn cb(op: c.MlirOperation, _: ?*anyopaque) callconv(.c) c.MlirWalkResult {
                return switch (callback(.{ .raw = op })) {
                    .advance => c.MlirWalkResultAdvance,
                    .interrupt => c.MlirWalkResultInterrupt,
                    .skip => c.MlirWalkResultSkip,
                };
            }
        };
        c.mlirOperationWalk(self.raw, Wrapper.cb, null, c.MlirWalkPostOrder);
    }
};

pub const WalkResult = enum {
    advance,
    interrupt,
    skip,
};

// ===----------------------------------------------------------------------===
// SymbolTable — for looking up func.func by callee name.
// ===----------------------------------------------------------------------===

pub const SymbolTable = struct {
    raw: c.MlirSymbolTable,

    pub fn create(module_op: Operation) SymbolTable {
        return .{ .raw = c.mlirSymbolTableCreate(module_op.raw) };
    }

    pub fn destroy(self: SymbolTable) void {
        c.mlirSymbolTableDestroy(self.raw);
    }

    pub fn lookup(self: SymbolTable, name: []const u8) ?Operation {
        const ref = c.MlirStringRef{ .data = name.ptr, .length = name.len };
        const op = c.mlirSymbolTableLookup(self.raw, ref);
        return if (c.mlirOperationIsNull(op)) null else .{ .raw = op };
    }
};

// ===----------------------------------------------------------------------===
// Operation building helpers (raw — for creating func.func, func.return, etc.)
// ===----------------------------------------------------------------------===

pub const OperationState = struct {
    raw: c.MlirOperationState,

    pub fn get(name: [*:0]const u8, loc: Location) OperationState {
        return .{ .raw = c.mlirOperationStateGet(
            c.mlirStringRefCreateFromCString(name),
            loc.raw,
        ) };
    }

    pub fn addOperands(self: *OperationState, operands: []const Value) void {
        c.mlirOperationStateAddOperands(
            &self.raw,
            @intCast(operands.len),
            @ptrCast(operands.ptr),
        );
    }

    pub fn addResults(self: *OperationState, result_types: []const Type) void {
        c.mlirOperationStateAddResults(
            &self.raw,
            @intCast(result_types.len),
            @ptrCast(result_types.ptr),
        );
    }

    pub fn addOwnedRegions(self: *OperationState, regions: []const Region) void {
        c.mlirOperationStateAddOwnedRegions(
            &self.raw,
            @intCast(regions.len),
            @ptrCast(@constCast(regions.ptr)),
        );
    }

    pub fn addAttribute(self: *OperationState, ctx: Context, name: [*:0]const u8, attr: Attribute) void {
        const named = c.mlirNamedAttributeGet(
            c.mlirIdentifierGet(ctx.raw, c.mlirStringRefCreateFromCString(name)),
            attr.raw,
        );
        c.mlirOperationStateAddAttributes(&self.raw, 1, &named);
    }

    pub fn create(self: *OperationState) Operation {
        return .{ .raw = c.mlirOperationCreate(&self.raw) };
    }
};

pub const Attribute = struct {
    raw: c.MlirAttribute,

    pub fn string(ctx: Context, value: [*:0]const u8) Attribute {
        return .{ .raw = c.mlirStringAttrGet(
            ctx.raw,
            c.mlirStringRefCreateFromCString(value),
        ) };
    }

    pub fn typeAttr(ty: Type) Attribute {
        return .{ .raw = c.mlirTypeAttrGet(ty.raw) };
    }

    pub fn flatSymbolRef(ctx: Context, name: [*:0]const u8) Attribute {
        return .{ .raw = c.mlirFlatSymbolRefAttrGet(
            ctx.raw,
            c.mlirStringRefCreateFromCString(name),
        ) };
    }
};
