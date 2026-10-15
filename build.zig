const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Package version, kept in step with build.zig.zon; reported by plugin --about.
    const version = "0.1.0";

    // External dependencies
    const pb_dep = b.dependency("printable_binary", .{
        .target = target,
        .optimize = optimize,
    });
    const pb_mod = pb_dep.module("printable_binary");

    // zlib for the PDF codec's FlateDecode (zlib license, allyourcodebase/zlib)
    const zlib_dep = b.dependency("zlib", .{
        .target = target,
        .optimize = optimize,
    });
    const zlib_lib = zlib_dep.artifact("z");

    // Core module: the C0 format itself, pure Zig with no C dependencies
    const core_mod = b.addModule("c0_core", .{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "printable_binary", .module = pb_mod },
        },
    });

    // Vendored compression libraries used only by the BG3 codec plugin
    const lz4_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "lz4",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    lz4_lib.root_module.addCSourceFiles(.{
        .root = b.path("codecs/vendor/lz4"),
        .files = &.{ "lz4.c", "lz4frame.c", "xxhash.c", "lz4hc.c" },
        .flags = &.{"-std=c99"},
    });
    const zstd_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zstd",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    zstd_lib.root_module.addCSourceFiles(.{
        .root = b.path("codecs/vendor/zstd"),
        .files = &.{"zstd.c"},
        .flags = &.{"-std=c99"},
    });

    // Codec module: the pure logic of every codec. It carries the C headers its @cImport
    // calls need; each consumer links only the C libraries for the codecs it references.
    const codec_mod = b.addModule("c0_codec", .{
        .root_source_file = b.path("codecs/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c0_core", .module = core_mod },
        },
    });
    codec_mod.addIncludePath(b.path("codecs/vendor/lz4"));
    codec_mod.addIncludePath(b.path("codecs/vendor/zstd"));
    codec_mod.addIncludePath(zlib_lib.getEmittedIncludeTree());

    // Plugin adapter: wraps a codec type in the c0_plugin.h C ABI
    const plugin_mod = b.createModule(.{
        .root_source_file = b.path("codecs/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c0_core", .module = core_mod },
            .{ .name = "c0_codec", .module = codec_mod },
        },
    });

    // Static library (libc0.a): the C0 format only. Codecs live in plugin executables.
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

    // C CLI executable; reaches codecs only through the c0-codec/1 plugin protocol
    const cli = b.addExecutable(.{
        .name = "c0",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    cli.root_module.addCSourceFiles(.{
        .files = &.{ "cli/main.c", "cli/codec_host.c" },
        .flags = &.{ "-std=c99", "-Wall", "-Wextra" },
    });
    cli.root_module.addIncludePath(b.path("ffi"));
    cli.root_module.linkLibrary(lib);
    b.installArtifact(cli);

    // Codec plugin executables (c0-codec-<name>): the shared C host codecs/plugin_main.c
    // performs all I/O and calls the codec's Zig library through codecs/c0_plugin.h.
    const PluginSpec = struct { name: []const u8, lz4_zstd: bool = false, zlib: bool = false };
    const plugin_specs = [_]PluginSpec{
        .{ .name = "png" },
        .{ .name = "bg3", .lz4_zstd = true },
        .{ .name = "json" },
        .{ .name = "jpeg" },
        .{ .name = "tiff" },
        .{ .name = "pdf", .zlib = true },
    };
    for (plugin_specs) |spec| {
        const codec_lib = b.addLibrary(.{
            .linkage = .static,
            .name = b.fmt("c0_codec_{s}", .{spec.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("codecs/plugins/{s}.zig", .{spec.name})),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "c0_plugin", .module = plugin_mod },
                    .{ .name = "c0_codec", .module = codec_mod },
                },
            }),
        });
        const plugin_exe = b.addExecutable(.{
            .name = b.fmt("c0-codec-{s}", .{spec.name}),
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        plugin_exe.root_module.addCSourceFile(.{
            .file = b.path("codecs/plugin_main.c"),
            .flags = &.{
                "-std=c99",                                         "-Wall", "-Wextra",
                b.fmt("-DC0_PLUGIN_NAME=\"{s}\"", .{spec.name}), "-DC0_VERSION=\"" ++ version ++ "\"",
            },
        });
        plugin_exe.root_module.addIncludePath(b.path("codecs"));
        plugin_exe.root_module.linkLibrary(codec_lib);
        if (spec.lz4_zstd) {
            plugin_exe.root_module.linkLibrary(lz4_lib);
            plugin_exe.root_module.linkLibrary(zstd_lib);
        }
        if (spec.zlib) plugin_exe.root_module.linkLibrary(zlib_lib);
        b.installArtifact(plugin_exe);
    }

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

    // Codec tests: every codec, so every codec's C library
    const codec_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("codecs/mod.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "c0_core", .module = core_mod },
            },
        }),
    });
    codec_tests.root_module.addIncludePath(b.path("codecs/vendor/lz4"));
    codec_tests.root_module.addIncludePath(b.path("codecs/vendor/zstd"));
    codec_tests.root_module.addIncludePath(zlib_lib.getEmittedIncludeTree());
    codec_tests.root_module.linkLibrary(lz4_lib);
    codec_tests.root_module.linkLibrary(zstd_lib);
    codec_tests.root_module.linkLibrary(zlib_lib);

    // Plugin adapter tests
    const plugin_tests = b.addTest(.{ .root_module = plugin_mod });

    const run_core_tests = b.addRunArtifact(core_tests);
    const run_ffi_tests = b.addRunArtifact(ffi_tests);
    const run_codec_tests = b.addRunArtifact(codec_tests);
    const run_plugin_tests = b.addRunArtifact(plugin_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_ffi_tests.step);
    test_step.dependOn(&run_codec_tests.step);
    test_step.dependOn(&run_plugin_tests.step);

    // Lets CI build test binaries without running them (so patchelf can fix
    // up the FHS dynamic-linker path that Zig bakes into libc-linked exes
    // which doesn't exist in the Nix build sandbox).
    const test_compile_step = b.step("test-compile", "Compile test binaries without running them");
    test_compile_step.dependOn(&b.addInstallArtifact(core_tests, .{
        .dest_dir = .{ .override = .{ .custom = "test-bins" } },
        .dest_sub_path = "core_tests",
    }).step);
    test_compile_step.dependOn(&b.addInstallArtifact(ffi_tests, .{
        .dest_dir = .{ .override = .{ .custom = "test-bins" } },
        .dest_sub_path = "ffi_tests",
    }).step);
    test_compile_step.dependOn(&b.addInstallArtifact(codec_tests, .{
        .dest_dir = .{ .override = .{ .custom = "test-bins" } },
        .dest_sub_path = "codec_tests",
    }).step);
    test_compile_step.dependOn(&b.addInstallArtifact(plugin_tests, .{
        .dest_dir = .{ .override = .{ .custom = "test-bins" } },
        .dest_sub_path = "plugin_tests",
    }).step);


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

    // Benchmark adapter for the performance-profile engine (./cg, ./mg, ./bm). It imports the
    // core directly because the C ABI takes no allocator and the memory gate must count every
    // allocation; the C CLI remains the FFI's dogfooding consumer. Not part of the default install.
    const bench = b.addExecutable(.{
        .name = "c0-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/benchmark/c0_bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "c0_core", .module = core_mod },
            },
        }),
    });
    const bench_step = b.step("bench", "Build the c0-bench benchmark adapter");
    bench_step.dependOn(&b.addInstallArtifact(bench, .{}).step);
    const bench_tests = b.addTest(.{ .root_module = bench.root_module });
    test_step.dependOn(&b.addRunArtifact(bench_tests).step);
    test_compile_step.dependOn(&b.addInstallArtifact(bench_tests, .{
        .dest_dir = .{ .override = .{ .custom = "test-bins" } },
        .dest_sub_path = "bench_tests",
    }).step);
}
