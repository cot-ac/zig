//! Zig Codegen — emit CIR from AST via @import("cot").
//!
//! Walks the parser's AST and emits CIR ops using the cot binding.
//! Each language feature maps to one or more CIR construct ops.

const std = @import("std");
const cot = @import("cot");
const parser = @import("parser");
const scanner = @import("scanner");
const TokenKind = scanner.TokenKind;

const Context = cot.Context;
const Module = cot.Module;
const Block = cot.Block;
const Value = cot.Value;
const Type = cot.Type;
const Location = cot.Location;

const VarInfo = struct {
    addr: Value, // alloca pointer
    ty: Type, // stored type
    pointee_ty: ?Type = null, // for pointer variables: what the pointer points to
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

    // Comptime type param map: "T" → !cir.type_param<"T"> (active during generic fn)
    comptime_type_params: std.StringHashMap(Type) = undefined,

    // Functions with comptime type params: fn_name → [param names]
    generic_functions: std.StringHashMap([]const []const u8) = undefined,

    // Scratch buffer for func.call result types (avoids dangling slice)
    call_result_buf: [1]Type = undefined,

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
        gen.comptime_type_params = std.StringHashMap(Type).init(alloc);
        gen.generic_functions = std.StringHashMap([]const []const u8).init(alloc);
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
        // Set up comptime type params: comptime T: type → !cir.type_param<"T">
        self.comptime_type_params.clearRetainingCapacity();
        var comptime_names: [8][]const u8 = undefined;
        var comptime_count: usize = 0;
        for (fd.params.items) |p| {
            if (p.is_comptime and std.mem.eql(u8, p.type_ref.name, "type")) {
                const tp_ty = cot.types.typeParamType(self.ctx, self.zstr(p.name));
                try self.comptime_type_params.put(p.name, tp_ty);
                comptime_names[comptime_count] = p.name;
                comptime_count += 1;
            }
        }
        // Record this function as generic if it has comptime type params
        if (comptime_count > 0) {
            const names = self.alloc.dupe([]const u8, comptime_names[0..comptime_count]) catch &.{};
            try self.generic_functions.put(fd.name, names);
        }

        const ret_type = self.resolveType(fd.return_type);
        self.return_type = ret_type;

        // Build parameter types (skip comptime type params — they're not runtime)
        var param_types: [32]Type = undefined;
        var n: usize = 0;
        for (fd.params.items) |p| {
            if (p.is_comptime and std.mem.eql(u8, p.type_ref.name, "type"))
                continue; // comptime type param — not a runtime parameter
            param_types[n] = self.resolveType(p.type_ref);
            n += 1;
        }

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

        // Create func.func via the C API — handles region, attributes, insertion
        const func_op = cot.func.create(
            self.module_body, self.loc, self.zstr(fd.name),
            func_type, entry_block,
        );

        // Set up codegen state
        self.current_block = entry_block;
        self.block_terminated = false;
        self.current_func_region = cot.func.getBodyRegion(func_op);
        self.vars = std.StringHashMap(VarInfo).init(self.alloc);

        // Bind parameters: alloca + store for mutable access
        // Skip comptime type params (they're not runtime block arguments)
        var arg_idx: usize = 0;
        for (fd.params.items) |p| {
            if (p.is_comptime and std.mem.eql(u8, p.type_ref.name, "type"))
                continue;
            const arg = entry_block.getArgument(arg_idx);
            const addr = cot.memory.alloca(self.current_block, self.loc, param_types[arg_idx]);
            cot.memory.store(self.current_block, self.loc, arg, addr);
            // Track pointee type for pointer params
            const pointee: ?Type = if (p.type_ref.is_pointer) blk: {
                var inner = p.type_ref;
                inner.is_pointer = false;
                break :blk self.resolveType(inner);
            } else null;
            try self.vars.put(p.name, .{ .addr = addr, .ty = param_types[arg_idx], .pointee_ty = pointee });
            arg_idx += 1;
        }

        // Emit body
        for (fd.body.items) |stmt| {
            try self.emitStmt(stmt);
        }

        // If no explicit return in void function, add one
        if (is_void_ret and !self.block_terminated) {
            cot.func.ret(self.current_block, self.loc, &.{});
        }
    }

    fn emitTestBlock(self: *Codegen, td: parser.TestDecl) CodegenError!void {
        // Emit test_case "name" { body }
        const test_op = cot.testing.testCase(self.module_body, self.loc, self.zstr(td.name));
        // Populate the body region
        const body_region = test_op.getRegion(0);
        const body_block = Block.create(0, null, null);
        body_region.appendOwnedBlock(body_block);

        // Save and reset codegen state for test isolation
        const saved_block = self.current_block;
        const saved_terminated = self.block_terminated;
        const saved_vars = self.vars;
        self.current_block = body_block;
        self.block_terminated = false;
        self.vars = std.StringHashMap(VarInfo).init(self.alloc);

        for (td.body.items) |stmt| {
            try self.emitStmt(stmt);
        }

        // Restore state (test_case has NoTerminator — no terminator needed)
        self.current_block = saved_block;
        self.block_terminated = saved_terminated;
        self.vars = saved_vars;
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
                if (stmt.expr) |e| _ = try self.emitExpr(e, null);
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
        if (stmt.expr) |e| {
            var val = try self.emitExpr(e, self.return_type);
            // Implicit wrapping: returning T from function returning ?T
            if (cot.types.isOptional(self.return_type) and !cot.types.isOptional(val.getType())) {
                val = cot.optionals.wrap(self.current_block, self.loc, self.return_type, val);
            }
            // Implicit wrapping: returning T from function returning T!error
            if (cot.types.isErrorUnion(self.return_type) and !cot.types.isErrorUnion(val.getType())) {
                val = cot.errors.wrapResult(self.current_block, self.loc, self.return_type, val);
            }
            cot.func.ret(self.current_block, self.loc, &.{val});
        } else {
            cot.func.ret(self.current_block, self.loc, &.{});
        }
    }

    fn emitVarDecl(self: *Codegen, stmt: *const parser.Stmt) CodegenError!void {
        // Resolve declared type if present (e.g., "var x: ?i32 = null")
        const declared_type: ?Type = if (stmt.var_type.name.len > 0)
            self.resolveType(stmt.var_type)
        else
            null;

        var init_val = try self.emitExpr(stmt.expr.?, declared_type);
        var val_type = init_val.getType();

        // Implicit wrapping: assigning T to ?T variable
        if (declared_type) |dt| {
            if (cot.types.isOptional(dt) and !cot.types.isOptional(val_type)) {
                init_val = cot.optionals.wrap(self.current_block, self.loc, dt, init_val);
                val_type = dt;
            }
            // Implicit wrapping: assigning T to T!error variable
            if (cot.types.isErrorUnion(dt) and !cot.types.isErrorUnion(val_type)) {
                init_val = cot.errors.wrapResult(self.current_block, self.loc, dt, init_val);
                val_type = dt;
            }
        }

        const store_type = declared_type orelse val_type;
        const addr = cot.memory.alloca(self.current_block, self.loc, store_type);
        cot.memory.store(self.current_block, self.loc, init_val, addr);
        try self.vars.put(stmt.var_name, .{ .addr = addr, .ty = store_type });
    }

    fn emitIf(self: *Codegen, stmt: *const parser.Stmt) CodegenError!void {
        const cond = try self.emitExpr(stmt.expr.?, null);
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
        const cond = try self.emitExpr(stmt.expr.?, null);
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
        const lo = try self.emitExpr(stmt.expr.?, null);
        const hi = if (stmt.range_end) |re| try self.emitExpr(re, null) else lo;

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
        // Resolve expected type from the target variable
        const target_type: ?Type = if (target.kind == .ident)
            (if (self.vars.get(target.name)) |info| info.ty else null)
        else
            null;
        var val = try self.emitExpr(stmt.expr.?, target_type);

        // Implicit wrapping for optional/error union assignment
        if (target_type) |tt| {
            if (cot.types.isOptional(tt) and !cot.types.isOptional(val.getType())) {
                val = cot.optionals.wrap(self.current_block, self.loc, tt, val);
            }
            if (cot.types.isErrorUnion(tt) and !cot.types.isErrorUnion(val.getType())) {
                val = cot.errors.wrapResult(self.current_block, self.loc, tt, val);
            }
        }

        if (target.kind == .ident) {
            if (self.vars.get(target.name)) |info| {
                cot.memory.store(self.current_block, self.loc, val, info.addr);
            }
        } else if (target.kind == .deref) {
            // p.* = val → store to the pointer held in the variable
            const ptr_val = try self.emitExpr(target.lhs.?, null);
            cot.memory.store(self.current_block, self.loc, val, ptr_val);
        }
    }

    fn emitCompoundAssign(self: *Codegen, stmt: *const parser.Stmt) CodegenError!void {
        const target = stmt.lhs_expr orelse return;
        // Pass target type so RHS integer literals get the right width
        const target_type: ?Type = if (target.kind == .ident)
            (if (self.vars.get(target.name)) |info| info.ty else null)
        else
            null;
        const rhs = try self.emitExpr(stmt.expr.?, target_type);

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

    fn emitSwitch(self: *Codegen, stmt: *const parser.Stmt) CodegenError!void {
        // Emit scrutinee and extract tag value
        const scrutinee = try self.emitExpr(stmt.expr.?, null);
        const scrutinee_ty = scrutinee.getType();
        if (!cot.types.isEnum(scrutinee_ty)) return;

        const tag_ty = cot.types.enumTagType(scrutinee_ty);
        const tag = cot.enums.value(self.current_block, self.loc, tag_ty, scrutinee);

        // Build case values and blocks
        const num_arms = stmt.switch_variants.items.len;
        var case_values: [64]i64 = undefined;
        var case_blocks: [64]Block = undefined;
        var case_count: usize = 0;
        var default_idx: ?usize = null;

        for (stmt.switch_variants.items, 0..) |variant_name, arm_idx| {
            if (std.mem.eql(u8, variant_name, "_")) {
                // else/default arm
                default_idx = arm_idx;
            } else {
                // Find variant index in the enum type
                const nv = cot.types.enumVariantCount(scrutinee_ty);
                var found_idx: i64 = 0;
                for (0..nv) |vi| {
                    if (std.mem.eql(u8, cot.types.enumVariantName(scrutinee_ty, vi), variant_name)) {
                        found_idx = @intCast(vi);
                        break;
                    }
                }
                case_values[case_count] = found_idx;
                case_blocks[case_count] = Block.create(0, null, null);
                case_count += 1;
            }
        }

        const merge_block = Block.create(0, null, null);
        const default_block = if (default_idx != null) Block.create(0, null, null) else merge_block;

        // Emit cir.switch
        cot.flow.switchOp(
            self.current_block, self.loc, tag, default_block,
            case_values[0..case_count], case_blocks[0..case_count],
        );

        // Emit each case arm body
        var case_idx: usize = 0;
        for (0..num_arms) |arm_idx| {
            const is_default = if (default_idx) |di| (arm_idx == di) else false;
            const arm_block = if (is_default) default_block else blk: {
                const b = case_blocks[case_idx];
                case_idx += 1;
                break :blk b;
            };

            self.appendBlockToFunc(arm_block);
            self.current_block = arm_block;
            self.block_terminated = false;

            for (stmt.switch_bodies.items[arm_idx].items) |s| {
                try self.emitStmt(s);
            }
            if (!self.block_terminated) {
                cot.flow.br(self.current_block, self.loc, merge_block);
            }
        }

        self.appendBlockToFunc(merge_block);
        self.current_block = merge_block;
        self.block_terminated = false;
    }

    // ===----------------------------------------------------------------------===
    // Expressions
    // ===----------------------------------------------------------------------===

    pub const CodegenError = error{OutOfMemory};

    /// Convert a slice to a null-terminated string for C API calls.
    fn zstr(self: *Codegen, s: []const u8) [*:0]const u8 {
        return self.alloc.dupeZ(u8, s) catch "";
    }

    fn emitExpr(self: *Codegen, expr: *const parser.Expr, expected_type: ?Type) CodegenError!Value {
        // Unwrap expected type for sub-expressions:
        // If expected is optional and expr is not null, pass the payload type.
        // If expected is error_union and expr is not an error call, pass the payload type.
        var et = expected_type;
        if (et) |ety| {
            if (cot.types.isOptional(ety) and expr.kind != .null_lit) {
                et = cot.types.optionalPayloadType(ety);
            } else if (cot.types.isErrorUnion(ety) and expr.kind != .error_val) {
                et = cot.types.errorUnionPayloadType(ety);
            }
        }

        return switch (expr.kind) {
            .int_lit => cot.arith.constant.int(self.current_block, self.loc, et orelse self.ty_i32, expr.int_val),
            .float_lit => cot.arith.constant.float(self.current_block, self.loc, et orelse self.ty_f64, expr.float_val),
            .bool_lit => cot.arith.constant.boolean(self.current_block, self.loc, expr.bool_val),
            .string_lit => self.emitStringLit(expr),
            .null_lit => self.emitNullLit(expected_type),
            .ident => self.emitIdent(expr),
            .bin_op => self.emitBinOp(expr, et),
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
            .dot_ident => self.emitDotIdent(expr, et),
            .error_val => self.emitErrorVal(expr, expected_type),
        };
    }

    fn emitStringLit(self: *Codegen, expr: *const parser.Expr) Value {
        const slice_ty = cot.types.sliceType(self.ctx, self.ty_i8);
        return cot.slices.stringConstant(self.current_block, self.loc, slice_ty, self.zstr(expr.str_val));
    }

    fn emitNullLit(self: *Codegen, expected_type: ?Type) Value {
        // null → cir.none with the expected optional type
        const opt_ty = if (expected_type) |et|
            (if (cot.types.isOptional(et)) et else cot.types.optionalType(self.ctx, self.ty_i32))
        else
            cot.types.optionalType(self.ctx, self.ty_i32);
        return cot.optionals.none(self.current_block, self.loc, opt_ty);
    }

    fn emitIdent(self: *Codegen, expr: *const parser.Expr) Value {
        if (self.vars.get(expr.name)) |info| {
            return cot.memory.load(self.current_block, self.loc, info.addr, info.ty);
        }
        return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
    }

    fn emitBinOp(self: *Codegen, expr: *const parser.Expr, expected_type: ?Type) CodegenError!Value {
        // orelse and catch need special handling — LHS type determines RHS type
        if (expr.op == .kw_orelse) return self.emitOrelse(expr);
        if (expr.op == .kw_catch) return self.emitCatch(expr, expected_type);

        const lhs = try self.emitExpr(expr.lhs.?, null);
        const rhs = try self.emitExpr(expr.rhs.?, null);

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
            else => cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0),
        };
    }

    /// x orelse default → is_non_null ? payload : default
    fn emitOrelse(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        const lhs = try self.emitExpr(expr.lhs.?, null);
        const lhs_ty = lhs.getType();
        if (!cot.types.isOptional(lhs_ty)) return lhs;

        const payload_ty = cot.types.optionalPayloadType(lhs_ty);
        const is_nn = cot.optionals.isNonNull(self.current_block, self.loc, lhs);
        const payload = cot.optionals.payload(self.current_block, self.loc, payload_ty, lhs);
        const rhs = try self.emitExpr(expr.rhs.?, payload_ty);
        return cot.arith.select(self.current_block, self.loc, is_nn, payload, rhs);
    }

    /// x catch default → !is_error ? payload : default
    fn emitCatch(self: *Codegen, expr: *const parser.Expr, expected_type: ?Type) CodegenError!Value {
        _ = expected_type;
        const lhs = try self.emitExpr(expr.lhs.?, null);
        const lhs_ty = lhs.getType();
        if (!cot.types.isErrorUnion(lhs_ty)) return lhs;

        const payload_ty = cot.types.errorUnionPayloadType(lhs_ty);
        const is_err = cot.errors.isError(self.current_block, self.loc, lhs);
        // is_ok = !is_error (XOR with true)
        const true_val = cot.arith.constant.boolean(self.current_block, self.loc, true);
        const is_ok = cot.arith.bitXor(self.current_block, self.loc, is_err, true_val);
        const payload = cot.errors.payload(self.current_block, self.loc, payload_ty, lhs);
        const rhs = try self.emitExpr(expr.rhs.?, payload_ty);
        return cot.arith.select(self.current_block, self.loc, is_ok, payload, rhs);
    }

    fn emitUnaryOp(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        const operand = try self.emitExpr(expr.lhs.?, null);
        return switch (expr.op) {
            .minus => cot.arith.neg(self.current_block, self.loc, operand),
            .tilde => cot.arith.bitNot(self.current_block, self.loc, operand),
            .bang => blk: {
                // Logical not: XOR with true (reference: ac Codegen.cpp)
                const true_val = cot.arith.constant.boolean(self.current_block, self.loc, true);
                break :blk cot.arith.bitXor(self.current_block, self.loc, operand, true_val);
            },
            else => operand,
        };
    }

    fn emitCall(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        // Special builtins
        if (std.mem.eql(u8, expr.name, "assert") or std.mem.eql(u8, expr.name, "@assert")) {
            if (expr.has_args and expr.args.items.len > 0) {
                const cond = try self.emitExpr(expr.args.items[0], null);
                cot.testing.assert(self.current_block, self.loc, cond, "assertion failed");
            }
            return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
        }

        // Check if this is a generic function call: add(i32, 20, 22)
        // If the callee has comptime type params, the first N args are types
        if (self.generic_functions.get(expr.name)) |type_param_names| {
            return self.emitGenericCall(expr, type_param_names);
        }

        // Build argument values
        var arg_vals: [32]Value = undefined;
        var n: usize = 0;
        if (expr.has_args) {
            for (expr.args.items) |arg| {
                arg_vals[n] = try self.emitExpr(arg, null);
                n += 1;
            }
        }

        const callee_name = self.zstr(expr.name);
        const module_op = self.module.getOperation();

        // Coerce arguments: &array → slice at call sites (Zig semantics)
        self.coerceCallArgs(module_op, expr, arg_vals[0..n]);
        const is_void = cot.func.isVoidReturn(module_op, callee_name);
        const result_types: []const Type = if (is_void) &.{} else blk: {
            const ret_type = cot.func.lookupReturnType(module_op, callee_name) orelse self.ty_i32;
            self.call_result_buf[0] = ret_type;
            break :blk self.call_result_buf[0..1];
        };

        const result = cot.func.call(
            self.current_block, self.loc, callee_name,
            arg_vals[0..n], result_types,
        );

        if (is_void) {
            return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
        }
        return result;
    }

    fn emitFieldAccess(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        const base = try self.emitExpr(expr.lhs.?, null);
        const base_ty = base.getType();

        // Slice .len → cir.slice_len
        if (cot.types.isSlice(base_ty) and std.mem.eql(u8, expr.name, "len")) {
            return cot.slices.len(self.current_block, self.loc, base);
        }

        // Struct field access
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
        const base = try self.emitExpr(expr.lhs.?, null);
        const base_ty = base.getType();

        if (cot.types.isArray(base_ty)) {
            const elem_ty = cot.types.arrayElementType(base_ty);
            // Constant index: use cir.elem_val (extractvalue-like)
            if (expr.rhs) |rhs| {
                if (rhs.kind == .int_lit) {
                    return cot.arrays.elemVal(self.current_block, self.loc, elem_ty, base, rhs.int_val);
                }
                // Dynamic index: alloca + elem_ptr + load
                const idx = try self.emitExpr(rhs, null);
                const addr = cot.memory.alloca(self.current_block, self.loc, base_ty);
                cot.memory.store(self.current_block, self.loc, base, addr);
                const ptr = cot.arrays.elemPtr(self.current_block, self.loc, self.ty_ptr, addr, idx, base_ty);
                return cot.memory.load(self.current_block, self.loc, ptr, elem_ty);
            }
        } else if (cot.types.isSlice(base_ty)) {
            const elem_ty = cot.types.sliceElementType(base_ty);
            if (expr.rhs) |rhs| {
                const idx = try self.emitExpr(rhs, null);
                return cot.slices.elem(self.current_block, self.loc, elem_ty, base, idx);
            }
        }
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
                        field_vals[fi] = self.emitExpr(finit.value, null) catch
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
        if (!expr.has_args or expr.args.items.len == 0)
            return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);

        var elem_vals: [64]Value = undefined;
        for (expr.args.items, 0..) |arg, i| {
            elem_vals[i] = try self.emitExpr(arg, null);
        }
        const n = expr.args.items.len;
        const elem_ty = elem_vals[0].getType();
        const arr_ty = cot.types.arrayType(self.ctx, @intCast(n), elem_ty);
        return cot.arrays.init(self.current_block, self.loc, arr_ty, elem_vals[0..n]);
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
                const ptr_val = cot.memory.load(self.current_block, self.loc, info.addr, info.ty);
                const pointee_ty = info.pointee_ty orelse self.ty_i32;
                return cot.memory.load(self.current_block, self.loc, ptr_val, pointee_ty);
            }
        }
        const ptr_val = try self.emitExpr(inner, null);
        return cot.memory.load(self.current_block, self.loc, ptr_val, self.ty_i32);
    }

    fn emitForceUnwrap(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        const opt_val = try self.emitExpr(expr.lhs.?, null);
        // .? → optional_payload — extract payload type from the optional
        const opt_ty = opt_val.getType();
        const payload_ty = if (cot.types.isOptional(opt_ty))
            cot.types.optionalPayloadType(opt_ty)
        else
            self.ty_i32;
        return cot.optionals.payload(self.current_block, self.loc, payload_ty, opt_val);
    }

    fn emitTryUnwrap(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        const eu_val = try self.emitExpr(expr.lhs.?, null);
        // try → check is_error, branch: error path propagates, success path extracts payload
        const eu_ty = eu_val.getType();
        if (!cot.types.isErrorUnion(eu_ty)) return eu_val;

        const payload_ty = cot.types.errorUnionPayloadType(eu_ty);
        const is_err = cot.errors.isError(self.current_block, self.loc, eu_val);

        const err_block = Block.create(0, null, null);
        const ok_block = Block.create(0, null, null);

        cot.flow.condBr(self.current_block, self.loc, is_err, err_block, ok_block);

        // Error path: propagate error to caller
        self.appendBlockToFunc(err_block);
        self.current_block = err_block;
        self.block_terminated = false;
        const err_code = cot.errors.code(self.current_block, self.loc, eu_val);
        const wrapped = cot.errors.wrapError(self.current_block, self.loc, self.return_type, err_code);
        cot.func.ret(self.current_block, self.loc, &.{wrapped});

        // Success path: extract payload
        self.appendBlockToFunc(ok_block);
        self.current_block = ok_block;
        self.block_terminated = false;
        return cot.errors.payload(self.current_block, self.loc, payload_ty, eu_val);
    }

    fn emitCastAs(self: *Codegen, expr: *const parser.Expr) CodegenError!Value {
        const input = try self.emitExpr(expr.lhs.?, null);
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
        // arr[lo..hi] → alloca array, cir.array_to_slice
        const base = try self.emitExpr(expr.lhs.?, null);
        const base_ty = base.getType();

        if (cot.types.isArray(base_ty)) {
            const elem_ty = cot.types.arrayElementType(base_ty);
            const slice_ty = cot.types.sliceType(self.ctx, elem_ty);
            // Store array to get a stable address for slicing
            const addr = cot.memory.alloca(self.current_block, self.loc, base_ty);
            cot.memory.store(self.current_block, self.loc, base, addr);
            // Emit start and end indices
            const lo = if (expr.rhs) |rhs| try self.emitExpr(rhs, null) else cot.arith.constant.int(self.current_block, self.loc, self.ty_i64, 0);
            const hi = if (expr.has_args and expr.args.items.len > 0)
                try self.emitExpr(expr.args.items[0], null)
            else
                cot.arith.constant.int(self.current_block, self.loc, self.ty_i64, cot.types.arraySize(base_ty));
            return cot.slices.arrayToSlice(self.current_block, self.loc, slice_ty, addr, lo, hi);
        }
        return cot.arith.constant.int(self.current_block, self.loc, self.ty_i32, 0);
    }

    fn emitErrorVal(self: *Codegen, expr: *const parser.Expr, expected_type: ?Type) CodegenError!Value {
        // error.Name → cir.wrap_error with a hash-based error code
        // Requires error_union type context for the wrap_error return type
        const eu_ty = if (expected_type) |et|
            (if (cot.types.isErrorUnion(et)) et else cot.types.errorUnionType(self.ctx, self.ty_i32))
        else
            cot.types.errorUnionType(self.ctx, self.ty_i32);

        // Generate a non-zero error code from the variant name
        var code: i64 = 1;
        for (expr.name) |ch| {
            code = code *% 31 +% @as(i64, ch);
        }
        if (code <= 0) code = 1; // ensure non-zero
        const code_val = cot.arith.constant.int(self.current_block, self.loc, self.ty_i16, code);
        return cot.errors.wrapError(self.current_block, self.loc, eu_ty, code_val);
    }

    fn emitDotIdent(self: *Codegen, expr: *const parser.Expr, expected_type: ?Type) CodegenError!Value {
        // .Variant → cir.enum_constant with the expected enum type
        if (expected_type) |et| {
            if (cot.types.isEnum(et)) {
                return cot.enums.constant(self.current_block, self.loc, et, self.zstr(expr.name));
            }
        }
        // Fallback: search all registered enum types for the variant name
        var enum_iter = self.enum_defs.iterator();
        while (enum_iter.next()) |entry| {
            for (entry.value_ptr.variants.items) |v| {
                if (std.mem.eql(u8, v, expr.name)) {
                    const ety = self.enum_types.get(entry.key_ptr.*).?;
                    return cot.enums.constant(self.current_block, self.loc, ety, self.zstr(expr.name));
                }
            }
        }
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
        if (std.mem.eql(u8, ty.name, "usize")) return self.ty_i64; // 64-bit target
        if (std.mem.eql(u8, ty.name, "f32")) return self.ty_f32;
        if (std.mem.eql(u8, ty.name, "f64")) return self.ty_f64;
        if (std.mem.eql(u8, ty.name, "bool")) return self.ty_bool;
        if (std.mem.eql(u8, ty.name, "void")) return self.ty_i32; // placeholder

        // Look up struct/enum types
        if (self.struct_types.get(ty.name)) |sty| return sty;
        if (self.enum_types.get(ty.name)) |ety| return ety;

        // Comptime type params: T → !cir.type_param<"T">
        if (self.comptime_type_params.get(ty.name)) |tp| return tp;

        return self.ty_i32; // fallback
    }

    /// Emit a generic function call: add(i32, 20, 22) → cir.generic_apply
    fn emitGenericCall(self: *Codegen, expr: *const parser.Expr, type_param_names: []const []const u8) CodegenError!Value {
        const num_type_args = type_param_names.len;

        // First N args are type names → build substitution map
        var sub_keys: [8][*:0]const u8 = undefined;
        var sub_types: [8]Type = undefined;
        for (0..num_type_args) |i| {
            sub_keys[i] = self.zstr(type_param_names[i]);
            // The arg at position i should be an ident naming a type
            if (expr.has_args and i < expr.args.items.len) {
                const type_arg = expr.args.items[i];
                if (type_arg.kind == .ident) {
                    sub_types[i] = self.resolveType(.{ .name = type_arg.name });
                } else {
                    sub_types[i] = self.ty_i32; // fallback
                }
            }
        }

        // Remaining args are values
        var arg_vals: [32]Value = undefined;
        var n: usize = 0;
        if (expr.has_args) {
            for (expr.args.items[num_type_args..]) |arg| {
                arg_vals[n] = try self.emitExpr(arg, null);
                n += 1;
            }
        }

        // Look up callee return type — resolve type_param with our concrete types
        const callee_name = self.zstr(expr.name);
        const module_op = self.module.getOperation();
        var result_type = self.ty_i32;
        if (cot.func.lookupReturnType(module_op, callee_name)) |ret_ty| {
            if (cot.types.isTypeParam(ret_ty)) {
                // Return type is a type param — use the first substitution
                result_type = sub_types[0];
            } else {
                result_type = ret_ty;
            }
        }

        // Emit cir.generic_apply
        const result = cot.ops.func.genericApply(
            self.current_block, self.loc, callee_name,
            arg_vals[0..n], sub_keys[0..num_type_args], sub_types[0..num_type_args],
            result_type,
        );
        return result;
    }

    /// Coerce call arguments: &array → slice when callee expects []T.
    /// Zig passes &arr to []T params via implicit coercion.
    fn coerceCallArgs(self: *Codegen, module_op: cot.ir.Operation, expr: *const parser.Expr, args: []Value) void {
        const sym_table = cot.ir.SymbolTable.create(module_op);
        defer sym_table.destroy();
        const callee_op = sym_table.lookup(expr.name) orelse return;
        const fty = callee_op.getFunctionType() orelse return;
        const num_params = cot.types.functionNumInputs(fty);

        for (0..@min(args.len, num_params)) |i| {
            const param_ty = cot.types.functionInput(fty, i);
            if (!cot.types.isSlice(param_ty) or !cot.types.isPtr(args[i].getType()))
                continue;
            // &arr passed to []T — coerce via array_to_slice
            const arg_expr = expr.args.items[i];
            if (arg_expr.kind != .addr_of) continue;
            const inner = arg_expr.lhs orelse continue;
            if (inner.kind != .ident) continue;
            const info = self.vars.get(inner.name) orelse continue;
            if (!cot.types.isArray(info.ty)) continue;

            const elem_ty = cot.types.arrayElementType(info.ty);
            const slice_ty = cot.types.sliceType(self.ctx, elem_ty);
            const arr_val = cot.memory.load(self.current_block, self.loc, info.addr, info.ty);
            const arr_addr = cot.memory.alloca(self.current_block, self.loc, info.ty);
            cot.memory.store(self.current_block, self.loc, arr_val, arr_addr);
            const zero = cot.arith.constant.int(self.current_block, self.loc, self.ty_i64, 0);
            const len = cot.arith.constant.int(self.current_block, self.loc, self.ty_i64, cot.types.arraySize(info.ty));
            args[i] = cot.slices.arrayToSlice(self.current_block, self.loc, slice_ty, arr_addr, zero, len);
        }
    }

    fn appendBlockToFunc(self: *Codegen, block: Block) void {
        self.current_func_region.appendOwnedBlock(block);
    }
};
