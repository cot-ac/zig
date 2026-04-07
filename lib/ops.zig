//! CIR op builders organized by construct namespace.

const c = @import("c.zig").cir;
const ir = @import("ir.zig");
const Block = ir.Block;
const Value = ir.Value;
const Type = ir.Type;
const Location = ir.Location;
const Operation = ir.Operation;

// ===----------------------------------------------------------------------===
// arith — constants, arithmetic, comparison, bitwise, casts
// ===----------------------------------------------------------------------===

pub const arith = struct {
    pub const constant = struct {
        pub fn int(block: Block, loc: Location, ty: Type, value: i64) Value {
            return .{ .raw = c.cirBuildConstantInt(block.raw, loc.raw, ty.raw, value) };
        }
        pub fn float(block: Block, loc: Location, ty: Type, value: f64) Value {
            return .{ .raw = c.cirBuildConstantFloat(block.raw, loc.raw, ty.raw, value) };
        }
        pub fn boolean(block: Block, loc: Location, value: bool) Value {
            return .{ .raw = c.cirBuildConstantBool(block.raw, loc.raw, value) };
        }
    };

    pub fn add(block: Block, loc: Location, lhs: Value, rhs: Value) Value {
        return .{ .raw = c.cirBuildAdd(block.raw, loc.raw, lhs.raw, rhs.raw) };
    }
    pub fn sub(block: Block, loc: Location, lhs: Value, rhs: Value) Value {
        return .{ .raw = c.cirBuildSub(block.raw, loc.raw, lhs.raw, rhs.raw) };
    }
    pub fn mul(block: Block, loc: Location, lhs: Value, rhs: Value) Value {
        return .{ .raw = c.cirBuildMul(block.raw, loc.raw, lhs.raw, rhs.raw) };
    }
    pub fn div(block: Block, loc: Location, lhs: Value, rhs: Value, signed: bool) Value {
        return .{ .raw = c.cirBuildDiv(block.raw, loc.raw, lhs.raw, rhs.raw, signed) };
    }
    pub fn rem(block: Block, loc: Location, lhs: Value, rhs: Value, signed: bool) Value {
        return .{ .raw = c.cirBuildRem(block.raw, loc.raw, lhs.raw, rhs.raw, signed) };
    }
    pub fn neg(block: Block, loc: Location, operand: Value) Value {
        return .{ .raw = c.cirBuildNeg(block.raw, loc.raw, operand.raw) };
    }
    pub fn cmp(block: Block, loc: Location, predicate: i64, lhs: Value, rhs: Value) Value {
        return .{ .raw = c.cirBuildCmp(block.raw, loc.raw, predicate, lhs.raw, rhs.raw) };
    }
    pub fn select(block: Block, loc: Location, cond: Value, true_val: Value, false_val: Value) Value {
        return .{ .raw = c.cirBuildSelect(block.raw, loc.raw, cond.raw, true_val.raw, false_val.raw) };
    }

    // Bitwise
    pub fn bitAnd(block: Block, loc: Location, lhs: Value, rhs: Value) Value {
        return .{ .raw = c.cirBuildBitAnd(block.raw, loc.raw, lhs.raw, rhs.raw) };
    }
    pub fn bitOr(block: Block, loc: Location, lhs: Value, rhs: Value) Value {
        return .{ .raw = c.cirBuildBitOr(block.raw, loc.raw, lhs.raw, rhs.raw) };
    }
    pub fn bitXor(block: Block, loc: Location, lhs: Value, rhs: Value) Value {
        return .{ .raw = c.cirBuildBitXor(block.raw, loc.raw, lhs.raw, rhs.raw) };
    }
    pub fn bitNot(block: Block, loc: Location, operand: Value) Value {
        return .{ .raw = c.cirBuildBitNot(block.raw, loc.raw, operand.raw) };
    }
    pub fn shl(block: Block, loc: Location, lhs: Value, rhs: Value) Value {
        return .{ .raw = c.cirBuildShl(block.raw, loc.raw, lhs.raw, rhs.raw) };
    }
    pub fn shr(block: Block, loc: Location, lhs: Value, rhs: Value, signed: bool) Value {
        return .{ .raw = c.cirBuildShr(block.raw, loc.raw, lhs.raw, rhs.raw, signed) };
    }

    // Casts
    pub fn extSI(block: Block, loc: Location, input: Value, result_type: Type) Value {
        return .{ .raw = c.cirBuildExtSI(block.raw, loc.raw, input.raw, result_type.raw) };
    }
    pub fn extUI(block: Block, loc: Location, input: Value, result_type: Type) Value {
        return .{ .raw = c.cirBuildExtUI(block.raw, loc.raw, input.raw, result_type.raw) };
    }
    pub fn truncI(block: Block, loc: Location, input: Value, result_type: Type) Value {
        return .{ .raw = c.cirBuildTruncI(block.raw, loc.raw, input.raw, result_type.raw) };
    }
    pub fn siToFP(block: Block, loc: Location, input: Value, result_type: Type) Value {
        return .{ .raw = c.cirBuildSIToFP(block.raw, loc.raw, input.raw, result_type.raw) };
    }
    pub fn fpToSI(block: Block, loc: Location, input: Value, result_type: Type) Value {
        return .{ .raw = c.cirBuildFPToSI(block.raw, loc.raw, input.raw, result_type.raw) };
    }
    pub fn extF(block: Block, loc: Location, input: Value, result_type: Type) Value {
        return .{ .raw = c.cirBuildExtF(block.raw, loc.raw, input.raw, result_type.raw) };
    }
    pub fn truncF(block: Block, loc: Location, input: Value, result_type: Type) Value {
        return .{ .raw = c.cirBuildTruncF(block.raw, loc.raw, input.raw, result_type.raw) };
    }
};

// ===----------------------------------------------------------------------===
// memory — alloca, store, load, addr_of, deref
// ===----------------------------------------------------------------------===

pub const memory = struct {
    pub fn alloca(block: Block, loc: Location, elem_type: Type) Value {
        return .{ .raw = c.cirBuildAlloca(block.raw, loc.raw, elem_type.raw) };
    }
    pub fn store(block: Block, loc: Location, value: Value, addr: Value) void {
        c.cirBuildStore(block.raw, loc.raw, value.raw, addr.raw);
    }
    pub fn load(block: Block, loc: Location, addr: Value, result_type: Type) Value {
        return .{ .raw = c.cirBuildLoad(block.raw, loc.raw, addr.raw, result_type.raw) };
    }
    pub fn addrOf(block: Block, loc: Location, addr: Value, ref_type: Type) Value {
        return .{ .raw = c.cirBuildAddrOf(block.raw, loc.raw, addr.raw, ref_type.raw) };
    }
    pub fn deref(block: Block, loc: Location, ref_val: Value, result_type: Type) Value {
        return .{ .raw = c.cirBuildDeref(block.raw, loc.raw, ref_val.raw, result_type.raw) };
    }
};

// ===----------------------------------------------------------------------===
// flow — br, condbr, trap
// ===----------------------------------------------------------------------===

pub const flow = struct {
    pub fn br(block: Block, loc: Location, dest: Block) void {
        c.cirBuildBr(block.raw, loc.raw, dest.raw);
    }
    pub fn condBr(block: Block, loc: Location, cond: Value, true_dest: Block, false_dest: Block) void {
        c.cirBuildCondBr(block.raw, loc.raw, cond.raw, true_dest.raw, false_dest.raw);
    }
    pub fn trap(block: Block, loc: Location) void {
        c.cirBuildTrap(block.raw, loc.raw);
    }
};

// ===----------------------------------------------------------------------===
// structs — struct_init, field_val, field_ptr
// ===----------------------------------------------------------------------===

pub const structs = struct {
    pub fn init(block: Block, loc: Location, struct_type: Type, fields: []const Value) Value {
        return .{ .raw = c.cirBuildStructInit(
            block.raw, loc.raw, struct_type.raw,
            @intCast(fields.len), @ptrCast(fields.ptr),
        ) };
    }
    pub fn fieldVal(block: Block, loc: Location, result_type: Type, input: Value, index: i64) Value {
        return .{ .raw = c.cirBuildFieldVal(block.raw, loc.raw, result_type.raw, input.raw, index) };
    }
    pub fn fieldPtr(block: Block, loc: Location, result_type: Type, base: Value, index: i64, struct_type: Type) Value {
        return .{ .raw = c.cirBuildFieldPtr(block.raw, loc.raw, result_type.raw, base.raw, index, struct_type.raw) };
    }
};

// ===----------------------------------------------------------------------===
// arrays — array_init, elem_val, elem_ptr
// ===----------------------------------------------------------------------===

pub const arrays = struct {
    pub fn init(block: Block, loc: Location, array_type: Type, elements: []const Value) Value {
        return .{ .raw = c.cirBuildArrayInit(
            block.raw, loc.raw, array_type.raw,
            @intCast(elements.len), @ptrCast(elements.ptr),
        ) };
    }
    pub fn elemVal(block: Block, loc: Location, result_type: Type, input: Value, index: i64) Value {
        return .{ .raw = c.cirBuildElemVal(block.raw, loc.raw, result_type.raw, input.raw, index) };
    }
    pub fn elemPtr(block: Block, loc: Location, result_type: Type, base: Value, index: Value, array_type: Type) Value {
        return .{ .raw = c.cirBuildElemPtr(block.raw, loc.raw, result_type.raw, base.raw, index.raw, array_type.raw) };
    }
};

// ===----------------------------------------------------------------------===
// slices — string_constant, slice_ptr, slice_len, slice_elem, array_to_slice
// ===----------------------------------------------------------------------===

pub const slices = struct {
    pub fn stringConstant(block: Block, loc: Location, slice_type: Type, value: [*:0]const u8) Value {
        return .{ .raw = c.cirBuildStringConstant(block.raw, loc.raw, slice_type.raw, value) };
    }
    pub fn ptr(block: Block, loc: Location, result_type: Type, input: Value) Value {
        return .{ .raw = c.cirBuildSlicePtr(block.raw, loc.raw, result_type.raw, input.raw) };
    }
    pub fn len(block: Block, loc: Location, input: Value) Value {
        return .{ .raw = c.cirBuildSliceLen(block.raw, loc.raw, input.raw) };
    }
    pub fn elem(block: Block, loc: Location, result_type: Type, input: Value, index: Value) Value {
        return .{ .raw = c.cirBuildSliceElem(block.raw, loc.raw, result_type.raw, input.raw, index.raw) };
    }
    pub fn arrayToSlice(block: Block, loc: Location, slice_type: Type, base: Value, start: Value, end: Value) Value {
        return .{ .raw = c.cirBuildArrayToSlice(block.raw, loc.raw, slice_type.raw, base.raw, start.raw, end.raw) };
    }
};

// ===----------------------------------------------------------------------===
// optionals — none, wrap, is_non_null, payload
// ===----------------------------------------------------------------------===

pub const optionals = struct {
    pub fn none(block: Block, loc: Location, optional_type: Type) Value {
        return .{ .raw = c.cirBuildNone(block.raw, loc.raw, optional_type.raw) };
    }
    pub fn wrap(block: Block, loc: Location, optional_type: Type, input: Value) Value {
        return .{ .raw = c.cirBuildWrapOptional(block.raw, loc.raw, optional_type.raw, input.raw) };
    }
    pub fn isNonNull(block: Block, loc: Location, input: Value) Value {
        return .{ .raw = c.cirBuildIsNonNull(block.raw, loc.raw, input.raw) };
    }
    pub fn payload(block: Block, loc: Location, result_type: Type, input: Value) Value {
        return .{ .raw = c.cirBuildOptionalPayload(block.raw, loc.raw, result_type.raw, input.raw) };
    }
};

// ===----------------------------------------------------------------------===
// errors — wrap_result, wrap_error, is_error, error_payload, error_code
// ===----------------------------------------------------------------------===

pub const errors = struct {
    pub fn wrapResult(block: Block, loc: Location, eu_type: Type, input: Value) Value {
        return .{ .raw = c.cirBuildWrapResult(block.raw, loc.raw, eu_type.raw, input.raw) };
    }
    pub fn wrapError(block: Block, loc: Location, eu_type: Type, err_code: Value) Value {
        return .{ .raw = c.cirBuildWrapError(block.raw, loc.raw, eu_type.raw, err_code.raw) };
    }
    pub fn isError(block: Block, loc: Location, input: Value) Value {
        return .{ .raw = c.cirBuildIsError(block.raw, loc.raw, input.raw) };
    }
    pub fn payload(block: Block, loc: Location, result_type: Type, input: Value) Value {
        return .{ .raw = c.cirBuildErrorPayload(block.raw, loc.raw, result_type.raw, input.raw) };
    }
    pub fn code(block: Block, loc: Location, input: Value) Value {
        return .{ .raw = c.cirBuildErrorCode(block.raw, loc.raw, input.raw) };
    }
};

// ===----------------------------------------------------------------------===
// enums — enum_constant, enum_value
// ===----------------------------------------------------------------------===

pub const enums = struct {
    pub fn constant(block: Block, loc: Location, enum_type: Type, variant: [*:0]const u8) Value {
        return .{ .raw = c.cirBuildEnumConstant(block.raw, loc.raw, enum_type.raw, variant) };
    }
    pub fn value(block: Block, loc: Location, result_type: Type, input: Value) Value {
        return .{ .raw = c.cirBuildEnumValue(block.raw, loc.raw, result_type.raw, input.raw) };
    }
};

// ===----------------------------------------------------------------------===
// unions — union_init, union_tag, union_payload
// ===----------------------------------------------------------------------===

pub const unions = struct {
    pub fn init(block: Block, loc: Location, union_type: Type, variant: [*:0]const u8, payload_val: ?Value) Value {
        const raw_payload: c.MlirValue = if (payload_val) |p| p.raw else .{ .ptr = null };
        return .{ .raw = c.cirBuildUnionInit(block.raw, loc.raw, union_type.raw, variant, raw_payload) };
    }
    pub fn tag(block: Block, loc: Location, input: Value) Value {
        return .{ .raw = c.cirBuildUnionTag(block.raw, loc.raw, input.raw) };
    }
    pub fn payload(block: Block, loc: Location, result_type: Type, variant: [*:0]const u8, input: Value) Value {
        return .{ .raw = c.cirBuildUnionPayload(block.raw, loc.raw, result_type.raw, variant, input.raw) };
    }
};

// ===----------------------------------------------------------------------===
// testing — assert, test_case
// ===----------------------------------------------------------------------===

pub const testing = struct {
    pub fn assert(block: Block, loc: Location, condition: Value, message: [*:0]const u8) void {
        c.cirBuildAssert(block.raw, loc.raw, condition.raw, message);
    }
    pub fn testCase(block: Block, loc: Location, name: [*:0]const u8) Operation {
        return .{ .raw = c.cirBuildTestCase(block.raw, loc.raw, name) };
    }
};
