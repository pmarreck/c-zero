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
}
