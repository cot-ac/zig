//! Zig Scanner — tokenizes Zig source into a flat token array.
//!
//! Supports the subset of Zig needed for ac feature parity:
//! functions, variables, control flow, structs, arrays, slices,
//! optionals, errors, pointers, enums, switch, test blocks.
//!
//! Reference: Zig lib/std/zig/Tokenizer.zig

const std = @import("std");

pub const TokenKind = enum {
    // Sentinel
    eof,
    invalid,

    // Literals
    identifier,
    int_literal,
    float_literal,
    string_literal,
    true_lit,
    false_lit,

    // Keywords
    kw_fn,
    kw_pub,
    kw_return,
    kw_var,
    kw_const,
    kw_if,
    kw_else,
    kw_while,
    kw_for,
    kw_break,
    kw_continue,
    kw_test,
    kw_null,
    kw_undefined,
    kw_orelse,
    kw_struct,
    kw_enum,
    kw_switch,
    kw_try,
    kw_catch,
    kw_error,
    kw_unreachable,

    // Builtin types
    ty_i8,
    ty_i16,
    ty_i32,
    ty_i64,
    ty_u8,
    ty_u16,
    ty_u32,
    ty_u64,
    ty_usize,
    ty_f32,
    ty_f64,
    ty_bool,
    ty_void,

    // Punctuation
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    comma,
    colon,
    semicolon,
    dot,
    at_sign,

    // Operators
    plus,
    minus,
    star,
    slash,
    percent,
    ampersand,
    pipe,
    caret,
    tilde,
    bang,
    equal,
    less,
    greater,
    question,

    // Multi-char operators
    arrow,       // ->
    fat_arrow,   // =>
    equal_equal, // ==
    bang_equal,  // !=
    less_equal,  // <=
    greater_equal, // >=
    plus_equal,  // +=
    minus_equal, // -=
    star_equal,  // *=
    slash_equal, // /=
    dot_dot,     // ..
    dot_star,    // .*
    dot_question, // .?
    shl,         // <<
    shr,         // >>
    pipe_pipe,   // ||
    ampersand_ampersand, // (not in Zig — use `and`/`or` or keep for compat)
};

pub const Token = struct {
    kind: TokenKind,
    start: u32,
    end: u32,
};

const keywords = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "fn", .kw_fn },
    .{ "pub", .kw_pub },
    .{ "return", .kw_return },
    .{ "var", .kw_var },
    .{ "const", .kw_const },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
    .{ "for", .kw_for },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
    .{ "test", .kw_test },
    .{ "null", .kw_null },
    .{ "undefined", .kw_undefined },
    .{ "orelse", .kw_orelse },
    .{ "struct", .kw_struct },
    .{ "enum", .kw_enum },
    .{ "switch", .kw_switch },
    .{ "try", .kw_try },
    .{ "catch", .kw_catch },
    .{ "error", .kw_error },
    .{ "true", .true_lit },
    .{ "false", .false_lit },
    .{ "unreachable", .kw_unreachable },
    // Builtin types
    .{ "i8", .ty_i8 },
    .{ "i16", .ty_i16 },
    .{ "i32", .ty_i32 },
    .{ "i64", .ty_i64 },
    .{ "u8", .ty_u8 },
    .{ "u16", .ty_u16 },
    .{ "u32", .ty_u32 },
    .{ "u64", .ty_u64 },
    .{ "usize", .ty_usize },
    .{ "f32", .ty_f32 },
    .{ "f64", .ty_f64 },
    .{ "bool", .ty_bool },
    .{ "void", .ty_void },
});

pub const Scanner = struct {
    source: []const u8,
    index: u32 = 0,

    pub fn init(source: []const u8) Scanner {
        return .{ .source = source };
    }

    pub fn next(self: *Scanner) Token {
        self.skipWhitespaceAndComments();
        if (self.index >= self.source.len)
            return .{ .kind = .eof, .start = self.index, .end = self.index };

        const start = self.index;
        const ch = self.source[self.index];

        // String literal
        if (ch == '"') return self.scanString(start);

        // Number
        if (std.ascii.isDigit(ch)) return self.scanNumber(start);

        // Identifier / keyword
        if (std.ascii.isAlphabetic(ch) or ch == '_')
            return self.scanIdentifier(start);

        // Builtin (@as, @import, etc.)
        if (ch == '@') {
            self.index += 1;
            if (self.index < self.source.len and
                (std.ascii.isAlphabetic(self.source[self.index]) or self.source[self.index] == '_'))
            {
                // Scan the builtin name as part of the @ token
                return self.scanIdentifier(start);
            }
            return .{ .kind = .at_sign, .start = start, .end = self.index };
        }

        // Punctuation and operators
        self.index += 1;
        return switch (ch) {
            '(' => .{ .kind = .l_paren, .start = start, .end = self.index },
            ')' => .{ .kind = .r_paren, .start = start, .end = self.index },
            '{' => .{ .kind = .l_brace, .start = start, .end = self.index },
            '}' => .{ .kind = .r_brace, .start = start, .end = self.index },
            '[' => .{ .kind = .l_bracket, .start = start, .end = self.index },
            ']' => .{ .kind = .r_bracket, .start = start, .end = self.index },
            ',' => .{ .kind = .comma, .start = start, .end = self.index },
            ':' => .{ .kind = .colon, .start = start, .end = self.index },
            ';' => .{ .kind = .semicolon, .start = start, .end = self.index },
            '~' => .{ .kind = .tilde, .start = start, .end = self.index },
            '?' => .{ .kind = .question, .start = start, .end = self.index },
            '.' => self.scanDot(start),
            '+' => self.scanTwo(start, '=', .plus_equal, .plus),
            '-' => self.scanMinus(start),
            '*' => self.scanTwo(start, '=', .star_equal, .star),
            '/' => self.scanTwo(start, '=', .slash_equal, .slash),
            '%' => .{ .kind = .percent, .start = start, .end = self.index },
            '&' => self.scanTwo(start, '&', .ampersand_ampersand, .ampersand),
            '|' => self.scanTwo(start, '|', .pipe_pipe, .pipe),
            '^' => .{ .kind = .caret, .start = start, .end = self.index },
            '!' => self.scanTwo(start, '=', .bang_equal, .bang),
            '=' => self.scanEqual(start),
            '<' => self.scanLess(start),
            '>' => self.scanGreater(start),
            else => .{ .kind = .invalid, .start = start, .end = self.index },
        };
    }

    pub fn text(self: *const Scanner, tok: Token) []const u8 {
        return self.source[tok.start..tok.end];
    }

    fn skipWhitespaceAndComments(self: *Scanner) void {
        while (self.index < self.source.len) {
            const ch = self.source[self.index];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                self.index += 1;
            } else if (ch == '/' and self.index + 1 < self.source.len and
                self.source[self.index + 1] == '/')
            {
                // Line comment — skip to end of line
                while (self.index < self.source.len and self.source[self.index] != '\n')
                    self.index += 1;
            } else break;
        }
    }

    fn scanString(self: *Scanner, start: u32) Token {
        self.index += 1; // skip opening "
        while (self.index < self.source.len and self.source[self.index] != '"') {
            if (self.source[self.index] == '\\') self.index += 1; // skip escape
            self.index += 1;
        }
        if (self.index < self.source.len) self.index += 1; // skip closing "
        return .{ .kind = .string_literal, .start = start, .end = self.index };
    }

    fn scanNumber(self: *Scanner, start: u32) Token {
        var is_float = false;
        while (self.index < self.source.len and
            (std.ascii.isDigit(self.source[self.index]) or self.source[self.index] == '_'))
            self.index += 1;

        // Check for decimal point (but not ..)
        if (self.index < self.source.len and self.source[self.index] == '.' and
            (self.index + 1 >= self.source.len or self.source[self.index + 1] != '.'))
        {
            is_float = true;
            self.index += 1;
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index]))
                self.index += 1;
        }

        return .{
            .kind = if (is_float) .float_literal else .int_literal,
            .start = start,
            .end = self.index,
        };
    }

    fn scanIdentifier(self: *Scanner, start: u32) Token {
        // If start is '@', skip it for the identifier text but include in token span
        const ident_start = if (start < self.source.len and self.source[start] == '@')
            start + 1
        else
            start;
        _ = ident_start;

        while (self.index < self.source.len and
            (std.ascii.isAlphanumeric(self.source[self.index]) or self.source[self.index] == '_'))
            self.index += 1;

        const ident_text = self.source[if (self.source[start] == '@') start + 1 else start..self.index];
        const kind = keywords.get(ident_text) orelse .identifier;
        return .{ .kind = kind, .start = start, .end = self.index };
    }

    fn scanDot(self: *Scanner, start: u32) Token {
        if (self.index < self.source.len) {
            switch (self.source[self.index]) {
                '.' => {
                    self.index += 1;
                    return .{ .kind = .dot_dot, .start = start, .end = self.index };
                },
                '*' => {
                    self.index += 1;
                    return .{ .kind = .dot_star, .start = start, .end = self.index };
                },
                '?' => {
                    self.index += 1;
                    return .{ .kind = .dot_question, .start = start, .end = self.index };
                },
                else => {},
            }
        }
        return .{ .kind = .dot, .start = start, .end = self.index };
    }

    fn scanTwo(self: *Scanner, start: u32, expected: u8, matched: TokenKind, fallback: TokenKind) Token {
        if (self.index < self.source.len and self.source[self.index] == expected) {
            self.index += 1;
            return .{ .kind = matched, .start = start, .end = self.index };
        }
        return .{ .kind = fallback, .start = start, .end = self.index };
    }

    fn scanMinus(self: *Scanner, start: u32) Token {
        if (self.index < self.source.len) {
            if (self.source[self.index] == '>') {
                self.index += 1;
                return .{ .kind = .arrow, .start = start, .end = self.index };
            }
            if (self.source[self.index] == '=') {
                self.index += 1;
                return .{ .kind = .minus_equal, .start = start, .end = self.index };
            }
        }
        return .{ .kind = .minus, .start = start, .end = self.index };
    }

    fn scanEqual(self: *Scanner, start: u32) Token {
        if (self.index < self.source.len) {
            if (self.source[self.index] == '=') {
                self.index += 1;
                return .{ .kind = .equal_equal, .start = start, .end = self.index };
            }
            if (self.source[self.index] == '>') {
                self.index += 1;
                return .{ .kind = .fat_arrow, .start = start, .end = self.index };
            }
        }
        return .{ .kind = .equal, .start = start, .end = self.index };
    }

    fn scanLess(self: *Scanner, start: u32) Token {
        if (self.index < self.source.len) {
            if (self.source[self.index] == '=') {
                self.index += 1;
                return .{ .kind = .less_equal, .start = start, .end = self.index };
            }
            if (self.source[self.index] == '<') {
                self.index += 1;
                return .{ .kind = .shl, .start = start, .end = self.index };
            }
        }
        return .{ .kind = .less, .start = start, .end = self.index };
    }

    fn scanGreater(self: *Scanner, start: u32) Token {
        if (self.index < self.source.len) {
            if (self.source[self.index] == '=') {
                self.index += 1;
                return .{ .kind = .greater_equal, .start = start, .end = self.index };
            }
            if (self.source[self.index] == '>') {
                self.index += 1;
                return .{ .kind = .shr, .start = start, .end = self.index };
            }
        }
        return .{ .kind = .greater, .start = start, .end = self.index };
    }
};

/// Scan all tokens from source into an array.
pub fn scanAll(allocator: std.mem.Allocator, source: []const u8) !std.ArrayListUnmanaged(Token) {
    var s = Scanner.init(source);
    var tokens = std.ArrayListUnmanaged(Token){};
    while (true) {
        const tok = s.next();
        try tokens.append(allocator, tok);
        if (tok.kind == .eof) break;
    }
    return tokens;
}
