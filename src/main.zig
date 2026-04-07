//! czig — Zig compiler targeting COT/CIR.
//!
//! Compiles Zig source files to native binaries via:
//!   Zig source → scan → parse → codegen (CIR) → pipeline → binary
//!
//! Usage:
//!   czig build input.zig [-o output]
//!   czig emit-cir input.zig
//!   czig input.zig              (default: build)

const std = @import("std");
const cot = @import("cot");
const Scanner = @import("scanner").Scanner;
const parser = @import("parser");
const Codegen = @import("codegen").Codegen;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        std.debug.print("usage: czig [build|emit-cir] <input.zig> [-o output]\n", .{});
        std.process.exit(1);
    }

    var input_file: ?[]const u8 = null;
    var output_file: []const u8 = "a.out";
    var mode: enum { build, emit_cir } = .build;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "build")) {
            mode = .build;
        } else if (std.mem.eql(u8, args[i], "emit-cir")) {
            mode = .emit_cir;
        } else if (std.mem.eql(u8, args[i], "-o")) {
            i += 1;
            if (i < args.len) output_file = args[i];
        } else {
            input_file = args[i];
        }
    }

    const path = input_file orelse {
        std.debug.print("error: no input file\n", .{});
        std.process.exit(1);
    };

    // Read source file
    const source = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch |err| {
        std.debug.print("error: cannot read '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer alloc.free(source);

    // Scan
    var scan = Scanner.init(source);
    var tokens = std.ArrayListUnmanaged(@import("scanner").Token){};
    defer tokens.deinit(alloc);
    while (true) {
        const tok = scan.next();
        try tokens.append(alloc, tok);
        if (tok.kind == .eof) break;
    }

    // Parse
    var p = parser.Parser.init(alloc, source, tokens.items);
    const mod = p.parseModule() catch |err| {
        std.debug.print("error: parse failed: {}\n", .{err});
        std.process.exit(1);
    };

    // Codegen
    var gen = Codegen.init(alloc, @ptrCast(path.ptr));
    errdefer gen.deinit();

    gen.emit(&mod) catch |err| {
        std.debug.print("error: codegen failed: {}\n", .{err});
        std.process.exit(1);
    };

    // Pipeline
    switch (mode) {
        .emit_cir => {
            // Print CIR to stdout
            const module_op = gen.module.getOperation();
            @import("cot").c.cir.mlirOperationDump(module_op.raw);
        },
        .build => {
            const pipe = cot.pipeline.Pipeline.create(gen.ctx);
            defer pipe.destroy();
            pipe.emitBinary(gen.module, @ptrCast(output_file.ptr)) catch {
                std.debug.print("error: pipeline failed\n", .{});
                std.process.exit(1);
            };
        },
    }
}
