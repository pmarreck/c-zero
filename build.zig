const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // External dependency
    const pb_dep = b.dependency("printable_binary", .{
        .target = target,
        .optimize = optimize,
    });
    const pb_mod = pb_dep.module("printable_binary");

    // Core module
    const core_mod = b.addModule("c0_core", .{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "printable_binary", .module = pb_mod },
        },
    });

    // FFI module
    const ffi_mod = b.addModule("c0_ffi", .{
        .root_source_file = b.path("ffi/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c0_core", .module = core_mod },
        },
    });

    // Static library (libc0.a)
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "c0",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ffi/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c0_core", .module = core_mod },
            },
        }),
    });
    lib.installHeader(b.path("ffi/c0.h"), "c0.h");
    b.installArtifact(lib);

    // C CLI executable
    const cli = b.addExecutable(.{
        .name = "c0",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    cli.addCSourceFile(.{
        .file = b.path("cli/main.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra" },
    });
    cli.addIncludePath(b.path("ffi"));
    cli.linkLibrary(lib);
    b.installArtifact(cli);

    // Core tests
    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/mod.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "printable_binary", .module = pb_mod },
            },
        }),
    });

    // FFI tests
    const ffi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("ffi/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c0_core", .module = core_mod },
            },
        }),
    });

    const run_core_tests = b.addRunArtifact(core_tests);
    const run_ffi_tests = b.addRunArtifact(ffi_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_ffi_tests.step);

    _ = ffi_mod;

    // JSON demo executable
    const json_demo = b.addExecutable(.{
        .name = "json_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/json_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c0_core", .module = core_mod },
            },
        }),
    });
    b.installArtifact(json_demo);

    const run_json_demo = b.addRunArtifact(json_demo);
    const run_demo_step = b.step("run-json-demo", "Run the JSON demo");
    run_demo_step.dependOn(&run_json_demo.step);

    // JSON demo tests
    const json_demo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/json_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c0_core", .module = core_mod },
            },
        }),
    });
    const run_json_demo_tests = b.addRunArtifact(json_demo_tests);
    test_step.dependOn(&run_json_demo_tests.step);

    // Binary demo executable
    const binary_demo = b.addExecutable(.{
        .name = "binary_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/binary_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c0_core", .module = core_mod },
            },
        }),
    });
    b.installArtifact(binary_demo);

    const run_binary_demo = b.addRunArtifact(binary_demo);
    const run_binary_demo_step = b.step("run-binary-demo", "Run the binary data demo");
    run_binary_demo_step.dependOn(&run_binary_demo.step);

    // Binary demo tests
    const binary_demo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/binary_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c0_core", .module = core_mod },
            },
        }),
    });
    const run_binary_demo_tests = b.addRunArtifact(binary_demo_tests);
    test_step.dependOn(&run_binary_demo_tests.step);

    // PNG demo executable
    const png_demo = b.addExecutable(.{
        .name = "png_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/png_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c0_core", .module = core_mod },
            },
        }),
    });
    b.installArtifact(png_demo);

    const run_png_demo = b.addRunArtifact(png_demo);
    if (b.args) |args| {
        run_png_demo.addArgs(args);
    }
    const run_png_demo_step = b.step("run-png-demo", "Run the PNG destructuring demo");
    run_png_demo_step.dependOn(&run_png_demo.step);

    // PNG demo tests
    const png_demo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/png_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c0_core", .module = core_mod },
            },
        }),
    });
    const run_png_demo_tests = b.addRunArtifact(png_demo_tests);
    test_step.dependOn(&run_png_demo_tests.step);
}
