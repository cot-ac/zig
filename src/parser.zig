//! Zig Parser — recursive descent parser for the Zig subset.
//!
//! Produces an AST from tokens. Supports:
//! - Top-level: fn, pub fn, const struct/enum, test
//! - Statements: var/const, if/else, while, for, return, switch,
//!   break/continue, assignment, compound assignment, expression
//! - Expressions: binary ops, unary, call, field access, index,
//!   optional unwrap (.?), try, address-of (&), deref (.*),
//!   @as cast, array/struct init, slice (a[lo..hi])
//!
//! Reference: Go parser, Zig Parse.zig

const std = @import("std");
const scanner = @import("scanner");
const Token = scanner.Token;
const TokenKind = scanner.TokenKind;

pub const TypeRef = struct {
    name: []const u8 = "",
    array_len: i64 = 0,
    is_array: bool = false,
    is_optional: bool = false,
    is_error_union: bool = false,
    is_pointer: bool = false,
    is_slice: bool = false,
};

pub const Param = struct {
    name: []const u8,
    type_ref: TypeRef,
};

pub const FieldInit = struct {
    name: []const u8,
    value: *Expr,
};

pub const ExprKind = enum {
    int_lit,
    float_lit,
    bool_lit,
    string_lit,
    null_lit,
    ident,
    bin_op,
    unary_op,
    call,
    struct_lit,
    field_access,
    array_lit,
    index,
    force_unwrap,
    try_unwrap,
    addr_of,
    deref,
    cast_as,
    slice_from,
    dot_ident, // .variant (enum literal)
};

pub const Expr = struct {
    kind: ExprKind,
    pos: u32 = 0,

    int_val: i64 = 0,
    float_val: f64 = 0.0,
    bool_val: bool = false,
    name: []const u8 = "",
    str_val: []const u8 = "",
    op: TokenKind = .invalid,
    lhs: ?*Expr = null,
    rhs: ?*Expr = null,
    args: std.ArrayListUnmanaged(*Expr) = undefined,
    fields: std.ArrayListUnmanaged(FieldInit) = undefined,
    cast_type: TypeRef = .{},

    has_args: bool = false,
    has_fields: bool = false,
};

pub const StmtKind = enum {
    ret,
    expr_stmt,
    if_stmt,
    while_stmt,
    for_stmt,
    break_stmt,
    continue_stmt,
    let_decl,
    var_decl,
    assign,
    compound_assign,
    switch_stmt,
};

pub const Stmt = struct {
    kind: StmtKind,
    pos: u32 = 0,
    expr: ?*Expr = null,
    lhs_expr: ?*Expr = null, // For assign/compound_assign: the target
    range_end: ?*Expr = null,
    then_body: std.ArrayListUnmanaged(*Stmt) = undefined,
    else_body: std.ArrayListUnmanaged(*Stmt) = undefined,
    var_name: []const u8 = "",
    var_type: TypeRef = .{},
    op: TokenKind = .invalid,
    // Switch arms
    switch_variants: std.ArrayListUnmanaged([]const u8) = undefined,
    switch_bodies: std.ArrayListUnmanaged(std.ArrayListUnmanaged(*Stmt)) = undefined,

    has_then: bool = false,
    has_else: bool = false,
    has_switch: bool = false,
};

pub const EnumDef = struct {
    name: []const u8,
    variants: std.ArrayListUnmanaged([]const u8),
    pos: u32,
};

pub const StructDef = struct {
    name: []const u8,
    fields: std.ArrayListUnmanaged(Param),
    pos: u32,
};

pub const FnDecl = struct {
    name: []const u8,
    params: std.ArrayListUnmanaged(Param),
    return_type: TypeRef,
    body: std.ArrayListUnmanaged(*Stmt),
    pos: u32,
};

pub const TestDecl = struct {
    name: []const u8,
    body: std.ArrayListUnmanaged(*Stmt),
    pos: u32,
};

pub const Module = struct {
    enums: std.ArrayListUnmanaged(EnumDef),
    structs: std.ArrayListUnmanaged(StructDef),
    functions: std.ArrayListUnmanaged(FnDecl),
    tests: std.ArrayListUnmanaged(TestDecl),
};

pub const Parser = struct {
    source: []const u8,
    tokens: []const Token,
    pos: u32 = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, source: []const u8, tokens: []const Token) Parser {
        return .{
            .source = source,
            .tokens = tokens,
            .alloc = alloc,
        };
    }

    pub fn parseModule(self: *Parser) ParseError!Module {
        var mod = Module{
            .enums = std.ArrayListUnmanaged(EnumDef){},
            .structs = std.ArrayListUnmanaged(StructDef){},
            .functions = std.ArrayListUnmanaged(FnDecl){},
            .tests = std.ArrayListUnmanaged(TestDecl){},
        };

        while (self.peek() != .eof) {
            const kind = self.peek();
            if (kind == .kw_pub) {
                self.advance(); // skip pub
                if (self.peek() == .kw_fn) {
                    try mod.functions.append(self.alloc,try self.parseFnDecl());
                } else return error.UnexpectedToken;
            } else if (kind == .kw_fn) {
                try mod.functions.append(self.alloc,try self.parseFnDecl());
            } else if (kind == .kw_const) {
                // const Name = struct { ... } or const Name = enum { ... }
                try self.parseConstDecl(&mod);
            } else if (kind == .kw_test) {
                try mod.tests.append(self.alloc,try self.parseTestDecl());
            } else {
                return error.UnexpectedToken;
            }
        }

        return mod;
    }

    // ===----------------------------------------------------------------------===
    // Top-level declarations
    // ===----------------------------------------------------------------------===

    fn parseFnDecl(self: *Parser) ParseError!FnDecl {
        const pos = self.current().start;
        self.expect(.kw_fn);
        const name = self.expectIdent();
        self.expect(.l_paren);

        var params = std.ArrayListUnmanaged(Param){};
        while (self.peek() != .r_paren) {
            const pname = self.expectIdent();
            self.expect(.colon);
            const ptype = try self.parseTypeRef();
            try params.append(self.alloc,.{ .name = pname, .type_ref = ptype });
            if (self.peek() == .comma) self.advance();
        }
        self.expect(.r_paren);

        var return_type = TypeRef{ .name = "void" };
        if (self.peek() != .l_brace) {
            return_type = try self.parseTypeRef();
        }

        const body = try self.parseBlock();

        return .{
            .name = name,
            .params = params,
            .return_type = return_type,
            .body = body,
            .pos = pos,
        };
    }

    fn parseConstDecl(self: *Parser, mod: *Module) ParseError!void {
        self.expect(.kw_const);
        const name = self.expectIdent();
        self.expect(.equal);

        if (self.peek() == .kw_struct) {
            self.advance();
            try mod.structs.append(self.alloc,try self.parseStructBody(name));
        } else if (self.peek() == .kw_enum) {
            self.advance();
            try mod.enums.append(self.alloc,try self.parseEnumBody(name));
        } else {
            return error.UnexpectedToken;
        }
    }

    fn parseStructBody(self: *Parser, name: []const u8) ParseError!StructDef {
        const pos = self.current().start;
        self.expect(.l_brace);
        var fields = std.ArrayListUnmanaged(Param){};
        while (self.peek() != .r_brace) {
            const fname = self.expectIdent();
            self.expect(.colon);
            const ftype = try self.parseTypeRef();
            try fields.append(self.alloc,.{ .name = fname, .type_ref = ftype });
            if (self.peek() == .comma) self.advance();
        }
        self.expect(.r_brace);
        // Optional trailing semicolon
        if (self.peek() == .semicolon) self.advance();
        return .{ .name = name, .fields = fields, .pos = pos };
    }

    fn parseEnumBody(self: *Parser, name: []const u8) ParseError!EnumDef {
        const pos = self.current().start;
        self.expect(.l_brace);
        var variants = std.ArrayListUnmanaged([]const u8){};
        while (self.peek() != .r_brace) {
            const vname = self.expectIdent();
            try variants.append(self.alloc,vname);
            if (self.peek() == .comma) self.advance();
        }
        self.expect(.r_brace);
        if (self.peek() == .semicolon) self.advance();
        return .{ .name = name, .variants = variants, .pos = pos };
    }

    fn parseTestDecl(self: *Parser) ParseError!TestDecl {
        const pos = self.current().start;
        self.expect(.kw_test);
        // test "name" { ... }
        var name: []const u8 = "unnamed";
        if (self.peek() == .string_literal) {
            const tok = self.current();
            self.advance();
            name = self.source[tok.start + 1 .. tok.end - 1];
        }
        const body = try self.parseBlock();
        return .{ .name = name, .body = body, .pos = pos };
    }

    // ===----------------------------------------------------------------------===
    // Types
    // ===----------------------------------------------------------------------===

    fn parseTypeRef(self: *Parser) ParseError!TypeRef {
        var ty = TypeRef{};

        // ?T — optional
        if (self.peek() == .question) {
            self.advance();
            ty = try self.parseTypeRef();
            ty.is_optional = true;
            return ty;
        }

        // *T — pointer
        if (self.peek() == .star) {
            self.advance();
            ty = try self.parseTypeRef();
            ty.is_pointer = true;
            return ty;
        }

        // []T — slice
        if (self.peek() == .l_bracket) {
            self.advance();
            if (self.peek() == .r_bracket) {
                // []T — slice
                self.advance();
                ty = try self.parseTypeRef();
                ty.is_slice = true;
                return ty;
            } else {
                // [N]T — array
                const len_tok = self.current();
                if (self.peek() != .int_literal) return error.ExpectedArrayLen;
                self.advance();
                self.expect(.r_bracket);
                ty = try self.parseTypeRef();
                ty.is_array = true;
                ty.array_len = std.fmt.parseInt(i64, self.source[len_tok.start..len_tok.end], 10) catch 0;
                return ty;
            }
        }

        // Base type name
        const kind = self.peek();
        ty.name = switch (kind) {
            .ty_i8 => "i8",
            .ty_i16 => "i16",
            .ty_i32 => "i32",
            .ty_i64 => "i64",
            .ty_u8 => "u8",
            .ty_u16 => "u16",
            .ty_u32 => "u32",
            .ty_u64 => "u64",
            .ty_f32 => "f32",
            .ty_f64 => "f64",
            .ty_bool => "bool",
            .ty_void => "void",
            .identifier => self.tokenText(self.current()),
            else => return error.ExpectedType,
        };
        self.advance();

        // T!error — error union (check for ! after base type)
        if (self.peek() == .bang) {
            self.advance();
            ty.is_error_union = true;
        }

        return ty;
    }

    // ===----------------------------------------------------------------------===
    // Statements
    // ===----------------------------------------------------------------------===

    fn parseBlock(self: *Parser) ParseError!std.ArrayListUnmanaged(*Stmt) {
        self.expect(.l_brace);
        var stmts = std.ArrayListUnmanaged(*Stmt){};
        while (self.peek() != .r_brace and self.peek() != .eof) {
            try stmts.append(self.alloc,try self.parseStmt());
        }
        self.expect(.r_brace);
        return stmts;
    }

    fn parseStmt(self: *Parser) ParseError!*Stmt {
        return switch (self.peek()) {
            .kw_return => self.parseReturn(),
            .kw_if => self.parseIf(),
            .kw_while => self.parseWhile(),
            .kw_for => self.parseFor(),
            .kw_break => self.parseBreak(),
            .kw_continue => self.parseContinue(),
            .kw_var => self.parseVarDecl(.var_decl),
            .kw_const => self.parseVarDecl(.let_decl),
            .kw_switch => self.parseSwitch(),
            else => self.parseExprOrAssign(),
        };
    }

    fn parseReturn(self: *Parser) ParseError!*Stmt {
        const stmt = try self.alloc.create(Stmt);
        stmt.* = .{ .kind = .ret, .pos = self.current().start };
        self.advance(); // skip 'return'
        if (self.peek() != .semicolon and self.peek() != .r_brace) {
            stmt.expr = try self.parseExpr();
        }
        self.eatSemicolon();
        return stmt;
    }

    fn parseIf(self: *Parser) ParseError!*Stmt {
        const stmt = try self.alloc.create(Stmt);
        stmt.* = .{ .kind = .if_stmt, .pos = self.current().start, .has_then = true };
        self.advance(); // skip 'if'
        self.expect(.l_paren);
        stmt.expr = try self.parseExpr();
        self.expect(.r_paren);
        stmt.then_body = try self.parseBlock();
        if (self.peek() == .kw_else) {
            self.advance();
            stmt.has_else = true;
            stmt.else_body = try self.parseBlock();
        }
        return stmt;
    }

    fn parseWhile(self: *Parser) ParseError!*Stmt {
        const stmt = try self.alloc.create(Stmt);
        stmt.* = .{ .kind = .while_stmt, .pos = self.current().start, .has_then = true };
        self.advance(); // skip 'while'
        self.expect(.l_paren);
        stmt.expr = try self.parseExpr();
        self.expect(.r_paren);
        stmt.then_body = try self.parseBlock();
        return stmt;
    }

    fn parseFor(self: *Parser) ParseError!*Stmt {
        const stmt = try self.alloc.create(Stmt);
        stmt.* = .{ .kind = .for_stmt, .pos = self.current().start, .has_then = true };
        self.advance(); // skip 'for'
        self.expect(.l_paren);
        // for (0..n) |i| { ... }
        stmt.expr = try self.parseExpr();
        if (self.peek() == .dot_dot) {
            self.advance();
            stmt.range_end = try self.parseExpr();
        }
        self.expect(.r_paren);
        // |capture|
        if (self.peek() == .pipe) {
            self.advance();
            stmt.var_name = self.expectIdent();
            self.expect(.pipe);
        }
        stmt.then_body = try self.parseBlock();
        return stmt;
    }

    fn parseBreak(self: *Parser) ParseError!*Stmt {
        const stmt = try self.alloc.create(Stmt);
        stmt.* = .{ .kind = .break_stmt, .pos = self.current().start };
        self.advance();
        self.eatSemicolon();
        return stmt;
    }

    fn parseContinue(self: *Parser) ParseError!*Stmt {
        const stmt = try self.alloc.create(Stmt);
        stmt.* = .{ .kind = .continue_stmt, .pos = self.current().start };
        self.advance();
        self.eatSemicolon();
        return stmt;
    }

    fn parseVarDecl(self: *Parser, kind: StmtKind) ParseError!*Stmt {
        const stmt = try self.alloc.create(Stmt);
        stmt.* = .{ .kind = kind, .pos = self.current().start };
        self.advance(); // skip var/const
        stmt.var_name = self.expectIdent();
        if (self.peek() == .colon) {
            self.advance();
            stmt.var_type = try self.parseTypeRef();
        }
        self.expect(.equal);
        stmt.expr = try self.parseExpr();
        self.eatSemicolon();
        return stmt;
    }

    fn parseSwitch(self: *Parser) ParseError!*Stmt {
        const stmt = try self.alloc.create(Stmt);
        stmt.* = .{ .kind = .switch_stmt, .pos = self.current().start, .has_switch = true };
        self.advance(); // skip 'switch'
        self.expect(.l_paren);
        stmt.expr = try self.parseExpr();
        self.expect(.r_paren);
        self.expect(.l_brace);

        stmt.switch_variants = std.ArrayListUnmanaged([]const u8){};
        stmt.switch_bodies = std.ArrayListUnmanaged(std.ArrayListUnmanaged(*Stmt)){};

        while (self.peek() != .r_brace) {
            // .Variant => { body },
            if (self.peek() == .dot) {
                self.advance();
                const vname = self.expectIdent();
                try stmt.switch_variants.append(self.alloc,vname);
            } else {
                try stmt.switch_variants.append(self.alloc,"_");
                self.advance(); // skip 'else' or '_'
            }
            self.expect(.fat_arrow);
            if (self.peek() == .l_brace) {
                try stmt.switch_bodies.append(self.alloc,try self.parseBlock());
            } else {
                // Single expression arm
                var body = std.ArrayListUnmanaged(*Stmt){};
                const es = try self.alloc.create(Stmt);
                es.* = .{ .kind = .expr_stmt, .expr = try self.parseExpr() };
                try body.append(self.alloc,es);
                try stmt.switch_bodies.append(self.alloc,body);
            }
            if (self.peek() == .comma) self.advance();
        }
        self.expect(.r_brace);
        return stmt;
    }

    fn parseExprOrAssign(self: *Parser) ParseError!*Stmt {
        const expr = try self.parseExpr();
        const kind = self.peek();

        // Assignment: expr = expr
        if (kind == .equal) {
            self.advance();
            const stmt = try self.alloc.create(Stmt);
            stmt.* = .{ .kind = .assign, .pos = expr.pos, .lhs_expr = expr };
            stmt.expr = try self.parseExpr();
            self.eatSemicolon();
            return stmt;
        }

        // Compound assignment: expr += expr
        if (kind == .plus_equal or kind == .minus_equal or
            kind == .star_equal or kind == .slash_equal)
        {
            self.advance();
            const stmt = try self.alloc.create(Stmt);
            stmt.* = .{ .kind = .compound_assign, .pos = expr.pos, .op = kind };
            stmt.lhs_expr = expr;
            stmt.expr = try self.parseExpr();
            self.eatSemicolon();
            return stmt;
        }

        // Expression statement
        const stmt = try self.alloc.create(Stmt);
        stmt.* = .{ .kind = .expr_stmt, .pos = expr.pos, .expr = expr };
        self.eatSemicolon();
        return stmt;
    }

    // ===----------------------------------------------------------------------===
    // Expressions — precedence climbing
    // ===----------------------------------------------------------------------===

    pub const ParseError = error{ UnexpectedToken, ExpectedArrayLen, ExpectedType, ExpectedExpression, OutOfMemory };

    fn parseExpr(self: *Parser) ParseError!*Expr {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!*Expr {
        var lhs = try self.parseAnd();
        while (self.peek() == .pipe_pipe) {
            const op = self.peek();
            self.advance();
            const rhs = try self.parseAnd();
            const node = try self.alloc.create(Expr);
            node.* = .{ .kind = .bin_op, .op = op, .lhs = lhs, .rhs = rhs };
            lhs = node;
        }
        return lhs;
    }

    fn parseAnd(self: *Parser) ParseError!*Expr {
        var lhs = try self.parseComparison();
        while (self.peek() == .ampersand_ampersand) {
            const op = self.peek();
            self.advance();
            const rhs = try self.parseComparison();
            const node = try self.alloc.create(Expr);
            node.* = .{ .kind = .bin_op, .op = op, .lhs = lhs, .rhs = rhs };
            lhs = node;
        }
        return lhs;
    }

    fn parseComparison(self: *Parser) ParseError!*Expr {
        var lhs = try self.parseBitOr();
        const kind = self.peek();
        if (kind == .equal_equal or kind == .bang_equal or
            kind == .less or kind == .less_equal or
            kind == .greater or kind == .greater_equal)
        {
            self.advance();
            const rhs = try self.parseBitOr();
            const node = try self.alloc.create(Expr);
            node.* = .{ .kind = .bin_op, .op = kind, .lhs = lhs, .rhs = rhs };
            lhs = node;
        }
        return lhs;
    }

    fn parseBitOr(self: *Parser) ParseError!*Expr {
        var lhs = try self.parseBitXor();
        while (self.peek() == .pipe) {
            self.advance();
            const rhs = try self.parseBitXor();
            const node = try self.alloc.create(Expr);
            node.* = .{ .kind = .bin_op, .op = .pipe, .lhs = lhs, .rhs = rhs };
            lhs = node;
        }
        return lhs;
    }

    fn parseBitXor(self: *Parser) ParseError!*Expr {
        var lhs = try self.parseBitAnd();
        while (self.peek() == .caret) {
            self.advance();
            const rhs = try self.parseBitAnd();
            const node = try self.alloc.create(Expr);
            node.* = .{ .kind = .bin_op, .op = .caret, .lhs = lhs, .rhs = rhs };
            lhs = node;
        }
        return lhs;
    }

    fn parseBitAnd(self: *Parser) ParseError!*Expr {
        var lhs = try self.parseShift();
        while (self.peek() == .ampersand and self.peekNext() != .ampersand) {
            self.advance();
            const rhs = try self.parseShift();
            const node = try self.alloc.create(Expr);
            node.* = .{ .kind = .bin_op, .op = .ampersand, .lhs = lhs, .rhs = rhs };
            lhs = node;
        }
        return lhs;
    }

    fn parseShift(self: *Parser) ParseError!*Expr {
        var lhs = try self.parseAddSub();
        while (self.peek() == .shl or self.peek() == .shr) {
            const op = self.peek();
            self.advance();
            const rhs = try self.parseAddSub();
            const node = try self.alloc.create(Expr);
            node.* = .{ .kind = .bin_op, .op = op, .lhs = lhs, .rhs = rhs };
            lhs = node;
        }
        return lhs;
    }

    fn parseAddSub(self: *Parser) ParseError!*Expr {
        var lhs = try self.parseMulDiv();
        while (self.peek() == .plus or self.peek() == .minus) {
            const op = self.peek();
            self.advance();
            const rhs = try self.parseMulDiv();
            const node = try self.alloc.create(Expr);
            node.* = .{ .kind = .bin_op, .op = op, .lhs = lhs, .rhs = rhs };
            lhs = node;
        }
        return lhs;
    }

    fn parseMulDiv(self: *Parser) ParseError!*Expr {
        var lhs = try self.parseUnary();
        while (self.peek() == .star or self.peek() == .slash or self.peek() == .percent) {
            const op = self.peek();
            self.advance();
            const rhs = try self.parseUnary();
            const node = try self.alloc.create(Expr);
            node.* = .{ .kind = .bin_op, .op = op, .lhs = lhs, .rhs = rhs };
            lhs = node;
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) ParseError!*Expr {
        const kind = self.peek();
        if (kind == .minus or kind == .bang or kind == .tilde) {
            self.advance();
            const operand = try self.parseUnary();
            const node = try self.alloc.create(Expr);
            node.* = .{ .kind = .unary_op, .op = kind, .lhs = operand };
            return node;
        }
        if (kind == .ampersand) {
            self.advance();
            const operand = try self.parseUnary();
            const node = try self.alloc.create(Expr);
            node.* = .{ .kind = .addr_of, .lhs = operand };
            return node;
        }
        if (kind == .kw_try) {
            self.advance();
            const operand = try self.parseUnary();
            const node = try self.alloc.create(Expr);
            node.* = .{ .kind = .try_unwrap, .lhs = operand };
            return node;
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParseError!*Expr {
        var expr = try self.parsePrimary();

        while (true) {
            const kind = self.peek();
            if (kind == .dot) {
                self.advance();
                const field_name = self.expectIdent();
                const node = try self.alloc.create(Expr);
                node.* = .{ .kind = .field_access, .name = field_name, .lhs = expr };
                expr = node;
            } else if (kind == .dot_star) {
                self.advance();
                const node = try self.alloc.create(Expr);
                node.* = .{ .kind = .deref, .lhs = expr };
                expr = node;
            } else if (kind == .dot_question) {
                self.advance();
                const node = try self.alloc.create(Expr);
                node.* = .{ .kind = .force_unwrap, .lhs = expr };
                expr = node;
            } else if (kind == .l_paren) {
                // Function call
                self.advance();
                const node = try self.alloc.create(Expr);
                node.* = .{ .kind = .call, .name = expr.name, .has_args = true };
                node.args = std.ArrayListUnmanaged(*Expr){};
                while (self.peek() != .r_paren) {
                    try node.args.append(self.alloc,try self.parseExpr());
                    if (self.peek() == .comma) self.advance();
                }
                self.expect(.r_paren);
                expr = node;
            } else if (kind == .l_bracket) {
                self.advance();
                const idx = try self.parseExpr();
                if (self.peek() == .dot_dot) {
                    // Slice: a[lo..hi]
                    self.advance();
                    const hi = try self.parseExpr();
                    self.expect(.r_bracket);
                    const lo_expr = idx;
                    const node = try self.alloc.create(Expr);
                    // slice_from: lhs=base, rhs=hi, and we store lo in args
                    node.* = .{ .kind = .slice_from, .lhs = expr, .rhs = hi, .has_args = true };
                    node.args = std.ArrayListUnmanaged(*Expr){};
                    try node.args.append(self.alloc,lo_expr);
                    expr = node;
                } else {
                    // Index: a[i]
                    self.expect(.r_bracket);
                    const node = try self.alloc.create(Expr);
                    node.* = .{ .kind = .index, .lhs = expr, .rhs = idx };
                    expr = node;
                }
            } else if (kind == .kw_orelse) {
                self.advance();
                const rhs = try self.parseExpr();
                const node = try self.alloc.create(Expr);
                node.* = .{ .kind = .bin_op, .op = .kw_orelse, .lhs = expr, .rhs = rhs };
                expr = node;
            } else if (kind == .kw_catch) {
                self.advance();
                const rhs = try self.parseExpr();
                const node = try self.alloc.create(Expr);
                node.* = .{ .kind = .bin_op, .op = .kw_catch, .lhs = expr, .rhs = rhs };
                expr = node;
            } else break;
        }

        return expr;
    }

    fn parsePrimary(self: *Parser) ParseError!*Expr {
        const kind = self.peek();
        const tok = self.current();

        switch (kind) {
            .int_literal => {
                self.advance();
                const node = try self.alloc.create(Expr);
                const text = self.source[tok.start..tok.end];
                node.* = .{ .kind = .int_lit, .pos = tok.start };
                node.int_val = std.fmt.parseInt(i64, text, 10) catch 0;
                return node;
            },
            .float_literal => {
                self.advance();
                const node = try self.alloc.create(Expr);
                const text = self.source[tok.start..tok.end];
                node.* = .{ .kind = .float_lit, .pos = tok.start };
                node.float_val = std.fmt.parseFloat(f64, text) catch 0.0;
                return node;
            },
            .string_literal => {
                self.advance();
                const node = try self.alloc.create(Expr);
                node.* = .{ .kind = .string_lit, .pos = tok.start };
                node.str_val = self.source[tok.start + 1 .. tok.end - 1];
                return node;
            },
            .true_lit => {
                self.advance();
                const node = try self.alloc.create(Expr);
                node.* = .{ .kind = .bool_lit, .bool_val = true };
                return node;
            },
            .false_lit => {
                self.advance();
                const node = try self.alloc.create(Expr);
                node.* = .{ .kind = .bool_lit, .bool_val = false };
                return node;
            },
            .kw_null => {
                self.advance();
                const node = try self.alloc.create(Expr);
                node.* = .{ .kind = .null_lit };
                return node;
            },
            .dot => {
                // .Variant (enum literal)
                self.advance();
                const vname = self.expectIdent();
                const node = try self.alloc.create(Expr);
                node.* = .{ .kind = .dot_ident, .name = vname };
                return node;
            },
            .identifier => {
                self.advance();
                const name = self.source[tok.start..tok.end];
                // Check for @as(Type, expr) builtin
                if (tok.start > 0 and self.source[tok.start] == '@') {
                    // It's a builtin like @as
                    return self.parseBuiltin(name, tok.start);
                }
                // Check for struct literal: Name { field: val, ... }
                if (self.peek() == .l_brace) {
                    return self.parseStructLiteral(name, tok.start);
                }
                const node = try self.alloc.create(Expr);
                node.* = .{ .kind = .ident, .name = name, .pos = tok.start };
                return node;
            },
            .l_paren => {
                // Grouped expression
                self.advance();
                const inner = try self.parseExpr();
                self.expect(.r_paren);
                return inner;
            },
            .l_bracket => {
                // Array literal: [_]T{ 1, 2, 3 } or .{ 1, 2, 3 }
                return self.parseArrayLiteral();
            },
            else => {
                // Try identifier for builtins that start with @
                return error.ExpectedExpression;
            },
        }
    }

    fn parseBuiltin(self: *Parser, name: []const u8, pos: u32) ParseError!*Expr {
        // @as(Type, expr)
        if (std.mem.eql(u8, name, "@as")) {
            self.expect(.l_paren);
            const cast_type = try self.parseTypeRef();
            self.expect(.comma);
            const operand = try self.parseExpr();
            self.expect(.r_paren);
            const node = try self.alloc.create(Expr);
            node.* = .{ .kind = .cast_as, .pos = pos, .lhs = operand, .cast_type = cast_type };
            return node;
        }
        // @intCast(expr) — truncation/extension cast to context type
        if (std.mem.eql(u8, name, "@intCast")) {
            self.expect(.l_paren);
            const operand = try self.parseExpr();
            self.expect(.r_paren);
            const node = try self.alloc.create(Expr);
            // cast_as with empty cast_type — codegen will use return type context
            node.* = .{ .kind = .cast_as, .pos = pos, .lhs = operand, .cast_type = .{ .name = "__intcast" } };
            return node;
        }
        // Other builtins: treat as function call with args
        if (self.peek() == .l_paren) {
            self.advance();
            const node = try self.alloc.create(Expr);
            node.* = .{ .kind = .call, .name = name, .pos = pos, .has_args = true };
            node.args = std.ArrayListUnmanaged(*Expr){};
            while (self.peek() != .r_paren) {
                try node.args.append(self.alloc, try self.parseExpr());
                if (self.peek() == .comma) self.advance();
            }
            self.expect(.r_paren);
            return node;
        }
        const node = try self.alloc.create(Expr);
        node.* = .{ .kind = .ident, .name = name, .pos = pos };
        return node;
    }

    fn parseStructLiteral(self: *Parser, name: []const u8, pos: u32) ParseError!*Expr {
        self.expect(.l_brace);
        const node = try self.alloc.create(Expr);
        node.* = .{ .kind = .struct_lit, .name = name, .pos = pos, .has_fields = true };
        node.fields = std.ArrayListUnmanaged(FieldInit){};
        while (self.peek() != .r_brace) {
            if (self.peek() == .dot) {
                self.advance();
                const fname = self.expectIdent();
                self.expect(.equal);
                const val = try self.parseExpr();
                try node.fields.append(self.alloc,.{ .name = fname, .value = val });
            } else {
                // Positional init
                const val = try self.parseExpr();
                try node.fields.append(self.alloc,.{ .name = "", .value = val });
            }
            if (self.peek() == .comma) self.advance();
        }
        self.expect(.r_brace);
        return node;
    }

    fn parseArrayLiteral(self: *Parser) ParseError!*Expr {
        self.expect(.l_bracket);
        const node = try self.alloc.create(Expr);
        node.* = .{ .kind = .array_lit, .has_args = true };
        node.args = std.ArrayListUnmanaged(*Expr){};
        // Skip type info like [_]i32 or [3]i32 for now — just parse elements
        if (self.peek() == .identifier or self.peek() == .int_literal) {
            // Could be [_]T or [N]T — skip to the brace
            self.advance(); // _ or N
            self.expect(.r_bracket);
            _ = try self.parseTypeRef(); // element type
        } else {
            self.expect(.r_bracket);
        }
        self.expect(.l_brace);
        while (self.peek() != .r_brace) {
            try node.args.append(self.alloc,try self.parseExpr());
            if (self.peek() == .comma) self.advance();
        }
        self.expect(.r_brace);
        return node;
    }

    // ===----------------------------------------------------------------------===
    // Helpers
    // ===----------------------------------------------------------------------===

    fn peek(self: *const Parser) TokenKind {
        if (self.pos >= self.tokens.len) return .eof;
        return self.tokens[self.pos].kind;
    }

    fn peekNext(self: *const Parser) TokenKind {
        if (self.pos + 1 >= self.tokens.len) return .eof;
        return self.tokens[self.pos + 1].kind;
    }

    fn current(self: *const Parser) Token {
        if (self.pos >= self.tokens.len)
            return .{ .kind = .eof, .start = @intCast(self.source.len), .end = @intCast(self.source.len) };
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.tokens.len) self.pos += 1;
    }

    fn expect(self: *Parser, kind: TokenKind) void {
        if (self.peek() == kind) {
            self.advance();
        }
        // In production we'd emit a diagnostic, but for now silently skip
    }

    fn expectIdent(self: *Parser) []const u8 {
        if (self.peek() == .identifier) {
            const text = self.tokenText(self.current());
            self.advance();
            return text;
        }
        return "";
    }

    fn tokenText(self: *const Parser, tok: Token) []const u8 {
        return self.source[tok.start..tok.end];
    }

    fn eatSemicolon(self: *Parser) void {
        if (self.peek() == .semicolon) self.advance();
    }
};
