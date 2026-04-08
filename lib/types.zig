//! CIR type constructors and inspectors, organized by construct.

const c = @import("c.zig").cir;
const ir = @import("ir.zig");
const Context = ir.Context;
const Type = ir.Type;

// ===----------------------------------------------------------------------===
// Primitive types (from MLIR builtins)
// ===----------------------------------------------------------------------===

pub fn i1Type(ctx: Context) Type {
    return .{ .raw = c.mlirIntegerTypeGet(ctx.raw, 1) };
}
pub fn i8Type(ctx: Context) Type {
    return .{ .raw = c.mlirIntegerTypeGet(ctx.raw, 8) };
}
pub fn i16Type(ctx: Context) Type {
    return .{ .raw = c.mlirIntegerTypeGet(ctx.raw, 16) };
}
pub fn i32Type(ctx: Context) Type {
    return .{ .raw = c.mlirIntegerTypeGet(ctx.raw, 32) };
}
pub fn i64Type(ctx: Context) Type {
    return .{ .raw = c.mlirIntegerTypeGet(ctx.raw, 64) };
}
pub fn integerType(ctx: Context, width: u32) Type {
    return .{ .raw = c.mlirIntegerTypeGet(ctx.raw, width) };
}
pub fn f32Type(ctx: Context) Type {
    return .{ .raw = c.mlirF32TypeGet(ctx.raw) };
}
pub fn f64Type(ctx: Context) Type {
    return .{ .raw = c.mlirF64TypeGet(ctx.raw) };
}
pub fn functionType(ctx: Context, inputs: []const Type, results: []const Type) Type {
    return .{ .raw = c.mlirFunctionTypeGet(
        ctx.raw,
        @intCast(inputs.len),
        @ptrCast(inputs.ptr),
        @intCast(results.len),
        @ptrCast(results.ptr),
    ) };
}

// ===----------------------------------------------------------------------===
// Memory types
// ===----------------------------------------------------------------------===

pub fn ptrType(ctx: Context) Type {
    return .{ .raw = c.cirPointerTypeGet(ctx.raw) };
}
pub fn refType(pointee: Type) Type {
    return .{ .raw = c.cirRefTypeGet(pointee.raw) };
}
pub fn refPointee(ty: Type) Type {
    return .{ .raw = c.cirRefTypeGetPointee(ty.raw) };
}

// ===----------------------------------------------------------------------===
// Struct types
// ===----------------------------------------------------------------------===

pub fn structType(ctx: Context, name: [*:0]const u8, field_names: []const [*:0]const u8, field_types: []const Type) Type {
    return .{ .raw = c.cirStructTypeGet(
        ctx.raw,
        name,
        @intCast(field_names.len),
        @ptrCast(field_names.ptr),
        @ptrCast(field_types.ptr),
    ) };
}
pub fn structName(ty: Type) []const u8 {
    const s = c.cirStructTypeGetName(ty.raw);
    return s.data[0..s.length];
}
pub fn structNumFields(ty: Type) usize {
    return @intCast(c.cirStructTypeGetNumFields(ty.raw));
}
pub fn structFieldName(ty: Type, index: usize) []const u8 {
    const s = c.cirStructTypeGetFieldName(ty.raw, @intCast(index));
    return s.data[0..s.length];
}
pub fn structFieldType(ty: Type, index: usize) Type {
    return .{ .raw = c.cirStructTypeGetFieldType(ty.raw, @intCast(index)) };
}

// ===----------------------------------------------------------------------===
// Array types
// ===----------------------------------------------------------------------===

pub fn arrayType(ctx: Context, size: i64, element: Type) Type {
    return .{ .raw = c.cirArrayTypeGet(ctx.raw, size, element.raw) };
}
pub fn arraySize(ty: Type) i64 {
    return c.cirArrayTypeGetSize(ty.raw);
}
pub fn arrayElementType(ty: Type) Type {
    return .{ .raw = c.cirArrayTypeGetElementType(ty.raw) };
}

// ===----------------------------------------------------------------------===
// Slice types
// ===----------------------------------------------------------------------===

pub fn sliceType(ctx: Context, element: Type) Type {
    return .{ .raw = c.cirSliceTypeGet(ctx.raw, element.raw) };
}
pub fn sliceElementType(ty: Type) Type {
    return .{ .raw = c.cirSliceTypeGetElementType(ty.raw) };
}

// ===----------------------------------------------------------------------===
// Optional types
// ===----------------------------------------------------------------------===

pub fn optionalType(ctx: Context, payload: Type) Type {
    return .{ .raw = c.cirOptionalTypeGet(ctx.raw, payload.raw) };
}
pub fn optionalPayloadType(ty: Type) Type {
    return .{ .raw = c.cirOptionalTypeGetPayload(ty.raw) };
}

// ===----------------------------------------------------------------------===
// Error union types
// ===----------------------------------------------------------------------===

pub fn errorUnionType(ctx: Context, payload: Type) Type {
    return .{ .raw = c.cirErrorUnionTypeGet(ctx.raw, payload.raw) };
}
pub fn errorUnionPayloadType(ty: Type) Type {
    return .{ .raw = c.cirErrorUnionTypeGetPayload(ty.raw) };
}

// ===----------------------------------------------------------------------===
// Enum types
// ===----------------------------------------------------------------------===

pub fn enumType(ctx: Context, name: [*:0]const u8, tag_type: Type, variants: []const [*:0]const u8) Type {
    return .{ .raw = c.cirEnumTypeGet(
        ctx.raw,
        name,
        tag_type.raw,
        @intCast(variants.len),
        @ptrCast(variants.ptr),
    ) };
}
pub fn enumName(ty: Type) []const u8 {
    const s = c.cirEnumTypeGetName(ty.raw);
    return s.data[0..s.length];
}
pub fn enumTagType(ty: Type) Type {
    return .{ .raw = c.cirEnumTypeGetTagType(ty.raw) };
}
pub fn enumVariantCount(ty: Type) usize {
    return @intCast(c.cirEnumTypeGetVariantCount(ty.raw));
}
pub fn enumVariantName(ty: Type, index: usize) []const u8 {
    const s = c.cirEnumTypeGetVariantName(ty.raw, @intCast(index));
    return s.data[0..s.length];
}

// ===----------------------------------------------------------------------===
// Tagged union types
// ===----------------------------------------------------------------------===

pub fn taggedUnionType(ctx: Context, name: [*:0]const u8, variant_names: []const [*:0]const u8, variant_types: []const Type) Type {
    return .{ .raw = c.cirTaggedUnionTypeGet(
        ctx.raw,
        name,
        @intCast(variant_names.len),
        @ptrCast(variant_names.ptr),
        @ptrCast(variant_types.ptr),
    ) };
}
pub fn taggedUnionName(ty: Type) []const u8 {
    const s = c.cirTaggedUnionTypeGetName(ty.raw);
    return s.data[0..s.length];
}
pub fn taggedUnionNumVariants(ty: Type) usize {
    return @intCast(c.cirTaggedUnionTypeGetNumVariants(ty.raw));
}
pub fn taggedUnionVariantName(ty: Type, index: usize) []const u8 {
    const s = c.cirTaggedUnionTypeGetVariantName(ty.raw, @intCast(index));
    return s.data[0..s.length];
}
pub fn taggedUnionVariantType(ty: Type, index: usize) Type {
    return .{ .raw = c.cirTaggedUnionTypeGetVariantType(ty.raw, @intCast(index)) };
}

// ===----------------------------------------------------------------------===
// Type inspectors
// ===----------------------------------------------------------------------===

pub fn isPtr(ty: Type) bool {
    return c.cirTypeIsPtr(ty.raw);
}
pub fn isRef(ty: Type) bool {
    return c.cirTypeIsRef(ty.raw);
}
pub fn isStruct(ty: Type) bool {
    return c.cirTypeIsStruct(ty.raw);
}
pub fn isArray(ty: Type) bool {
    return c.cirTypeIsArray(ty.raw);
}
pub fn isSlice(ty: Type) bool {
    return c.cirTypeIsSlice(ty.raw);
}
pub fn isOptional(ty: Type) bool {
    return c.cirTypeIsOptional(ty.raw);
}
pub fn isErrorUnion(ty: Type) bool {
    return c.cirTypeIsErrorUnion(ty.raw);
}
pub fn isEnum(ty: Type) bool {
    return c.cirTypeIsEnum(ty.raw);
}
pub fn isTaggedUnion(ty: Type) bool {
    return c.cirTypeIsTaggedUnion(ty.raw);
}

// ===----------------------------------------------------------------------===
// Generics types
// ===----------------------------------------------------------------------===

pub fn typeParamType(ctx: Context, name: [*:0]const u8) Type {
    return .{ .raw = c.cirTypeParamTypeGet(ctx.raw, name) };
}
pub fn isTypeParam(ty: Type) bool {
    return c.cirTypeIsTypeParam(ty.raw);
}

// ===----------------------------------------------------------------------===
// Type introspection — widths, element types, function type queries
// ===----------------------------------------------------------------------===

pub fn isInteger(ty: Type) bool {
    return c.mlirTypeIsAInteger(ty.raw);
}
pub fn isFloat(ty: Type) bool {
    return c.mlirTypeIsAFloat(ty.raw);
}
pub fn isFunction(ty: Type) bool {
    return c.mlirTypeIsAFunction(ty.raw);
}
pub fn integerWidth(ty: Type) u32 {
    return c.mlirIntegerTypeGetWidth(ty.raw);
}
pub fn floatWidth(ty: Type) u32 {
    return c.mlirFloatTypeGetWidth(ty.raw);
}
pub fn functionNumInputs(ty: Type) usize {
    return @intCast(c.mlirFunctionTypeGetNumInputs(ty.raw));
}
pub fn functionInput(ty: Type, index: usize) Type {
    return .{ .raw = c.mlirFunctionTypeGetInput(ty.raw, @intCast(index)) };
}
pub fn functionNumResults(ty: Type) usize {
    return @intCast(c.mlirFunctionTypeGetNumResults(ty.raw));
}
pub fn functionResult(ty: Type, index: usize) Type {
    return .{ .raw = c.mlirFunctionTypeGetResult(ty.raw, @intCast(index)) };
}
pub fn typeEqual(a: Type, b: Type) bool {
    return c.mlirTypeEqual(a.raw, b.raw);
}
