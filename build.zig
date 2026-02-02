const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	// Core module
	const core_mod = b.addModule("c0_core", .{
		.root_source_file = b.path("src/core/mod.zig"),
		.target = target,
		.optimize = optimize,
	});

	// Tests
	const core_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/core/mod.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});

	const run_core_tests = b.addRunArtifact(core_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_core_tests.step);

	_ = core_mod;
}
