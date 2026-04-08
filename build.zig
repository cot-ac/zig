const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Paths — configurable via build options, defaults to sibling dirs.
    const cot_dev_dir = b.option(
        []const u8,
        "cot-dev",
        "Path to cot-dev source",
    ) orelse "../cot-dev";
    const cot_dev_build = b.option(
        []const u8,
        "cot-dev-build",
        "Path to cot-dev build",
    ) orelse "../cot-dev/build";
    const core_build = b.option(
        []const u8,
        "core-build",
        "Path to core constructs build",
    ) orelse "../core/build";
    const llvm_dir = b.option(
        []const u8,
        "llvm-dir",
        "Path to LLVM/MLIR install prefix",
    ) orelse "/opt/homebrew/opt/llvm@20";

    // The cot library module — importable as @import("cot").
    const cot_mod = b.addModule("cot", .{
        .root_source_file = b.path("lib/cot.zig"),
        .target = target,
        .optimize = optimize,
    });

    // C API header include paths for the module.
    cot_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ cot_dev_dir, "include" }) });
    cot_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ llvm_dir, "include" }) });

    // --- Binding test (standalone executable) ---
    const example_mod = b.createModule(.{
        .root_source_file = b.path("test/binding_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("cot", cot_mod);
    linkCotLibraries(b, example_mod, cot_dev_build, core_build, llvm_dir);

    const example = b.addExecutable(.{
        .name = "cot-zig-example",
        .root_module = example_mod,
    });

    b.installArtifact(example);

    // --- czig compiler ---
    const compiler_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cot", .module = cot_mod },
            .{ .name = "scanner.zig", .module = b.createModule(.{
                .root_source_file = b.path("src/scanner.zig"),
                .target = target,
                .optimize = optimize,
            }) },
        },
    });
    const scanner_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_mod.addImport("scanner", scanner_mod);
    const codegen_mod = b.createModule(.{
        .root_source_file = b.path("src/codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    codegen_mod.addImport("cot", cot_mod);
    codegen_mod.addImport("parser", parser_mod);
    codegen_mod.addImport("scanner", scanner_mod);

    const czig_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    czig_mod.addImport("cot", cot_mod);
    czig_mod.addImport("scanner", scanner_mod);
    czig_mod.addImport("parser", parser_mod);
    czig_mod.addImport("codegen", codegen_mod);
    linkCotLibraries(b, czig_mod, cot_dev_build, core_build, llvm_dir);
    _ = compiler_mod;

    const czig = b.addExecutable(.{
        .name = "czig",
        .root_module = czig_mod,
    });
    b.installArtifact(czig);

    // --- Sema test (Zig-written SemanticAnalysis) ---
    const sema_mod = b.createModule(.{
        .root_source_file = b.path("test/sema_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sema_mod.addImport("cot", cot_mod);
    linkCotLibraries(b, sema_mod, cot_dev_build, core_build, llvm_dir);

    const sema_exe = b.addExecutable(.{
        .name = "cot-zig-sema-test",
        .root_module = sema_mod,
    });
    b.installArtifact(sema_exe);

    const run_example = b.addRunArtifact(example);
    const run_sema = b.addRunArtifact(sema_exe);
    const test_step = b.step("test", "Run binding tests");
    test_step.dependOn(&run_example.step);
    test_step.dependOn(&run_sema.step);
}

fn linkCotLibraries(
    b: *std.Build,
    mod: *std.Build.Module,
    cot_dev_build: []const u8,
    core_build: []const u8,
    llvm_dir: []const u8,
) void {
    // COT framework libraries
    const cot_libs = [_]struct { dir: []const u8, name: []const u8 }{
        .{ .dir = "c-api", .name = "COTCApi" },
        .{ .dir = "lib/Pipeline", .name = "COTPipeline" },
        .{ .dir = "lib/Construct", .name = "COTConstruct" },
        .{ .dir = "lib/CIR", .name = "CIR" },
        .{ .dir = "runtime", .name = "cir_arc" },
    };
    for (cot_libs) |lib| {
        mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ cot_dev_build, lib.dir, b.fmt("lib{s}.a", .{lib.name}) }) });
    }

    // Core construct libraries — force-load via linker flag to prevent
    // dead-stripping of static constructors used for construct registration.
    const constructs = [_]struct { dir: []const u8, name: []const u8 }{
        .{ .dir = "arith/lib", .name = "CotArith" },
        .{ .dir = "memory/lib", .name = "CotMemory" },
        .{ .dir = "flow/lib", .name = "CotFlow" },
        .{ .dir = "structs/lib", .name = "CotStructs" },
        .{ .dir = "arrays/lib", .name = "CotArrays" },
        .{ .dir = "slices/lib", .name = "CotSlices" },
        .{ .dir = "optionals/lib", .name = "CotOptionals" },
        .{ .dir = "errors/lib", .name = "CotErrors" },
        .{ .dir = "test/lib", .name = "CotTest" },
        .{ .dir = "enums/lib", .name = "CotEnums" },
        .{ .dir = "unions/lib", .name = "CotUnions" },
        .{ .dir = "generics/lib", .name = "CotGenerics" },
        .{ .dir = "traits/lib", .name = "CotTraits" },
        .{ .dir = "vwt/lib", .name = "CotVWT" },
    };
    for (constructs) |cn| {
        const path = b.pathJoin(&.{ core_build, cn.dir, b.fmt("lib{s}.a", .{cn.name}) });
        mod.addObjectFile(.{ .cwd_relative = path });
    }

    // MLIR static libraries
    const mlir_lib_dir = b.pathJoin(&.{ llvm_dir, "lib" });
    const mlir_libs = [_][]const u8{
        "MLIRCAPIIR",           "MLIRCAPITransforms",
        "MLIRIR",               "MLIRPass",
        "MLIRSupport",          "MLIRDialect",
        "MLIRParser",           "MLIRAsmParser",
        "MLIRBytecodeReader",   "MLIRBytecodeWriter",
        "MLIRBytecodeOpInterface",
        "MLIRRewrite",          "MLIRRewritePDL",
        "MLIRPDLDialect",       "MLIRPDLInterpDialect",
        "MLIRPDLToPDLInterp",
        "MLIRTransforms",       "MLIRTransformUtils",
        "MLIRArithDialect",     "MLIRArithToLLVM",
        "MLIRArithAttrToLLVMConversion",
        "MLIRArithTransforms",  "MLIRArithUtils",
        "MLIRFuncDialect",      "MLIRFuncToLLVM",
        "MLIRFuncTransforms",
        "MLIRLLVMDialect",      "MLIRLLVMCommonConversion",
        "MLIRLLVMIRTransforms",
        "MLIRLLVMToLLVMIRTranslation",
        "MLIRBuiltinToLLVMIRTranslation",
        "MLIRTargetLLVMIRExport", "MLIRTranslateLib",
        "MLIRReconcileUnrealizedCasts",
        "MLIRControlFlowDialect", "MLIRControlFlowToLLVM",
        "MLIRControlFlowInterfaces",
        "MLIRCallInterfaces",   "MLIRCastInterfaces",
        "MLIRFunctionInterfaces",
        "MLIRInferTypeOpInterface",
        "MLIRSideEffectInterfaces",
        "MLIRDataLayoutInterfaces",
        "MLIRMemorySlotInterfaces",
        "MLIRInferIntRangeInterface",
        "MLIRInferIntRangeCommon",
        "MLIRLoopLikeInterface", "MLIRViewLikeInterface",
        "MLIRShapedOpInterfaces",
        "MLIRDestinationStyleOpInterface",
        "MLIRRuntimeVerifiableOpInterface",
        "MLIRMaskableOpInterface",
        "MLIRMaskingOpInterface",
        "MLIRSubsetOpInterface",
        "MLIRValueBoundsOpInterface",
        "MLIRPresburger",       "MLIRAnalysis",
        "MLIRDialectUtils",     "MLIRDLTIDialect",
        "MLIRMemRefDialect",    "MLIRSCFDialect",
        "MLIRAffineDialect",    "MLIRComplexDialect",
        "MLIRTensorDialect",    "MLIRVectorDialect",
        "MLIRVectorInterfaces",
        "MLIRParallelCombiningOpInterface",
        "MLIRSparseTensorDialect",
        "MLIRBufferizationDialect",
        "MLIRBufferizationTransforms",
        "MLIRUBDialect",        "MLIRNVVMDialect",
    };
    for (mlir_libs) |lib| {
        mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ mlir_lib_dir, b.fmt("lib{s}.a", .{lib}) }) });
    }

    // LLVM shared library
    mod.addLibraryPath(.{ .cwd_relative = mlir_lib_dir });
    mod.linkSystemLibrary("LLVM", .{});

    // System libraries required by LLVM/MLIR on macOS
    mod.linkSystemLibrary("c++", .{});
    mod.linkSystemLibrary("z", .{});
    mod.linkSystemLibrary("curses", .{});
    mod.linkFramework("CoreFoundation", .{});
}
