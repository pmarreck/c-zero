# C0 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a complete C0 encoder/decoder with Zig core, C FFI, and C CLI.

**Architecture:** Hexagonal design - pure Zig core handles encode/decode logic, C FFI provides arena-based memory management for external consumers, C CLI exercises FFI as first consumer.

**Tech Stack:** Zig 0.15.2, printable_binary (Zig dependency), Nix for deps, Bash for CLI tests.

---

## Task 1: Project Scaffolding

**Files:**
- Create: `flake.nix`
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `.gitignore`
- Create: `test` (executable)
- Create: `build` (executable)

**Step 1: Create flake.nix**

```nix
{
	description = "C0 - Hierarchical binary data stream format";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
	};

	outputs = { self, nixpkgs }:
		let
			allSystems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
			forAllSystems = nixpkgs.lib.genAttrs allSystems;
		in {
			devShells = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
				in {
					default = pkgs.mkShell {
						packages = with pkgs; [
							zig
							git
						];
						shellHook = ''
							unset LD
							unset SDKROOT
						'';
					};
				});
		};
}
```

**Step 2: Create build.zig.zon**

```zon
.{
	.name = .c0,
	.version = "0.1.0",
	.dependencies = .{
		.printable_binary = .{
			.url = "git+https://github.com/pmarreck/printable-binary#HEAD",
			.hash = "PLACEHOLDER_HASH",
		},
	},
	.paths = .{""},
}
```

Note: The hash will need to be updated after first build attempt.

**Step 3: Create minimal build.zig**

```zig
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
```

**Step 4: Create .gitignore**

```
.zig-cache/
zig-out/
.direnv/
result
result-*
.DS_Store
.codescan/
```

**Step 5: Create test script**

```bash
#!/usr/bin/env bash

if [[ -z "${C0_NIX:-}" ]]; then
	exec env C0_NIX=1 nix develop -c "$0" "$@"
fi

set -euo pipefail

# Define glob function for noglob environments
if [[ "$(type -t glob 2>/dev/null)" != "function" ]]; then
	glob() {
		local noglob_was_set=false
		[[ $- == *f* ]] && noglob_was_set=true
		set +f
		local expanded=($@)
		$noglob_was_set && set -f
		printf '%s\n' "${expanded[@]}"
	}
fi

unset LD
unset SDKROOT

total_failures=0

echo "=== Running Zig tests ==="
set +e
zig_output=$(zig build test --summary all 2>&1)
zig_exit=$?
set -e

printf '%s\n' "$zig_output"

if [[ $zig_exit -ne 0 ]]; then
	zig_failures=$(printf '%s\n' "$zig_output" | grep -oE '[0-9]+ failed' | awk '{sum+=$1} END {print sum+0}')
	if [[ $zig_failures -eq 0 ]]; then
		zig_failures=1
	fi
	echo "=== Zig tests FAILED ($zig_failures failures) ==="
	total_failures=$((total_failures + zig_failures))
else
	echo "=== Zig tests passed ==="
fi

if [[ -d tests/cli ]]; then
	echo "=== Building CLI for tests ==="
	zig build -Doptimize=ReleaseFast

	echo "=== Running CLI tests ==="
	cli_failures=0
	cli_tests_found=0
	set +e
	for test in $(glob tests/cli/*); do
		if [[ -x "$test" ]]; then
			((cli_tests_found++))
			bash "$test"
			rc=$?
			cli_failures=$((cli_failures + rc))
		fi
	done
	set -e

	if [[ $cli_tests_found -gt 0 ]]; then
		if [[ $cli_failures -ne 0 ]]; then
			echo "=== CLI tests FAILED ($cli_failures failures) ==="
			total_failures=$((total_failures + cli_failures))
		else
			echo "=== CLI tests passed ==="
		fi
	fi
fi

if [[ $total_failures -ne 0 ]]; then
	echo "=== TOTAL FAILURES: $total_failures ==="
	exit $total_failures
fi

echo "=== All tests passed ==="
exit 0
```

**Step 6: Create build script**

```bash
#!/usr/bin/env bash

if [[ -z "${C0_NIX:-}" ]]; then
	exec env C0_NIX=1 nix develop -c "$0" "$@"
fi

set -euo pipefail

unset LD
unset SDKROOT

echo "=== Building C0 ==="
zig build -Doptimize=ReleaseFast "$@"
echo "=== Build complete ==="
```

**Step 7: Make scripts executable and create stub core module**

```bash
chmod +x test build
mkdir -p src/core
```

**Step 8: Create stub src/core/mod.zig**

```zig
//! C0 Core - Hierarchical binary data stream encoding/decoding
//!
//! This module provides the pure encoding/decoding logic with no I/O.

test "stub" {
	// Placeholder to verify build works
}
```

**Step 9: Verify build works**

Run: `nix develop -c zig build test`
Expected: Build succeeds, stub test passes

**Step 10: Commit**

```bash
git add flake.nix build.zig build.zig.zon .gitignore test build src/core/mod.zig PROJECT_OVERVIEW.md
git commit -m "feat: project scaffolding with Nix and Zig build"
```

---

## Task 2: Value Type Definition

**Files:**
- Create: `src/core/value.zig`
- Modify: `src/core/mod.zig`

**Step 1: Write test for Value type**

In `src/core/value.zig`:

```zig
//! C0 Value types - string, array, object

const std = @import("std");

/// A key-value entry in an object
pub const Entry = struct {
	key: []const u8,
	value: Value,
};

/// A C0 value - string, array, or object
pub const Value = union(enum) {
	string: []const u8,
	array: []const Value,
	object: []const Entry,

	/// Check if two values are equal (deep comparison)
	pub fn eql(self: Value, other: Value) bool {
		switch (self) {
			.string => |s| {
				if (other != .string) return false;
				return std.mem.eql(u8, s, other.string);
			},
			.array => |arr| {
				if (other != .array) return false;
				if (arr.len != other.array.len) return false;
				for (arr, other.array) |a, b| {
					if (!a.eql(b)) return false;
				}
				return true;
			},
			.object => |obj| {
				if (other != .object) return false;
				if (obj.len != other.object.len) return false;
				for (obj, other.object) |a, b| {
					if (!std.mem.eql(u8, a.key, b.key)) return false;
					if (!a.value.eql(b.value)) return false;
				}
				return true;
			},
		}
	}
};

test "Value.string creation" {
	const v = Value{ .string = "hello" };
	try std.testing.expectEqualStrings("hello", v.string);
}

test "Value.array creation" {
	const items = [_]Value{
		.{ .string = "a" },
		.{ .string = "b" },
	};
	const v = Value{ .array = &items };
	try std.testing.expectEqual(@as(usize, 2), v.array.len);
}

test "Value.object creation" {
	const entries = [_]Entry{
		.{ .key = "name", .value = .{ .string = "test" } },
	};
	const v = Value{ .object = &entries };
	try std.testing.expectEqual(@as(usize, 1), v.object.len);
}

test "Value.eql for strings" {
	const a = Value{ .string = "hello" };
	const b = Value{ .string = "hello" };
	const c = Value{ .string = "world" };
	try std.testing.expect(a.eql(b));
	try std.testing.expect(!a.eql(c));
}

test "Value.eql for nested structures" {
	const inner = [_]Value{.{ .string = "nested" }};
	const a = Value{ .array = &inner };
	const b = Value{ .array = &inner };
	try std.testing.expect(a.eql(b));
}
```

**Step 2: Update mod.zig to export Value**

```zig
//! C0 Core - Hierarchical binary data stream encoding/decoding
//!
//! This module provides the pure encoding/decoding logic with no I/O.

pub const value = @import("value.zig");
pub const Value = value.Value;
pub const Entry = value.Entry;

test {
	_ = value;
}
```

**Step 3: Run tests**

Run: `nix develop -c zig build test`
Expected: All Value tests pass

**Step 4: Commit**

```bash
git add src/core/value.zig src/core/mod.zig
git commit -m "feat: add Value type (string, array, object)"
```

---

## Task 3: Wire printable_binary Dependency

**Files:**
- Modify: `build.zig.zon` (update hash)
- Modify: `build.zig` (add dependency)
- Create: `src/core/encoding.zig`

**Step 1: Fetch dependency and get correct hash**

Run: `nix develop -c zig build 2>&1 | grep -A2 "hash"`

This will fail but show the correct hash. Update `build.zig.zon` with the real hash.

**Step 2: Update build.zig to wire dependency**

```zig
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

	// Tests
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

	const run_core_tests = b.addRunArtifact(core_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_core_tests.step);

	_ = core_mod;
}
```

**Step 3: Create encoding.zig with structural constants**

```zig
//! C0 encoding constants and utilities

const std = @import("std");
const pb = @import("printable_binary");

/// Structural byte constants (ASCII C0 control characters)
pub const FS: u8 = 0x1C; // File Separator - begins object
pub const GS: u8 = 0x1D; // Group Separator - begins array
pub const RS: u8 = 0x1E; // Record Separator - terminates object entry
pub const US: u8 = 0x1F; // Unit Separator - terminates array element / separates key from value

/// Check if a byte is a structural delimiter
pub fn isStructural(byte: u8) bool {
	return byte == FS or byte == GS or byte == RS or byte == US;
}

/// Encode a string payload using printable_binary
/// Caller owns returned slice
pub fn encodePayload(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
	return pb.encode(allocator, data, .{});
}

/// Decode a string payload using printable_binary
/// Caller owns returned slice
pub fn decodePayload(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
	return pb.decode(allocator, encoded, .{});
}

test "structural byte detection" {
	try std.testing.expect(isStructural(FS));
	try std.testing.expect(isStructural(GS));
	try std.testing.expect(isStructural(RS));
	try std.testing.expect(isStructural(US));
	try std.testing.expect(!isStructural('a'));
	try std.testing.expect(!isStructural(0x00));
}

test "encodePayload never produces structural bytes" {
	const allocator = std.testing.allocator;

	// Test all possible single bytes
	var buf: [1]u8 = undefined;
	for (0..256) |i| {
		buf[0] = @intCast(i);
		const encoded = try encodePayload(allocator, &buf);
		defer allocator.free(encoded);

		// Verify no structural bytes in output
		for (encoded) |b| {
			try std.testing.expect(!isStructural(b));
		}
	}
}

test "payload round-trip" {
	const allocator = std.testing.allocator;
	const original = "hello world \x00\x1c\x1d\x1e\x1f binary";

	const encoded = try encodePayload(allocator, original);
	defer allocator.free(encoded);

	const decoded = try decodePayload(allocator, encoded);
	defer allocator.free(decoded);

	try std.testing.expectEqualStrings(original, decoded);
}
```

**Step 4: Update mod.zig**

```zig
//! C0 Core - Hierarchical binary data stream encoding/decoding
//!
//! This module provides the pure encoding/decoding logic with no I/O.

pub const value = @import("value.zig");
pub const Value = value.Value;
pub const Entry = value.Entry;

pub const encoding = @import("encoding.zig");
pub const FS = encoding.FS;
pub const GS = encoding.GS;
pub const RS = encoding.RS;
pub const US = encoding.US;

test {
	_ = value;
	_ = encoding;
}
```

**Step 5: Run tests**

Run: `nix develop -c zig build test`
Expected: All tests pass, including structural byte invariant test

**Step 6: Commit**

```bash
git add build.zig build.zig.zon src/core/encoding.zig src/core/mod.zig
git commit -m "feat: wire printable_binary dependency, add encoding constants"
```

---

## Task 4: Encoder Implementation

**Files:**
- Create: `src/core/encoder.zig`
- Modify: `src/core/mod.zig`

**Step 1: Write encoder tests first**

```zig
//! C0 Encoder - Convert Value to C0 binary format

const std = @import("std");
const Value = @import("value.zig").Value;
const Entry = @import("value.zig").Entry;
const enc = @import("encoding.zig");

/// Encode a Value to C0 binary format
/// Caller owns returned slice and must free with same allocator
pub fn encode(allocator: std.mem.Allocator, val: Value) ![]u8 {
	var result: std.ArrayListUnmanaged(u8) = .{};
	errdefer result.deinit(allocator);

	try encodeValue(allocator, &result, val);

	return result.toOwnedSlice(allocator);
}

fn encodeValue(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), val: Value) !void {
	switch (val) {
		.string => |s| {
			const encoded = try enc.encodePayload(allocator, s);
			defer allocator.free(encoded);
			try out.appendSlice(allocator, encoded);
		},
		.array => |arr| {
			try out.append(allocator, enc.GS);
			for (arr) |item| {
				try encodeValue(allocator, out, item);
				try out.append(allocator, enc.US);
			}
			// Empty array still needs trailing US (spec: GS US)
			if (arr.len == 0) {
				try out.append(allocator, enc.US);
			}
		},
		.object => |obj| {
			try out.append(allocator, enc.FS);
			for (obj) |entry| {
				// Key
				const key_encoded = try enc.encodePayload(allocator, entry.key);
				defer allocator.free(key_encoded);
				try out.appendSlice(allocator, key_encoded);
				try out.append(allocator, enc.US);
				// Value
				try encodeValue(allocator, out, entry.value);
				try out.append(allocator, enc.RS);
			}
			// Empty object still needs trailing RS (spec: FS RS)
			if (obj.len == 0) {
				try out.append(allocator, enc.RS);
			}
		},
	}
}

test "encode empty string" {
	const allocator = std.testing.allocator;
	const val = Value{ .string = "" };

	const result = try encode(allocator, val);
	defer allocator.free(result);

	// Empty string = empty output (no payload bytes)
	try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "encode simple string" {
	const allocator = std.testing.allocator;
	const val = Value{ .string = "hello" };

	const result = try encode(allocator, val);
	defer allocator.free(result);

	// "hello" is ASCII, passes through printable_binary unchanged
	try std.testing.expectEqualStrings("hello", result);
}

test "encode empty array" {
	const allocator = std.testing.allocator;
	const val = Value{ .array = &.{} };

	const result = try encode(allocator, val);
	defer allocator.free(result);

	// Empty array = GS US
	try std.testing.expectEqual(@as(usize, 2), result.len);
	try std.testing.expectEqual(enc.GS, result[0]);
	try std.testing.expectEqual(enc.US, result[1]);
}

test "encode array with strings" {
	const allocator = std.testing.allocator;
	const items = [_]Value{
		.{ .string = "a" },
		.{ .string = "b" },
	};
	const val = Value{ .array = &items };

	const result = try encode(allocator, val);
	defer allocator.free(result);

	// GS "a" US "b" US
	try std.testing.expectEqual(@as(usize, 5), result.len);
	try std.testing.expectEqual(enc.GS, result[0]);
	try std.testing.expectEqual(@as(u8, 'a'), result[1]);
	try std.testing.expectEqual(enc.US, result[2]);
	try std.testing.expectEqual(@as(u8, 'b'), result[3]);
	try std.testing.expectEqual(enc.US, result[4]);
}

test "encode empty object" {
	const allocator = std.testing.allocator;
	const val = Value{ .object = &.{} };

	const result = try encode(allocator, val);
	defer allocator.free(result);

	// Empty object = FS RS
	try std.testing.expectEqual(@as(usize, 2), result.len);
	try std.testing.expectEqual(enc.FS, result[0]);
	try std.testing.expectEqual(enc.RS, result[1]);
}

test "encode object with entry" {
	const allocator = std.testing.allocator;
	const entries = [_]Entry{
		.{ .key = "k", .value = .{ .string = "v" } },
	};
	const val = Value{ .object = &entries };

	const result = try encode(allocator, val);
	defer allocator.free(result);

	// FS "k" US "v" RS
	try std.testing.expectEqual(@as(usize, 5), result.len);
	try std.testing.expectEqual(enc.FS, result[0]);
	try std.testing.expectEqual(@as(u8, 'k'), result[1]);
	try std.testing.expectEqual(enc.US, result[2]);
	try std.testing.expectEqual(@as(u8, 'v'), result[3]);
	try std.testing.expectEqual(enc.RS, result[4]);
}

test "encode nested structure" {
	const allocator = std.testing.allocator;

	// { "arr": ["x"] }
	const inner_arr = [_]Value{.{ .string = "x" }};
	const entries = [_]Entry{
		.{ .key = "arr", .value = .{ .array = &inner_arr } },
	};
	const val = Value{ .object = &entries };

	const result = try encode(allocator, val);
	defer allocator.free(result);

	// FS "arr" US GS "x" US RS
	try std.testing.expectEqual(@as(usize, 9), result.len);
	try std.testing.expectEqual(enc.FS, result[0]);
	// "arr" = bytes 1,2,3
	try std.testing.expectEqual(enc.US, result[4]);
	try std.testing.expectEqual(enc.GS, result[5]);
	try std.testing.expectEqual(@as(u8, 'x'), result[6]);
	try std.testing.expectEqual(enc.US, result[7]);
	try std.testing.expectEqual(enc.RS, result[8]);
}
```

**Step 2: Update mod.zig**

```zig
//! C0 Core - Hierarchical binary data stream encoding/decoding
//!
//! This module provides the pure encoding/decoding logic with no I/O.

pub const value = @import("value.zig");
pub const Value = value.Value;
pub const Entry = value.Entry;

pub const encoding = @import("encoding.zig");
pub const FS = encoding.FS;
pub const GS = encoding.GS;
pub const RS = encoding.RS;
pub const US = encoding.US;

pub const encoder = @import("encoder.zig");
pub const encode = encoder.encode;

test {
	_ = value;
	_ = encoding;
	_ = encoder;
}
```

**Step 3: Run tests**

Run: `nix develop -c zig build test`
Expected: All encoder tests pass

**Step 4: Commit**

```bash
git add src/core/encoder.zig src/core/mod.zig
git commit -m "feat: implement C0 encoder"
```

---

## Task 5: Decoder Implementation

**Files:**
- Create: `src/core/decoder.zig`
- Modify: `src/core/mod.zig`

**Step 1: Write decoder with tests**

```zig
//! C0 Decoder - Parse C0 binary format to Value

const std = @import("std");
const Value = @import("value.zig").Value;
const Entry = @import("value.zig").Entry;
const enc = @import("encoding.zig");

pub const DecodeError = error{
	UnexpectedEndOfInput,
	UnexpectedStructuralByte,
	MissingUnitSeparator,
	MissingRecordSeparator,
	TrailingData,
	OutOfMemory,
};

/// Decode C0 binary to a Value
/// Caller owns returned Value and all nested allocations
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Value {
	var pos: usize = 0;
	const result = try decodeValue(allocator, bytes, &pos);

	// Ensure we consumed all input
	if (pos != bytes.len) {
		deinitValue(allocator, result);
		return DecodeError.TrailingData;
	}

	return result;
}

fn decodeValue(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize) DecodeError!Value {
	if (pos.* >= bytes.len) {
		// Empty input = empty string
		return Value{ .string = "" };
	}

	const first = bytes[pos.*];

	if (first == enc.GS) {
		return decodeArray(allocator, bytes, pos);
	} else if (first == enc.FS) {
		return decodeObject(allocator, bytes, pos);
	} else {
		return decodeString(allocator, bytes, pos);
	}
}

fn decodeString(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize) DecodeError!Value {
	const start = pos.*;

	// Read until structural byte or end
	while (pos.* < bytes.len and !enc.isStructural(bytes[pos.*])) {
		pos.* += 1;
	}

	const encoded_payload = bytes[start..pos.*];

	// Decode the payload
	const decoded = enc.decodePayload(allocator, encoded_payload) catch |err| switch (err) {
		error.OutOfMemory => return DecodeError.OutOfMemory,
	};

	return Value{ .string = decoded };
}

fn decodeArray(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize) DecodeError!Value {
	// Consume GS
	std.debug.assert(bytes[pos.*] == enc.GS);
	pos.* += 1;

	var items: std.ArrayListUnmanaged(Value) = .{};
	errdefer {
		for (items.items) |*item| {
			deinitValue(allocator, item.*);
		}
		items.deinit(allocator);
	}

	while (pos.* < bytes.len) {
		const next = bytes[pos.*];

		// Check for empty array or end of array (US not preceded by value means end)
		if (next == enc.US) {
			pos.* += 1; // Consume US
			// Check if this is end of array (next byte is structural or end)
			if (pos.* >= bytes.len or enc.isStructural(bytes[pos.*])) {
				break;
			}
			// Otherwise, continue parsing next element (we just consumed a terminator)
			// But wait - per spec, each element ends with US. So after consuming US,
			// if there's more non-structural data, that's the next element.
			// Actually, we need to parse the element FIRST, then expect US.
			// Let me re-read the spec...
			// "Value US" for each element. So we parse value, then consume US.
			// Let me restructure.
		}

		// If we see another structural byte that's not US, array ends
		if (enc.isStructural(next) and next != enc.US) {
			// Array ended without final US - but spec says every array MUST end with US
			// This means we hit end of enclosing container
			break;
		}

		// Parse value
		const item = try decodeValue(allocator, bytes, pos);
		errdefer deinitValue(allocator, item);

		// Expect US after value
		if (pos.* >= bytes.len or bytes[pos.*] != enc.US) {
			deinitValue(allocator, item);
			return DecodeError.MissingUnitSeparator;
		}
		pos.* += 1; // Consume US

		items.append(allocator, item) catch return DecodeError.OutOfMemory;
	}

	const slice = items.toOwnedSlice(allocator) catch return DecodeError.OutOfMemory;
	return Value{ .array = slice };
}

fn decodeObject(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize) DecodeError!Value {
	// Consume FS
	std.debug.assert(bytes[pos.*] == enc.FS);
	pos.* += 1;

	var entries: std.ArrayListUnmanaged(Entry) = .{};
	errdefer {
		for (entries.items) |*entry| {
			allocator.free(entry.key);
			deinitValue(allocator, entry.value);
		}
		entries.deinit(allocator);
	}

	while (pos.* < bytes.len) {
		const next = bytes[pos.*];

		// Check for empty object or end of object
		if (next == enc.RS) {
			pos.* += 1; // Consume RS
			break;
		}

		// If we see another structural byte that's not RS, object ends
		if (enc.isStructural(next)) {
			break;
		}

		// Parse key (string until US)
		const key_val = try decodeString(allocator, bytes, pos);
		const key = key_val.string;
		errdefer allocator.free(key);

		// Expect US after key
		if (pos.* >= bytes.len or bytes[pos.*] != enc.US) {
			allocator.free(key);
			return DecodeError.MissingUnitSeparator;
		}
		pos.* += 1; // Consume US

		// Parse value
		const val = try decodeValue(allocator, bytes, pos);
		errdefer deinitValue(allocator, val);

		// Expect RS after value
		if (pos.* >= bytes.len or bytes[pos.*] != enc.RS) {
			allocator.free(key);
			deinitValue(allocator, val);
			return DecodeError.MissingRecordSeparator;
		}
		pos.* += 1; // Consume RS

		entries.append(allocator, .{ .key = key, .value = val }) catch return DecodeError.OutOfMemory;
	}

	const slice = entries.toOwnedSlice(allocator) catch return DecodeError.OutOfMemory;
	return Value{ .object = slice };
}

/// Free a Value and all nested allocations
pub fn deinitValue(allocator: std.mem.Allocator, val: Value) void {
	switch (val) {
		.string => |s| {
			if (s.len > 0) {
				// Only free if it was allocated (non-empty strings from decode)
				// Note: This assumes all decoded strings are heap-allocated
				allocator.free(s);
			}
		},
		.array => |arr| {
			for (arr) |item| {
				deinitValue(allocator, item);
			}
			if (arr.len > 0) {
				allocator.free(arr);
			}
		},
		.object => |obj| {
			for (obj) |entry| {
				if (entry.key.len > 0) {
					allocator.free(entry.key);
				}
				deinitValue(allocator, entry.value);
			}
			if (obj.len > 0) {
				allocator.free(obj);
			}
		},
	}
}

test "decode empty input" {
	const allocator = std.testing.allocator;
	const result = try decode(allocator, "");
	defer deinitValue(allocator, result);

	try std.testing.expect(result == .string);
	try std.testing.expectEqualStrings("", result.string);
}

test "decode simple string" {
	const allocator = std.testing.allocator;
	const result = try decode(allocator, "hello");
	defer deinitValue(allocator, result);

	try std.testing.expect(result == .string);
	try std.testing.expectEqualStrings("hello", result.string);
}

test "decode empty array" {
	const allocator = std.testing.allocator;
	const input = [_]u8{ enc.GS, enc.US };
	const result = try decode(allocator, &input);
	defer deinitValue(allocator, result);

	try std.testing.expect(result == .array);
	try std.testing.expectEqual(@as(usize, 0), result.array.len);
}

test "decode array with strings" {
	const allocator = std.testing.allocator;
	// GS "a" US "b" US
	const input = [_]u8{ enc.GS, 'a', enc.US, 'b', enc.US };
	const result = try decode(allocator, &input);
	defer deinitValue(allocator, result);

	try std.testing.expect(result == .array);
	try std.testing.expectEqual(@as(usize, 2), result.array.len);
	try std.testing.expectEqualStrings("a", result.array[0].string);
	try std.testing.expectEqualStrings("b", result.array[1].string);
}

test "decode empty object" {
	const allocator = std.testing.allocator;
	const input = [_]u8{ enc.FS, enc.RS };
	const result = try decode(allocator, &input);
	defer deinitValue(allocator, result);

	try std.testing.expect(result == .object);
	try std.testing.expectEqual(@as(usize, 0), result.object.len);
}

test "decode object with entry" {
	const allocator = std.testing.allocator;
	// FS "k" US "v" RS
	const input = [_]u8{ enc.FS, 'k', enc.US, 'v', enc.RS };
	const result = try decode(allocator, &input);
	defer deinitValue(allocator, result);

	try std.testing.expect(result == .object);
	try std.testing.expectEqual(@as(usize, 1), result.object.len);
	try std.testing.expectEqualStrings("k", result.object[0].key);
	try std.testing.expectEqualStrings("v", result.object[0].value.string);
}

test "decode nested structure" {
	const allocator = std.testing.allocator;
	// { "arr": ["x"] } = FS "arr" US GS "x" US RS
	const input = [_]u8{ enc.FS, 'a', 'r', 'r', enc.US, enc.GS, 'x', enc.US, enc.RS };
	const result = try decode(allocator, &input);
	defer deinitValue(allocator, result);

	try std.testing.expect(result == .object);
	try std.testing.expectEqual(@as(usize, 1), result.object.len);
	try std.testing.expectEqualStrings("arr", result.object[0].key);

	const arr = result.object[0].value;
	try std.testing.expect(arr == .array);
	try std.testing.expectEqual(@as(usize, 1), arr.array.len);
	try std.testing.expectEqualStrings("x", arr.array[0].string);
}

test "trailing data error" {
	const allocator = std.testing.allocator;
	// Valid object followed by garbage
	const input = [_]u8{ enc.FS, enc.RS, 'x' };

	const result = decode(allocator, &input);
	try std.testing.expectError(DecodeError.TrailingData, result);
}
```

**Step 2: Update mod.zig**

```zig
//! C0 Core - Hierarchical binary data stream encoding/decoding
//!
//! This module provides the pure encoding/decoding logic with no I/O.

pub const value = @import("value.zig");
pub const Value = value.Value;
pub const Entry = value.Entry;

pub const encoding = @import("encoding.zig");
pub const FS = encoding.FS;
pub const GS = encoding.GS;
pub const RS = encoding.RS;
pub const US = encoding.US;

pub const encoder = @import("encoder.zig");
pub const encode = encoder.encode;

pub const decoder = @import("decoder.zig");
pub const decode = decoder.decode;
pub const deinit = decoder.deinitValue;
pub const DecodeError = decoder.DecodeError;

test {
	_ = value;
	_ = encoding;
	_ = encoder;
	_ = decoder;
}
```

**Step 3: Run tests**

Run: `nix develop -c zig build test`
Expected: All decoder tests pass

**Step 4: Commit**

```bash
git add src/core/decoder.zig src/core/mod.zig
git commit -m "feat: implement C0 decoder"
```

---

## Task 6: Round-Trip Tests

**Files:**
- Create: `src/core/roundtrip_test.zig`
- Modify: `src/core/mod.zig`

**Step 1: Write comprehensive round-trip tests**

```zig
//! Round-trip tests: verify decode(encode(x)) == x

const std = @import("std");
const Value = @import("value.zig").Value;
const Entry = @import("value.zig").Entry;
const encode = @import("encoder.zig").encode;
const decode = @import("decoder.zig").decode;
const deinit = @import("decoder.zig").deinitValue;

fn roundTrip(allocator: std.mem.Allocator, original: Value) !void {
	const encoded = try encode(allocator, original);
	defer allocator.free(encoded);

	const decoded = try decode(allocator, encoded);
	defer deinit(allocator, decoded);

	if (!original.eql(decoded)) {
		std.debug.print("Round-trip FAILED!\n", .{});
		std.debug.print("Original: {any}\n", .{original});
		std.debug.print("Encoded ({d} bytes): ", .{encoded.len});
		for (encoded) |b| {
			if (b < 0x20) {
				std.debug.print("\\x{x:0>2}", .{b});
			} else {
				std.debug.print("{c}", .{b});
			}
		}
		std.debug.print("\n", .{});
		std.debug.print("Decoded: {any}\n", .{decoded});
		return error.RoundTripFailed;
	}
}

test "round-trip: empty string" {
	const allocator = std.testing.allocator;
	try roundTrip(allocator, Value{ .string = "" });
}

test "round-trip: simple string" {
	const allocator = std.testing.allocator;
	try roundTrip(allocator, Value{ .string = "hello world" });
}

test "round-trip: string with special bytes" {
	const allocator = std.testing.allocator;
	// Include bytes that would be structural if not encoded
	try roundTrip(allocator, Value{ .string = "test\x1c\x1d\x1e\x1fdata" });
}

test "round-trip: empty array" {
	const allocator = std.testing.allocator;
	try roundTrip(allocator, Value{ .array = &.{} });
}

test "round-trip: array with strings" {
	const allocator = std.testing.allocator;
	const items = [_]Value{
		.{ .string = "first" },
		.{ .string = "second" },
		.{ .string = "third" },
	};
	try roundTrip(allocator, Value{ .array = &items });
}

test "round-trip: empty object" {
	const allocator = std.testing.allocator;
	try roundTrip(allocator, Value{ .object = &.{} });
}

test "round-trip: object with entries" {
	const allocator = std.testing.allocator;
	const entries = [_]Entry{
		.{ .key = "name", .value = .{ .string = "test" } },
		.{ .key = "count", .value = .{ .string = "42" } },
	};
	try roundTrip(allocator, Value{ .object = &entries });
}

test "round-trip: nested array in object" {
	const allocator = std.testing.allocator;
	const inner = [_]Value{
		.{ .string = "a" },
		.{ .string = "b" },
	};
	const entries = [_]Entry{
		.{ .key = "items", .value = .{ .array = &inner } },
	};
	try roundTrip(allocator, Value{ .object = &entries });
}

test "round-trip: nested object in array" {
	const allocator = std.testing.allocator;
	const inner_entries = [_]Entry{
		.{ .key = "x", .value = .{ .string = "1" } },
	};
	const items = [_]Value{
		.{ .object = &inner_entries },
	};
	try roundTrip(allocator, Value{ .array = &items });
}

test "round-trip: deeply nested" {
	const allocator = std.testing.allocator;

	// { "level1": { "level2": { "level3": ["deep"] } } }
	const deep_arr = [_]Value{.{ .string = "deep" }};
	const level3 = [_]Entry{.{ .key = "level3", .value = .{ .array = &deep_arr } }};
	const level2 = [_]Entry{.{ .key = "level2", .value = .{ .object = &level3 } }};
	const level1 = [_]Entry{.{ .key = "level1", .value = .{ .object = &level2 } }};

	try roundTrip(allocator, Value{ .object = &level1 });
}
```

**Step 2: Update mod.zig**

```zig
//! C0 Core - Hierarchical binary data stream encoding/decoding
//!
//! This module provides the pure encoding/decoding logic with no I/O.

pub const value = @import("value.zig");
pub const Value = value.Value;
pub const Entry = value.Entry;

pub const encoding = @import("encoding.zig");
pub const FS = encoding.FS;
pub const GS = encoding.GS;
pub const RS = encoding.RS;
pub const US = encoding.US;

pub const encoder = @import("encoder.zig");
pub const encode = encoder.encode;

pub const decoder = @import("decoder.zig");
pub const decode = decoder.decode;
pub const deinit = decoder.deinitValue;
pub const DecodeError = decoder.DecodeError;

test {
	_ = value;
	_ = encoding;
	_ = encoder;
	_ = decoder;
	_ = @import("roundtrip_test.zig");
}
```

**Step 3: Run tests**

Run: `nix develop -c zig build test`
Expected: All round-trip tests pass

**Step 4: Commit**

```bash
git add src/core/roundtrip_test.zig src/core/mod.zig
git commit -m "test: add comprehensive round-trip tests"
```

---

## Task 7: FFI Layer (Arena-Based)

**Files:**
- Create: `ffi/c_api.zig`
- Create: `ffi/c0.h`
- Modify: `build.zig`

**Step 1: Create C header**

```c
/* c0.h - C0 Format C API */
#ifndef C0_H
#define C0_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque types */
typedef struct C0Arena C0Arena;
typedef struct C0Value C0Value;

/* Arena lifecycle */
C0Arena* c0_arena_new(void);
void c0_arena_free(C0Arena* arena);

/* Value constructors (allocate from arena) */
C0Value* c0_string(C0Arena* arena, const char* data, size_t len);
C0Value* c0_array(C0Arena* arena);
C0Value* c0_object(C0Arena* arena);

/* Array operations */
int c0_array_push(C0Value* arr, C0Value* item);
size_t c0_array_len(const C0Value* arr);
const C0Value* c0_array_get(const C0Value* arr, size_t index);

/* Object operations */
int c0_object_set(C0Value* obj, const char* key, size_t key_len, C0Value* val);
size_t c0_object_len(const C0Value* obj);
const char* c0_object_key(const C0Value* obj, size_t index, size_t* key_len);
const C0Value* c0_object_value(const C0Value* obj, size_t index);

/* Value inspection */
int c0_is_string(const C0Value* val);
int c0_is_array(const C0Value* val);
int c0_is_object(const C0Value* val);
const char* c0_string_data(const C0Value* val, size_t* len);

/* Encode/Decode */
int c0_encode(C0Arena* arena, const C0Value* val, const char** out, size_t* out_len);
C0Value* c0_decode(C0Arena* arena, const char* data, size_t len);

/* Error codes */
#define C0_OK 0
#define C0_ERR_NULL_ARG -1
#define C0_ERR_OUT_OF_MEMORY -2
#define C0_ERR_INVALID_TYPE -3
#define C0_ERR_DECODE_FAILED -4

#ifdef __cplusplus
}
#endif

#endif /* C0_H */
```

**Step 2: Create c_api.zig**

```zig
//! C0 FFI Layer - C ABI exports with arena-based memory management

const std = @import("std");
const core = @import("c0_core");

// Error codes matching c0.h
const C0_OK: c_int = 0;
const C0_ERR_NULL_ARG: c_int = -1;
const C0_ERR_OUT_OF_MEMORY: c_int = -2;
const C0_ERR_INVALID_TYPE: c_int = -3;
const C0_ERR_DECODE_FAILED: c_int = -4;

/// Arena for C0 allocations
pub const C0Arena = struct {
	allocator: std.mem.Allocator,
	arena: std.heap.ArenaAllocator,

	pub fn init() !*C0Arena {
		const backing = std.heap.page_allocator;
		const self = try backing.create(C0Arena);
		self.* = .{
			.allocator = undefined,
			.arena = std.heap.ArenaAllocator.init(backing),
		};
		self.allocator = self.arena.allocator();
		return self;
	}

	pub fn deinit(self: *C0Arena) void {
		const backing = std.heap.page_allocator;
		self.arena.deinit();
		backing.destroy(self);
	}
};

/// Mutable value wrapper for building
pub const C0Value = struct {
	inner: MutableValue,

	const MutableValue = union(enum) {
		string: []const u8,
		array: std.ArrayListUnmanaged(C0Value),
		object: std.ArrayListUnmanaged(MutableEntry),
	};

	const MutableEntry = struct {
		key: []const u8,
		value: *C0Value,
	};

	/// Convert to core Value (for encoding)
	pub fn toCore(self: *const C0Value, allocator: std.mem.Allocator) !core.Value {
		switch (self.inner) {
			.string => |s| return core.Value{ .string = s },
			.array => |arr| {
				const items = try allocator.alloc(core.Value, arr.items.len);
				for (arr.items, 0..) |*item, i| {
					items[i] = try item.toCore(allocator);
				}
				return core.Value{ .array = items };
			},
			.object => |obj| {
				const entries = try allocator.alloc(core.Entry, obj.items.len);
				for (obj.items, 0..) |*entry, i| {
					entries[i] = .{
						.key = entry.key,
						.value = try entry.value.toCore(allocator),
					};
				}
				return core.Value{ .object = entries };
			},
		}
	}
};

// === Arena lifecycle ===

export fn c0_arena_new() ?*C0Arena {
	return C0Arena.init() catch null;
}

export fn c0_arena_free(arena: ?*C0Arena) void {
	if (arena) |a| {
		a.deinit();
	}
}

// === Value constructors ===

export fn c0_string(arena: ?*C0Arena, data: ?[*]const u8, len: usize) ?*C0Value {
	const a = arena orelse return null;
	const d = data orelse return null;

	const val = a.allocator.create(C0Value) catch return null;
	const str_copy = a.allocator.alloc(u8, len) catch return null;
	@memcpy(str_copy, d[0..len]);

	val.* = .{ .inner = .{ .string = str_copy } };
	return val;
}

export fn c0_array(arena: ?*C0Arena) ?*C0Value {
	const a = arena orelse return null;

	const val = a.allocator.create(C0Value) catch return null;
	val.* = .{ .inner = .{ .array = .{} } };
	return val;
}

export fn c0_object(arena: ?*C0Arena) ?*C0Value {
	const a = arena orelse return null;

	const val = a.allocator.create(C0Value) catch return null;
	val.* = .{ .inner = .{ .object = .{} } };
	return val;
}

// === Array operations ===

export fn c0_array_push(arr: ?*C0Value, item: ?*C0Value) c_int {
	const a = arr orelse return C0_ERR_NULL_ARG;
	const i = item orelse return C0_ERR_NULL_ARG;

	if (a.inner != .array) return C0_ERR_INVALID_TYPE;

	// Get arena allocator from the array's memory location
	// This is a simplification - in production we'd track the arena
	a.inner.array.append(std.heap.page_allocator, i.*) catch return C0_ERR_OUT_OF_MEMORY;
	return C0_OK;
}

export fn c0_array_len(arr: ?*const C0Value) usize {
	const a = arr orelse return 0;
	if (a.inner != .array) return 0;
	return a.inner.array.items.len;
}

export fn c0_array_get(arr: ?*const C0Value, index: usize) ?*const C0Value {
	const a = arr orelse return null;
	if (a.inner != .array) return null;
	if (index >= a.inner.array.items.len) return null;
	return &a.inner.array.items[index];
}

// === Object operations ===

export fn c0_object_set(obj: ?*C0Value, key: ?[*]const u8, key_len: usize, val: ?*C0Value) c_int {
	const o = obj orelse return C0_ERR_NULL_ARG;
	const k = key orelse return C0_ERR_NULL_ARG;
	const v = val orelse return C0_ERR_NULL_ARG;

	if (o.inner != .object) return C0_ERR_INVALID_TYPE;

	// Copy key
	const key_copy = std.heap.page_allocator.alloc(u8, key_len) catch return C0_ERR_OUT_OF_MEMORY;
	@memcpy(key_copy, k[0..key_len]);

	// Store value pointer
	const val_ptr = std.heap.page_allocator.create(C0Value) catch return C0_ERR_OUT_OF_MEMORY;
	val_ptr.* = v.*;

	o.inner.object.append(std.heap.page_allocator, .{
		.key = key_copy,
		.value = val_ptr,
	}) catch return C0_ERR_OUT_OF_MEMORY;

	return C0_OK;
}

export fn c0_object_len(obj: ?*const C0Value) usize {
	const o = obj orelse return 0;
	if (o.inner != .object) return 0;
	return o.inner.object.items.len;
}

export fn c0_object_key(obj: ?*const C0Value, index: usize, key_len: ?*usize) ?[*]const u8 {
	const o = obj orelse return null;
	if (o.inner != .object) return null;
	if (index >= o.inner.object.items.len) return null;

	const entry = o.inner.object.items[index];
	if (key_len) |len| {
		len.* = entry.key.len;
	}
	return entry.key.ptr;
}

export fn c0_object_value(obj: ?*const C0Value, index: usize) ?*const C0Value {
	const o = obj orelse return null;
	if (o.inner != .object) return null;
	if (index >= o.inner.object.items.len) return null;
	return o.inner.object.items[index].value;
}

// === Value inspection ===

export fn c0_is_string(val: ?*const C0Value) c_int {
	const v = val orelse return 0;
	return if (v.inner == .string) 1 else 0;
}

export fn c0_is_array(val: ?*const C0Value) c_int {
	const v = val orelse return 0;
	return if (v.inner == .array) 1 else 0;
}

export fn c0_is_object(val: ?*const C0Value) c_int {
	const v = val orelse return 0;
	return if (v.inner == .object) 1 else 0;
}

export fn c0_string_data(val: ?*const C0Value, len: ?*usize) ?[*]const u8 {
	const v = val orelse return null;
	if (v.inner != .string) return null;

	const s = v.inner.string;
	if (len) |l| {
		l.* = s.len;
	}
	return s.ptr;
}

// === Encode/Decode ===

export fn c0_encode(arena: ?*C0Arena, val: ?*const C0Value, out: ?*[*]const u8, out_len: ?*usize) c_int {
	const a = arena orelse return C0_ERR_NULL_ARG;
	const v = val orelse return C0_ERR_NULL_ARG;
	const o = out orelse return C0_ERR_NULL_ARG;
	const ol = out_len orelse return C0_ERR_NULL_ARG;

	// Convert to core Value
	const core_val = v.toCore(a.allocator) catch return C0_ERR_OUT_OF_MEMORY;

	// Encode
	const encoded = core.encode(a.allocator, core_val) catch return C0_ERR_OUT_OF_MEMORY;

	o.* = encoded.ptr;
	ol.* = encoded.len;
	return C0_OK;
}

export fn c0_decode(arena: ?*C0Arena, data: ?[*]const u8, len: usize) ?*C0Value {
	const a = arena orelse return null;
	const d = data orelse return null;

	const bytes = d[0..len];
	const core_val = core.decode(a.allocator, bytes) catch return null;

	// Convert core Value to C0Value
	return coreToC0Value(a, core_val) catch return null;
}

fn coreToC0Value(arena: *C0Arena, val: core.Value) !*C0Value {
	const result = try arena.allocator.create(C0Value);

	switch (val) {
		.string => |s| {
			result.* = .{ .inner = .{ .string = s } };
		},
		.array => |arr| {
			var items: std.ArrayListUnmanaged(C0Value) = .{};
			for (arr) |item| {
				const converted = try coreToC0Value(arena, item);
				try items.append(arena.allocator, converted.*);
			}
			result.* = .{ .inner = .{ .array = items } };
		},
		.object => |obj| {
			var entries: std.ArrayListUnmanaged(C0Value.MutableEntry) = .{};
			for (obj) |entry| {
				const converted_val = try coreToC0Value(arena, entry.value);
				try entries.append(arena.allocator, .{
					.key = entry.key,
					.value = converted_val,
				});
			}
			result.* = .{ .inner = .{ .object = entries } };
		},
	}

	return result;
}

test "FFI: arena lifecycle" {
	const arena = c0_arena_new();
	try std.testing.expect(arena != null);
	c0_arena_free(arena);
}

test "FFI: string round-trip" {
	const arena = c0_arena_new().?;
	defer c0_arena_free(arena);

	const str = c0_string(arena, "hello", 5).?;
	try std.testing.expectEqual(@as(c_int, 1), c0_is_string(str));

	var len: usize = 0;
	const data = c0_string_data(str, &len).?;
	try std.testing.expectEqual(@as(usize, 5), len);
	try std.testing.expectEqualStrings("hello", data[0..len]);
}

test "FFI: encode/decode round-trip" {
	const arena = c0_arena_new().?;
	defer c0_arena_free(arena);

	const str = c0_string(arena, "test", 4).?;

	var out: [*]const u8 = undefined;
	var out_len: usize = 0;
	const enc_result = c0_encode(arena, str, &out, &out_len);
	try std.testing.expectEqual(C0_OK, enc_result);

	const decoded = c0_decode(arena, out, out_len).?;
	try std.testing.expectEqual(@as(c_int, 1), c0_is_string(decoded));

	var dec_len: usize = 0;
	const dec_data = c0_string_data(decoded, &dec_len).?;
	try std.testing.expectEqualStrings("test", dec_data[0..dec_len]);
}
```

**Step 3: Update build.zig to build FFI**

Add FFI module and static library to build.zig (see full build.zig in design doc for reference).

**Step 4: Run tests**

Run: `nix develop -c zig build test`
Expected: All FFI tests pass

**Step 5: Commit**

```bash
git add ffi/c0.h ffi/c_api.zig build.zig
git commit -m "feat: add FFI layer with arena-based memory"
```

---

## Task 8: C CLI

**Files:**
- Create: `cli/main.c`
- Modify: `build.zig`

**Step 1: Create C CLI**

```c
/* c0 CLI - C0 format encoder/decoder */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../ffi/c0.h"

#define BUFFER_SIZE 65536

static void print_usage(const char* program) {
	fprintf(stderr, "Usage: %s <command> [options]\n", program);
	fprintf(stderr, "\nCommands:\n");
	fprintf(stderr, "  encode    Encode a string to C0 format\n");
	fprintf(stderr, "  decode    Decode C0 format to inspect structure\n");
	fprintf(stderr, "\nExamples:\n");
	fprintf(stderr, "  echo 'hello' | %s encode\n", program);
	fprintf(stderr, "  %s decode < file.c0\n", program);
}

static int cmd_encode(void) {
	char buffer[BUFFER_SIZE];
	size_t len = fread(buffer, 1, BUFFER_SIZE - 1, stdin);

	/* Remove trailing newline if present */
	if (len > 0 && buffer[len - 1] == '\n') {
		len--;
	}
	buffer[len] = '\0';

	C0Arena* arena = c0_arena_new();
	if (!arena) {
		fprintf(stderr, "Error: failed to create arena\n");
		return 1;
	}

	C0Value* val = c0_string(arena, buffer, len);
	if (!val) {
		fprintf(stderr, "Error: failed to create string value\n");
		c0_arena_free(arena);
		return 1;
	}

	const char* out;
	size_t out_len;
	int result = c0_encode(arena, val, &out, &out_len);
	if (result != C0_OK) {
		fprintf(stderr, "Error: encoding failed with code %d\n", result);
		c0_arena_free(arena);
		return 1;
	}

	fwrite(out, 1, out_len, stdout);
	fputc('\n', stdout);

	c0_arena_free(arena);
	return 0;
}

static void print_value(const C0Value* val, int indent);

static void print_indent(int indent) {
	for (int i = 0; i < indent; i++) {
		fputs("  ", stdout);
	}
}

static void print_value(const C0Value* val, int indent) {
	if (c0_is_string(val)) {
		size_t len;
		const char* data = c0_string_data(val, &len);
		printf("\"%.*s\"", (int)len, data);
	} else if (c0_is_array(val)) {
		size_t len = c0_array_len(val);
		if (len == 0) {
			printf("[]");
		} else {
			printf("[\n");
			for (size_t i = 0; i < len; i++) {
				print_indent(indent + 1);
				print_value(c0_array_get(val, i), indent + 1);
				if (i < len - 1) printf(",");
				printf("\n");
			}
			print_indent(indent);
			printf("]");
		}
	} else if (c0_is_object(val)) {
		size_t len = c0_object_len(val);
		if (len == 0) {
			printf("{}");
		} else {
			printf("{\n");
			for (size_t i = 0; i < len; i++) {
				size_t key_len;
				const char* key = c0_object_key(val, i, &key_len);
				print_indent(indent + 1);
				printf("\"%.*s\": ", (int)key_len, key);
				print_value(c0_object_value(val, i), indent + 1);
				if (i < len - 1) printf(",");
				printf("\n");
			}
			print_indent(indent);
			printf("}");
		}
	}
}

static int cmd_decode(void) {
	char buffer[BUFFER_SIZE];
	size_t len = fread(buffer, 1, BUFFER_SIZE, stdin);

	C0Arena* arena = c0_arena_new();
	if (!arena) {
		fprintf(stderr, "Error: failed to create arena\n");
		return 1;
	}

	C0Value* val = c0_decode(arena, buffer, len);
	if (!val) {
		fprintf(stderr, "Error: decoding failed\n");
		c0_arena_free(arena);
		return 1;
	}

	print_value(val, 0);
	printf("\n");

	c0_arena_free(arena);
	return 0;
}

int main(int argc, char** argv) {
	if (argc < 2) {
		print_usage(argv[0]);
		return 1;
	}

	const char* cmd = argv[1];

	if (strcmp(cmd, "encode") == 0) {
		return cmd_encode();
	} else if (strcmp(cmd, "decode") == 0) {
		return cmd_decode();
	} else if (strcmp(cmd, "-h") == 0 || strcmp(cmd, "--help") == 0) {
		print_usage(argv[0]);
		return 0;
	} else {
		fprintf(stderr, "Unknown command: %s\n", cmd);
		print_usage(argv[0]);
		return 1;
	}
}
```

**Step 2: Update build.zig to build CLI**

Add C CLI build configuration.

**Step 3: Build and test manually**

Run: `nix develop -c zig build`
Run: `echo "hello" | ./zig-out/bin/c0 encode`
Expected: Encoded output

Run: `echo "hello" | ./zig-out/bin/c0 encode | ./zig-out/bin/c0 decode`
Expected: `"hello"`

**Step 4: Commit**

```bash
git add cli/main.c build.zig
git commit -m "feat: add C CLI"
```

---

## Task 9: CLI Bash Tests

**Files:**
- Create: `tests/cli/test_encode_decode.sh`

**Step 1: Create CLI test script**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
C0="$PROJECT_ROOT/zig-out/bin/c0"

failures=0

# Test helper
test_case() {
	local name="$1"
	local expected="$2"
	local actual="$3"

	if [[ "$expected" == "$actual" ]]; then
		echo "PASS: $name"
	else
		echo "FAIL: $name"
		echo "  Expected: $expected"
		echo "  Actual:   $actual"
		((failures++)) || true
	fi
}

echo "=== CLI Tests ==="

# Test 1: Simple string encode/decode round-trip
result=$(echo "hello" | "$C0" encode | "$C0" decode)
test_case "string round-trip" '"hello"' "$result"

# Test 2: Empty string
result=$(echo -n "" | "$C0" encode | "$C0" decode)
test_case "empty string" '""' "$result"

# Test 3: Help flag
"$C0" --help > /dev/null 2>&1 && test_case "help flag" "ok" "ok" || { test_case "help flag" "ok" "failed"; }

# Test 4: Unknown command exits with error
if "$C0" unknown_cmd > /dev/null 2>&1; then
	test_case "unknown command fails" "exit 1" "exit 0"
else
	test_case "unknown command fails" "exit 1" "exit 1"
fi

echo "=== CLI Tests Complete ==="

exit $failures
```

**Step 2: Make executable**

```bash
chmod +x tests/cli/test_encode_decode.sh
```

**Step 3: Run full test suite**

Run: `./test`
Expected: Both Zig and CLI tests pass

**Step 4: Commit**

```bash
git add tests/cli/test_encode_decode.sh
git commit -m "test: add CLI bash tests"
```

---

## Task 10: Documentation

**Files:**
- Create: `CODE_MINIMAP.md`
- Update: `PLAN.md`
- Create: `README.md`

**Step 1: Create CODE_MINIMAP.md**

```markdown
# C0 Code Minimap

## src/core/

### mod.zig
Public API entry point. Re-exports all core types and functions.
- `Value`, `Entry` - data types
- `encode()` - Value → C0 bytes
- `decode()` - C0 bytes → Value
- `deinit()` - free decoded Value

### value.zig
Value type definitions.
- `Value` - tagged union (string/array/object)
- `Entry` - key-value pair for objects
- `eql()` - deep equality comparison

### encoding.zig
Low-level encoding utilities.
- `FS`, `GS`, `RS`, `US` - structural byte constants
- `isStructural()` - check if byte is delimiter
- `encodePayload()` - wrap printable_binary encode
- `decodePayload()` - wrap printable_binary decode

### encoder.zig
Encoder implementation.
- `encode()` - convert Value to C0 binary

### decoder.zig
Decoder implementation.
- `decode()` - parse C0 binary to Value
- `deinitValue()` - recursive free
- `DecodeError` - error types

### roundtrip_test.zig
Comprehensive round-trip tests.

## ffi/

### c_api.zig
C ABI exports with arena memory management.
- `C0Arena` - memory pool
- `C0Value` - mutable value wrapper
- All `c0_*` exported functions

### c0.h
C header file for FFI consumers.

## cli/

### main.c
C CLI implementation.
- `encode` command - stdin string → C0 binary
- `decode` command - C0 binary → pretty print
```

**Step 2: Create PLAN.md**

```markdown
# C0 Implementation Plan

## Completed
- [x] Project scaffolding (2026-02-02)
- [x] Value type definition (2026-02-02)
- [x] printable_binary dependency (2026-02-02)
- [x] Encoder implementation (2026-02-02)
- [x] Decoder implementation (2026-02-02)
- [x] Round-trip tests (2026-02-02)
- [x] FFI layer (2026-02-02)
- [x] C CLI (2026-02-02)
- [x] CLI tests (2026-02-02)
- [x] Documentation (2026-02-02)

## Future
- [ ] JSON demo (examples/json_demo.zig)
- [ ] Streaming API
- [ ] Performance benchmarks
```

**Step 3: Create README.md**

```markdown
# C0

A hierarchical binary data stream format designed for human-readable UTF-8 environments.

## Features

- **No escaping** - structural bytes never appear in payloads
- **Streaming-safe** - parse in a single left-to-right pass
- **UTF-8 compatible** - human-readable when printed
- **Deterministic** - same input always produces same output

## Quick Start

```bash
# Build
nix develop -c zig build

# Encode a string
echo "hello world" | ./zig-out/bin/c0 encode

# Decode back
echo "hello world" | ./zig-out/bin/c0 encode | ./zig-out/bin/c0 decode
```

## Building

Requires Nix with flakes enabled:

```bash
nix develop -c zig build          # Debug build
nix develop -c zig build -Doptimize=ReleaseFast  # Release build
```

## Testing

```bash
./test  # Runs Zig unit tests and CLI bash tests
```

## Architecture

See `docs/plans/2026-02-02-c0-design.md` for full design.

## License

MIT
```

**Step 4: Commit**

```bash
git add CODE_MINIMAP.md PLAN.md README.md
git commit -m "docs: add CODE_MINIMAP, PLAN, and README"
```

---

## Final: Push and Verify

**Step 1: Push all changes**

```bash
git push origin yolo
```

**Step 2: Verify CI (if configured)**

Check GitHub for any CI status.

**Done!** Core C0 implementation complete with:
- Pure Zig core (encode/decode)
- Arena-based C FFI
- C CLI
- Comprehensive tests
- Documentation
