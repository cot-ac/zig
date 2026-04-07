//! Zig Codegen — emit CIR from AST via @import("cot").
//!
//! Walks the parser's AST and emits CIR ops using the cot binding.
//! Each language feature maps to one or more CIR construct ops.

const std = @import("std");
const cot = @import("cot");
const parser = @import("parser");
const scanner = @import("scanner");
const TokenKind = scanner.TokenKind;

const c = cot.c.cir;

const Context = cot.Context;
const Module = cot.Module;
const Block = cot.Block;
const Value = cot.Value;
const Type = cot.Type;
const Location = cot.Location;

const VarInfo = struct {
    addr: Value, // alloca pointer
    ty: Type, // stored type
};

pub const Codegen = struct {
    ctx: Context,
    loc: Location,
    module: Module,
    module_body: Block,
    alloc: std.mem.Allocator,

    // Per-function state
    current_block: Block = undefined,
    current_func_region: cot.ir.Region = undefined,
    return_type: Type = undefined,
    vars: std.StringHashMap(VarInfo) = undefined,
    // Break/continue targets
    break_dest: ?Block = null,
    continue_dest: ?Block = null,
    block_terminated: bool = false,

    // Type cache
    ty_void: Type = undefined,
    ty_i8: Type = undefined,
    ty_i16: Type = undefined,
    ty_i32: Type = undefined,
    ty_i64: Type = undefined,
    ty_f32: Type = undefined,
    ty_f64: Type = undefined,
    ty_bool: Type = undefined,
    ty_ptr: Type = undefined,

    // Struct/enum type maps
    struct_types: std.StringHashMap(Type) = undefined,
    struct_defs: std.StringHashMap(parser.StructDef) = undefined,
    enum_types: std.StringHashMap(Type) = undefined,
    enum_defs: std.StringHashMap(parser.EnumDef) = undefined,

    pub fn init(alloc: std.mem.Allocator, filename: [*:0]const u8) Codegen {
        const ctx = Context.create();
        const loc = Location.fileLineCol(ctx, filename, 1, 1);
        const module = Module.createEmpty(loc);
        var gen = Codegen{
            .ctx = ctx,
            .loc = loc,
            .module = module,
            .module_body = module.body(),
            .alloc = alloc,
        };
        gen.ty_void = cot.types.functionType(ctx, &.{}, &.{}); // placeholder
        gen.ty_i8 = cot.types.i8Type(ctx);
        gen.ty_i16 = cot.types.i16Type(ctx);
        gen.ty_i32 = cot.types.i32Type(ctx);
        gen.ty_i64 = cot.types.i64Type(ctx);
        gen.ty_f32 = cot.types.f32Type(ctx);
        gen.ty_f64 = cot.types.f64Type(ctx);
        gen.ty_bool = cot.types.i1Type(ctx);
        gen.ty_ptr = cot.types.ptrType(ctx);
        gen.struct_types = std.StringHashMap(Type).init(alloc);
        gen.struct_defs = std.StringHashMap(parser.StructDef).init(alloc);
        gen.enum_types = std.StringHashMap(Type).init(alloc);
        gen.enum_defs = std.StringHashMap(parser.EnumDef).init(alloc);
        return gen;
    }

    pub fn deinit(self: *Codegen) void {
        self.module.destroy();
        self.ctx.destroy();
    }

    pub fn emit(self: *Codegen, mod: *const parser.Module) CodegenError!void {
        // Register struct and enum types first
        for (mod.structs.items) |sd| {
            try self.registerStruct(sd);
        }
        for (mod.enums.items) |ed| {
            try self.registerEnum(ed);
        }
        // Emit functions
        for (mod.functions.items) |fd| {
            try self.emitFunction(fd);
        }
        // Emit test blocks
        for (mod.tests.items) |td| {
            try self.emitTestBlock(td);
        }
    }

    // ===----------------------------------------------------------------------===
    // Type registration
    // ===----------------------------------------------------------------------===

    fn registerStruct(self: *Codegen, sd: parser.StructDef) CodegenError!void {
        var field_names: [32][*:0]const u8 = undefined;
        var field_types: [32]Type = undefined;
        for (sd.fields.items, 0..) |f, i| {
            field_names[i] = self.zstr(f.name);
            field_types[i] = self.resolveType(f.type_ref);
        }
        const n = sd.fields.items.len;
        const ty = cot.types.structType(
            self.ctx,
            self.zstr(sd.name),
            field_names[0..n],
            field_types[0..n],
        );
        try self.struct_types.put(sd.name, ty);
        try self.struct_defs.put(sd.name, sd);
    }

    fn registerEnum(self: *Codegen, ed: parser.EnumDef) CodegenError!void {
        var variant_names: [64][*:0]const u8 = undefined;
        for (ed.variants.items, 0..) |v, i| {
            variant_names[i] = self.zstr(v);
        }
        const n = ed.variants.items.len;
        const ty = cot.types.enumType(
            self.ctx,
            self.zstr(ed.name),
            self.ty_i32,
            variant_names[0..n],
        );
        try self.enum_types.put(ed.name, ty);
        try self.enum_defs.put(ed.name, ed);
    }

    // ===----------------------------------------------------------------------===
    // Functions
    // ===----------------------------------------------------------------------===

    fn emitFunction(self: *Codegen, fd: parser.FnDecl) CodegenError!void {
        const ret_type = self.resolveType(fd.return_type);
        self.return_type = ret_type;

        // Build parameter types
        var param_types: [32]Type = undefined;
        for (fd.params.items, 0..) |p, i| {
            param_types[i] = self.resolveType(p.type_ref);
        }
        const n = fd.params.items.len;

        const is_void_ret = std.mem.eql(u8, fd.return_type.name, "void");
        const result_types: []const Type = if (is_void_ret) &.{} else &.{ret_type};
        const func_type = cot.types.functionType(self.ctx, param_types[0..n], result_types);

        // Create entry block with function params
        var param_locs: [32]Location = undefined;
        for (0..n) |i| param_locs[i] = self.loc;
        const entry_block = Block.create(
            n,
            if (n > 0) @ptrCast(&param_types) else null,
            if (n > 0) @ptrCast(&param_locs) else null,
        );

        const body_region = cot.ir.Region.create();
        body_region.appendOwnedBlock(entry_block);

        var func_state = cot.ir.OperationState.get("func.func", self.loc);
        func_state.addAttribute(self.ctx, "sym_name", cot.ir.Attribute.string(self.ctx, self.zstr(fd.name)));
        func_state.addAttribute(self.ctx, "function_type", cot.ir.Attribute.typeAttr(func_type));
        func_state.addOwnedRegions(&.{body_region});
        const func_op = func_state.create();
        self.module_body.appendOwnedOperation(func_op);

        // Set up variable scope — get the region back from the created op
        self.current_block = entry_block;
        self.block_terminated = false;
        const created_func = cot.ir.Operation{ .raw = func_op.raw };
        self.current_func_region = created_func.getRegion(0);
        self.vars = std.StringHashMap(VarInfo).init(self.alloc);

        // Bind parameters
        for (fd.params.items, 0..) |p, i| {
            const arg = Value{ .raw = c.mlirBlockGetArgument(entry_block.raw, @intCast(i)) };
            // Alloca + store for mutable access
            const addr = cot.memory.alloca(self.current_block, self.loc, param_types[i]);
            cot.memory.store(self.current_block, self.loc, arg, addr);
            try self.vars.put(p.name, .{ .addr = addr, .ty = param_types[i] });
        }

        // Emit body
        for (fd.body.items) |stmt| {
            try self.emitStmt(stmt);
        }

        // If no explicit return in void function, add one
        if (is_void_ret and !self.block_terminated) {
            var ret_state = cot.ir.OperationState.get("func.return", self.loc);
            self.current_block.appendOwnedOperation(ret_state.create());
        }
    }

    fn emitTestBlock(self: *Codegen, td: parser.TestDecl) CodegenError!void {
        // Emit test as a standalone test_case op
        _ = cot.testing.testCase(self.module_body, self.loc, @ptrCast(td.name.ptr));
        // TODO: populate test_case body region with td.body statements
    }

    // ===----------------------------------------------------------------------===
    // Statements
    // ===----------------------------------------------------------------------===

    fn emitStmt(self: *Codegen, stmt: *const parser.Stmt) CodegenError!void {
        if (self.block_terminated) return; // block already has a terminator
        switch (stmt.kind) {
            .ret => {
                try self.emitReturn(stmt);
                self.block_terminated = true;
            },
            .expr_stmt => {
                if (stmt.expr) |e| _ = try self.emitExpr(e);
            },
            .let_decl, .var_decl => try self.emitVarDecl(stmt),
            .if_stmt => try self.emitIf(stmt),
            .while_stmt => try self.emitWhile(stmt),
            .for_stmt => try self.emitFor(stmt),
            .break_stmt => {
                if (self.break_dest) |dest| cot.flow.br(self.current_block, self.loc, dest);
                self.block_terminated = true;
            },
            .continue_stmt => {
                if (self.continue_dest) |dest| cot.flow.br(self.current_block, self.loc, dest);
                self.block_terminated = true;
            },
            .assign => try self.emitAssign(stmt),
            .compound_assign => try self.emitCompoundAssign(stmt),
            .switch_stmt => try self.emitSwitch(stmt),
        }
    }

    fn emitReturn(self: *Codegen, stmt: *const parser.Stmt) CodegenError!void {
        var ret_state = cot.ir.OperationState.get("func.return", self.loc);
        if (stmt.expr) |e| {
            const val = try self.emitExpr(e);
            ret_state.addOperands(&.{val});
        }
        self.current_block.appendOwnedOperation(ret_state.create());
    }

    fn emitVarDecl(self: *Codegen, stmt: *const parser.Stmt) CodegenError!void {
        const init_val = try self.emitExpr(stmt.expr.?);
        const val_type = init_val.getType();
        const addr = cot.memory.alloca(self.current_block, self.loc, val_type);
        cot.memory.store(self.current_block, self.loc, init_val, addr);
        try self.vars.put(stmt.var_name, .{ .addr = addr, .ty = val_type });
    }

    fn emitIf(self: *Codegen, stmt: *const parser.Stmt) CodegenError!void {
        const cond = try self.emitExpr(stmt.expr.?);
        const then_block = Block.create(0, null, null);
        const else_block = Block.create(0, null, null);
        const merge_block = Block.create(0, null, null);

        cot.flow.condBr(self.current_block, self.loc, cond, then_block, else_block);

        // Then branch
        self.current_block = then_block;
        self.block_terminated = false;
        self.appendBlockToFunc(then_block);
        if (stmt.has_then) {
            for (stmt.then_body.items) |s| try self.emitStmt(s);
        }
        if (!self.block_terminated)
            cot.flow.br(self.current_block, self.loc, merge_block);

        // Else branch
        self.current_block = else_block;
        self.block_terminated = false;
        self.appendBlockToFunc(else_block);
        if (stmt.has_else) {
            for (stmt.else_body.items) |s| try self.emitStmt(s);
        }
        if (!self.block_terminated)
            cot.flow.br(self.current_block, self.loc, merge_block);

        self.current_block = merge_block;
        self.block_terminated = false;
        self.appendBlockToFunc(merge_block);
    }

    fn emitWhile(self: *Codegen, stmt: *const parser.Stmt) CodegenError!void {
        const cond_block = Block.create(0, null, null);
        const body_block = Block.create(0, null, null);
        const exit_block = Block.create(0, null, null);

        cot.flow.br(self.current_block, self.loc, cond_block);

        // Condition
        self.current_block = cond_block;
        self.appendBlockToFunc(cond_block);
        const cond = try self.emitExpr(stmt.expr.?);
        cot.flow.condBr(self.current_block, self.loc, cond, body_block, exit_block);

        // Body
        const saved_break = self.break_dest;
        const saved_continue = self.continue_dest;
        self.break_dest = exit_block;
        self.continue_dest = cond_block;
        self.current_block = body_block;
        self.block_terminated = false;
        self.appendBlockToFunc(body_block);
        if (stmt.has_then) {
            for (stmt.then_body.items) |s| try self.emitStmt(s);
        }
        if (!self.block_terminated)
            cot.flow.br(self.current_block, self.loc, cond_block);
        self.break_dest = saved_break;
        self.continue_dest = saved_continue;

        self.current_block = exit_block;
        self.block_terminated = false;
        self.appendBlockToFunc(exit_block);
    }

    fn emitFor(self: *Codegen, stmt: *const parser.Stmt) CodegenError!void {
        // for (lo..hi) |i| { body }
        // → var i = lo; while (i < hi) { body; i += 1; }
        const lo = try self.emitExpr(stmt.expr.?);
        const hi = if (stmt.range_end) |re| try self.emitExpr(re) else lo;

        const addr = cot.memory.alloca(self.current_block, self.loc, lo.getType());
        cot.memory.store(self.current_block, self.loc, lo, addr);
        if (stmt.var_name.len > 0) {
            try self.vars.put(stmt.var_name, .{ .addr = addr, .ty = lo.getType() });
        }

        const cond_block = Block.create(0, null, null);
        const body_block = Block.create(0, null, null);
        const exit_block = Block.create(0, null, null);

        cot.flow.br(self.current_block, self.loc, cond_block);

        // Condition: i < hi
        self.current_block = cond_block;
        self.appendBlockToFunc(cond_block);
        const i_val = cot.memory.load(self.current_block, self.loc, addr, lo.getType());
        const cond = cot.arith.cmp(self.current_block, self.loc, 2, i_val, hi); // 2 = slt
        cot.flow.condBr(self.current_block, self.loc, cond, body_block, exit_block);

        // Body
        const saved_break = self.break_dest;
        const saved_continue = self.continue_dest;
        self.break_dest = exit_block;
        self.continue_dest = cond_block;
        self.current_block = body_block;
        self.block_terminated = false;
        self.appendBlockToFunc(body_block);
        if (stmt.has_then) {
            for (stmt.then_body.items) |s| try self.emitStmt(s);
        }
        if (!self.block_terminated) {
            // Increment: i += 1
            const cur = cot.memory.load(self.current_block, self.loc, addr, lo.getType());
            const one = cot.arith.constant.int(self.current_block, self.loc, lo.getType(), 1);
            const next = cot.arith.add(self.current_block, self.loc, cur, one);
            cot.memory.store(self.current_block, self.loc, next, addr);
            cot.flow.br(self.current_block, self.loc, cond_block);
        }

        self.break_dest = saved_break;
        self.continue_dest = saved_continue;
        self.current_block = exit_block;
        self.block_terminated = false;
        self.appendBlockToFunc(exit_block);
    }

    fn emitAssign(self: *Codegen, stmt: *const parser.Stmt) CodegenError!void {
        const target = stmt.lhs_expr orelse return;
        const val = try self.emitExpr(stmt.expr.?);

        if (target.kind == .ident) {
            if (self.vars.get(target.name)) |info| {
                cot.memory.store(self.current_block, self.loc, val, info.addr);
            }
        } else if (target.kind == .deref) {
            // p.* = val → store to the pointer held in the variable
            const ptr_val = try self.emitExpr(target.lhs.?);
            cot.memory.store(self.current_block, self.loc, val, ptr_val);
        }
    }

    fn emitCompoundAssign(self: *Codegen, stmt: *const parser.Stmt) CodegenError!void {
        const target = stmt.lhs_expr orelse return;
        const rhs = try self.emitExpr(stmt.expr.?);

        if (target.kind == .ident) {
            if (self.vars.get(target.name)) |info| {
                const cur = cot.memory.load(self.current_block, self.loc, info.addr, info.ty);
                const result = switch (stmt.op) {
                    .plus_equal => cot.arith.add(self.current_block, self.loc, cur, rhs),
                    .minus_equal => cot.arith.sub(self.current_block, self.loc, cur, rhs),
                    .star_equal => cot.arith.mul(self.current_block, self.loc, cur, rhs),
                    .slash_equal => cot.arith.div(self.current_block, self.loc, cur, rhs, true),
                    else => cur,
                };
                cot.memory.store(self.current_block, self.loc, result, info.addr);
            }
        }
    }

    fn emitSwitch(_: *Codegen, _: *const parser.Stmt) CodegenError!void {
        // TODO: switch lowering via cir.switch or chained condbr
    }

    // ===----------------------------------------------------------------------===
    // Expressions
    // ===----------------------------------------------------------------------===

    pub const CodegenError = error{OutOfMemory};

    /// Convert a slice to a null-terminated string for C API calls.
    fn zstr(self: *Codegen, s: []const u8) [*:0]const u8 {
        return self.alloc.dupeZ(u8, s) catch "";
    }

    fn emitExpr(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        return switch (expr.kind) {
            .int_lit => cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, expr.int_val),
            .float_lit => cot.arith.constant.float(self.current_block, self.loc, self.ty_f64, expr.float_val),
            .bool_lit => cot.arith.constant.boolean(self.current_block, self.loc, expr.bool_val),
            .string_lit => self.emitStringLit(expr),
            .null_lit => self.emitNullLit(),
            .ident => self.emitIdent(expr),
            .bin_op => self.emitBinOp(expr),
            .unary_op => self.emitUnaryOp(expr),
            .call => self.emitCall(expr),
            .field_access => self.emitFieldAccess(expr),
            .index => self.emitIndex(expr),
            .struct_lit => self.emitStructLit(expr),
            .array_lit => self.emitArrayLit(expr),
            .addr_of => self.emitAddrOf(expr),
            .deref => self.emitDeref(expr),
            .force_unwrap => self.emitForceUnwrap(expr),
            .try_unwrap => self.emitTryUnwrap(expr),
            .cast_as => self.emitCastAs(expr),
            .slice_from => self.emitSliceFrom(expr),
            .dot_ident => self.emitDotIdent(expr),
        };
    }

    fn emitStringLit(self: *Codegen, expr: *const parser.Expr) Value {
        const slice_ty = cot.types.sliceType(self.ctx, self.ty_i8);
        return cot.slices.stringConstant(self.current_block, self.loc, slice_ty, self.zstr(expr.str_val));
    }

    fn emitNullLit(self: *Codegen) Value {
        // null → cir.none with inferred optional type (use i32 as default payload)
        const opt_ty = cot.types.optionalType(self.ctx, self.ty_i32);
        return cot.optionals.none(self.current_block, self.loc, opt_ty);
    }

    fn emitIdent(self: *Codegen, expr: *const parser.Expr) Value {
        if (self.vars.get(expr.name)) |info| {
            return cot.memory.load(self.current_block, self.loc, info.addr, info.ty);
        }
        return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
    }

    fn emitBinOp(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        const lhs = try self.emitExpr(expr.lhs.?);
        const rhs = try self.emitExpr(expr.rhs.?);

        return switch (expr.op) {
            .plus => cot.arith.add(self.current_block, self.loc, lhs, rhs),
            .minus => cot.arith.sub(self.current_block, self.loc, lhs, rhs),
            .star => cot.arith.mul(self.current_block, self.loc, lhs, rhs),
            .slash => cot.arith.div(self.current_block, self.loc, lhs, rhs, true),
            .percent => cot.arith.rem(self.current_block, self.loc, lhs, rhs, true),
            .ampersand => cot.arith.bitAnd(self.current_block, self.loc, lhs, rhs),
            .pipe => cot.arith.bitOr(self.current_block, self.loc, lhs, rhs),
            .caret => cot.arith.bitXor(self.current_block, self.loc, lhs, rhs),
            .shl => cot.arith.shl(self.current_block, self.loc, lhs, rhs),
            .shr => cot.arith.shr(self.current_block, self.loc, lhs, rhs, true),
            .equal_equal => cot.arith.cmp(self.current_block, self.loc, 0, lhs, rhs), // eq
            .bang_equal => cot.arith.cmp(self.current_block, self.loc, 1, lhs, rhs),  // ne
            .less => cot.arith.cmp(self.current_block, self.loc, 2, lhs, rhs),         // slt
            .less_equal => cot.arith.cmp(self.current_block, self.loc, 3, lhs, rhs),   // sle
            .greater => cot.arith.cmp(self.current_block, self.loc, 4, lhs, rhs),      // sgt
            .greater_equal => cot.arith.cmp(self.current_block, self.loc, 5, lhs, rhs), // sge
            .kw_orelse => lhs, // TODO: proper orelse lowering
            .kw_catch => lhs,  // TODO: proper catch lowering
            else => cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0),
        };
    }

    fn emitUnaryOp(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        const operand = try self.emitExpr(expr.lhs.?);
        return switch (expr.op) {
            .minus => cot.arith.neg(self.current_block, self.loc, operand),
            .tilde => cot.arith.bitNot(self.current_block, self.loc, operand),
            .bang => operand, // TODO: logical not
            else => operand,
        };
    }

    fn emitCall(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        // Special builtins
        if (std.mem.eql(u8, expr.name, "assert") or std.mem.eql(u8, expr.name, "@assert")) {
            if (expr.has_args and expr.args.items.len > 0) {
                const cond = try self.emitExpr(expr.args.items[0]);
                cot.testing.assert(self.current_block, self.loc, cond, "assertion failed");
            }
            return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
        }

        // Build argument values
        var arg_vals: [32]Value = undefined;
        var n: usize = 0;
        if (expr.has_args) {
            for (expr.args.items) |arg| {
                arg_vals[n] = try self.emitExpr(arg);
                n += 1;
            }
        }

        // Look up callee return type from the function's symbol
        var ret_type = self.ty_i32;
        var is_void = false;
        const name_ref = c.MlirStringRef{ .data = expr.name.ptr, .length = expr.name.len };
        const sym_table = c.mlirSymbolTableCreate(self.module.getOperation().raw);
        defer c.mlirSymbolTableDestroy(sym_table);
        const callee_op = c.mlirSymbolTableLookup(sym_table, name_ref);
        if (!c.mlirOperationIsNull(callee_op)) {
            const ft_attr = c.mlirOperationGetAttributeByName(
                callee_op,
                c.mlirStringRefCreateFromCString("function_type"),
            );
            if (!c.mlirAttributeIsNull(ft_attr)) {
                const fty = c.mlirTypeAttrGetValue(ft_attr);
                if (c.mlirFunctionTypeGetNumResults(fty) == 0) {
                    is_void = true;
                } else {
                    ret_type = .{ .raw = c.mlirFunctionTypeGetResult(fty, 0) };
                }
            }
        }

        var state = cot.ir.OperationState.get("func.call", self.loc);
        state.addOperands(arg_vals[0..n]);
        if (!is_void) state.addResults(&.{ret_type});
        state.addAttribute(self.ctx, "callee", cot.ir.Attribute{
            .raw = c.mlirFlatSymbolRefAttrGet(self.ctx.raw, c.mlirStringRefCreateFromCString(self.zstr(expr.name))),
        });
        const op = state.create();
        self.current_block.appendOwnedOperation(op);

        if (is_void) {
            return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
        }
        return Value{ .raw = c.mlirOperationGetResult(op.raw, 0) };
    }

    fn emitFieldAccess(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        const base = try self.emitExpr(expr.lhs.?);
        const base_ty = base.getType();
        // Look up field index by name in the struct def
        if (cot.types.isStruct(base_ty)) {
            const num_fields = cot.types.structNumFields(base_ty);
            var idx: usize = 0;
            while (idx < num_fields) : (idx += 1) {
                const fname = cot.types.structFieldName(base_ty, idx);
                if (std.mem.eql(u8, fname, expr.name)) {
                    const field_ty = cot.types.structFieldType(base_ty, idx);
                    return cot.structs.fieldVal(self.current_block, self.loc, field_ty, base, @intCast(idx));
                }
            }
        }
        return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
    }

    fn emitIndex(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        _ = expr;
        // TODO: cir.elem_val / cir.slice_elem
        return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
    }

    fn emitStructLit(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        const sty = self.struct_types.get(expr.name) orelse
            return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
        const sd = self.struct_defs.get(expr.name) orelse
            return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);

        // Build field values in struct declaration order
        var field_vals: [32]Value = undefined;
        const num_fields = sd.fields.items.len;
        for (sd.fields.items, 0..) |field, fi| {
            // Find matching field init by name
            var found = false;
            if (expr.has_fields) {
                for (expr.fields.items) |finit| {
                    if (std.mem.eql(u8, finit.name, field.name)) {
                        field_vals[fi] = self.emitExpr(finit.value) catch
                            cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
                        found = true;
                        break;
                    }
                }
            }
            if (!found) {
                // Default to zero
                field_vals[fi] = cot.arith.constant.int(self.current_block, self.loc,
                    self.resolveType(field.type_ref), 0);
            }
        }
        return cot.structs.init(self.current_block, self.loc, sty, field_vals[0..num_fields]);
    }

    fn emitArrayLit(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        _ = expr;
        // TODO: cir.array_init
        return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
    }

    fn emitAddrOf(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        // &x → address of variable (the alloca IS the address)
        const inner = expr.lhs.?;
        if (inner.kind == .ident) {
            if (self.vars.get(inner.name)) |info| {
                return info.addr;
            }
        }
        return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
    }

    fn emitDeref(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        // p.* → load the pointer, then load through it
        const inner = expr.lhs.?;
        if (inner.kind == .ident) {
            if (self.vars.get(inner.name)) |info| {
                // Load the pointer value from the alloca
                const ptr_val = cot.memory.load(self.current_block, self.loc, info.addr, info.ty);
                // Load through the pointer — need to know the pointee type
                // For now assume i32 (TODO: proper pointee type tracking)
                return cot.memory.load(self.current_block, self.loc, ptr_val, self.ty_i32);
            }
        }
        const ptr_val = try self.emitExpr(inner);
        return cot.memory.load(self.current_block, self.loc, ptr_val, self.ty_i32);
    }

    fn emitForceUnwrap(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        const opt_val = try self.emitExpr(expr.lhs.?);
        // .? → optional_payload
        return cot.optionals.payload(self.current_block, self.loc, self.ty_i32, opt_val);
    }

    fn emitTryUnwrap(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        const eu_val = try self.emitExpr(expr.lhs.?);
        // try → error_payload (simplified — real try needs error propagation)
        return cot.errors.payload(self.current_block, self.loc, self.ty_i32, eu_val);
    }

    fn emitCastAs(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        const input = try self.emitExpr(expr.lhs.?);
        // @intCast — use function return type as target
        const target = if (std.mem.eql(u8, expr.cast_type.name, "__intcast"))
            self.return_type
        else
            self.resolveType(expr.cast_type);
        const src_ty = input.getType();
        if (cot.types.isInteger(src_ty) and cot.types.isInteger(target)) {
            if (cot.types.integerWidth(src_ty) < cot.types.integerWidth(target))
                return cot.arith.extSI(self.current_block, self.loc, input, target);
            if (cot.types.integerWidth(src_ty) > cot.types.integerWidth(target))
                return cot.arith.truncI(self.current_block, self.loc, input, target);
        }
        if (cot.types.isInteger(src_ty) and cot.types.isFloat(target))
            return cot.arith.siToFP(self.current_block, self.loc, input, target);
        if (cot.types.isFloat(src_ty) and cot.types.isInteger(target))
            return cot.arith.fpToSI(self.current_block, self.loc, input, target);
        return input;
    }

    fn emitSliceFrom(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        _ = expr;
        // TODO: cir.array_to_slice
        return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
    }

    fn emitDotIdent(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        _ = expr;
        // .Variant → enum constant (needs context to determine which enum)
        return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
    }

    // ===----------------------------------------------------------------------===
    // Helpers
    // ===----------------------------------------------------------------------===

    fn resolveType(self: *Codegen, ty: parser.TypeRef) Type {
        if (ty.is_optional) {
            var inner = ty;
            inner.is_optional = false;
            return cot.types.optionalType(self.ctx, self.resolveType(inner));
        }
        if (ty.is_error_union) {
            var inner = ty;
            inner.is_error_union = false;
            return cot.types.errorUnionType(self.ctx, self.resolveType(inner));
        }
        if (ty.is_pointer) {
            return self.ty_ptr;
        }
        if (ty.is_array) {
            var inner = ty;
            inner.is_array = false;
            inner.array_len = 0;
            return cot.types.arrayType(self.ctx, ty.array_len, self.resolveType(inner));
        }
        if (ty.is_slice) {
            var inner = ty;
            inner.is_slice = false;
            return cot.types.sliceType(self.ctx, self.resolveType(inner));
        }

        if (std.mem.eql(u8, ty.name, "i8")) return self.ty_i8;
        if (std.mem.eql(u8, ty.name, "i16")) return self.ty_i16;
        if (std.mem.eql(u8, ty.name, "i32")) return self.ty_i32;
        if (std.mem.eql(u8, ty.name, "i64")) return self.ty_i64;
        if (std.mem.eql(u8, ty.name, "u8")) return self.ty_i8;  // treat as i8 for now
        if (std.mem.eql(u8, ty.name, "u16")) return self.ty_i16;
        if (std.mem.eql(u8, ty.name, "u32")) return self.ty_i32;
        if (std.mem.eql(u8, ty.name, "u64")) return self.ty_i64;
        if (std.mem.eql(u8, ty.name, "f32")) return self.ty_f32;
        if (std.mem.eql(u8, ty.name, "f64")) return self.ty_f64;
        if (std.mem.eql(u8, ty.name, "bool")) return self.ty_bool;
        if (std.mem.eql(u8, ty.name, "void")) return self.ty_i32; // placeholder

        // Look up struct/enum types
        if (self.struct_types.get(ty.name)) |sty| return sty;
        if (self.enum_types.get(ty.name)) |ety| return ety;

        return self.ty_i32; // fallback
    }

    fn appendBlockToFunc(self: *Codegen, block: Block) void {
        self.current_func_region.appendOwnedBlock(block);
    }
};
