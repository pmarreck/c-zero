//! C0 Encoder - Convert Value to C0 binary format

const std = @import("std");
const Value = @import("value.zig").Value;
const Entry = @import("value.zig").Entry;
const enc = @import("encoding.zig");

/// Options for C0 encoding
pub const EncodeOptions = struct {
    /// Allow literal spaces in payloads (don't force encoding for spaces)
    /// Default true: spaces pass through unchanged for better readability and smaller output
    allow_spaces: bool = true,
    /// Allow literal tabs in payloads (don't force encoding for tabs)
    allow_tabs: bool = false,
    /// Pretty-print with tabs and newlines (insignificant whitespace, stripped on decode)
    pretty: bool = false,
};

/// Encode mode for internal use
const EncodeMode = union(enum) {
    /// Smart encoding with options
    smart: enc.EncodePayloadOptions,
    /// Raw mode - no payload encoding
    raw: void,
};

/// Encode a Value to C0 binary format using smart encoding
/// Only applies printable_binary encoding when needed (avoids double-encoding)
/// Caller owns returned slice and must free with same allocator
pub fn encode(allocator: std.mem.Allocator, val: Value) ![]u8 {
    return encodeWithOptions(allocator, val, .{});
}

/// Encode a Value to C0 binary format with options
/// Caller owns returned slice and must free with same allocator
pub fn encodeWithOptions(allocator: std.mem.Allocator, val: Value, options: EncodeOptions) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    const mode = EncodeMode{ .smart = .{
        .allow_spaces = options.allow_spaces,
        .allow_tabs = options.allow_tabs,
    } };
    try encodeValue(allocator, &result, val, mode, options.pretty, 0);

    // Trailing newline for pretty output
    if (options.pretty) {
        try result.append(allocator, '\n');
    }

    return result.toOwnedSlice(allocator);
}

/// Encode a Value to C0 binary format without payload encoding
/// Payloads are written as-is (caller is responsible for ensuring no structural bytes)
/// Caller owns returned slice and must free with same allocator
pub fn encodeRaw(allocator: std.mem.Allocator, val: Value) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    try encodeValue(allocator, &result, val, .raw, false, 0);

    return result.toOwnedSlice(allocator);
}

fn writeIndent(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), depth: usize) !void {
    for (0..depth) |_| {
        try out.append(allocator, '\t');
    }
}

fn encodeKey(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), key: []const u8, mode: EncodeMode) !void {
    switch (mode) {
        .smart => |opts| {
            const key_encoded = try enc.encodePayloadSmart(allocator, key, opts);
            defer allocator.free(key_encoded);
            try out.appendSlice(allocator, key_encoded);
        },
        .raw => {
            try out.appendSlice(allocator, key);
        },
    }
}

fn encodeValue(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), val: Value, mode: EncodeMode, pretty: bool, depth: usize) !void {
    switch (val) {
        .string => |s| {
            switch (mode) {
                .smart => |opts| {
                    const encoded = try enc.encodePayloadSmart(allocator, s, opts);
                    defer allocator.free(encoded);
                    try out.appendSlice(allocator, encoded);
                },
                .raw => {
                    try out.appendSlice(allocator, s);
                },
            }
        },
        .array => |arr| {
            try out.append(allocator, enc.ARRAY_OPEN);
            if (pretty and arr.len > 0) {
                for (arr, 0..) |item, i| {
                    try out.append(allocator, '\n');
                    try writeIndent(allocator, out, depth + 1);
                    try encodeValue(allocator, out, item, mode, pretty, depth + 1);
                    if (i < arr.len - 1) try out.append(allocator, enc.COMMA);
                }
                try out.append(allocator, '\n');
                try writeIndent(allocator, out, depth);
            } else {
                for (arr, 0..) |item, i| {
                    if (i > 0) try out.append(allocator, enc.COMMA);
                    try encodeValue(allocator, out, item, mode, pretty, depth + 1);
                }
            }
            try out.append(allocator, enc.ARRAY_CLOSE);
        },
        .object => |obj| {
            try out.append(allocator, enc.OBJECT_OPEN);
            if (pretty and obj.len > 0) {
                for (obj, 0..) |entry, i| {
                    try out.append(allocator, '\n');
                    try writeIndent(allocator, out, depth + 1);
                    try encodeKey(allocator, out, entry.key, mode);
                    try out.append(allocator, enc.COLON);
                    try encodeValue(allocator, out, entry.value, mode, pretty, depth + 1);
                    if (i < obj.len - 1) try out.append(allocator, enc.COMMA);
                }
                try out.append(allocator, '\n');
                try writeIndent(allocator, out, depth);
            } else {
                for (obj, 0..) |entry, i| {
                    if (i > 0) try out.append(allocator, enc.COMMA);
                    try encodeKey(allocator, out, entry.key, mode);
                    try out.append(allocator, enc.COLON);
                    try encodeValue(allocator, out, entry.value, mode, pretty, depth + 1);
                }
            }
            try out.append(allocator, enc.OBJECT_CLOSE);
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

    // Empty array = "[]"
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(enc.ARRAY_OPEN, result[0]);
    try std.testing.expectEqual(enc.ARRAY_CLOSE, result[1]);
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

    // "[a,b]" = 5 bytes
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("[a,b]", result);
}

test "encode empty object" {
    const allocator = std.testing.allocator;
    const val = Value{ .object = &.{} };

    const result = try encode(allocator, val);
    defer allocator.free(result);

    // Empty object = "{}"
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("{}", result);
}

test "encode object with entry" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .key = "k", .value = .{ .string = "v" } },
    };
    const val = Value{ .object = &entries };

    const result = try encode(allocator, val);
    defer allocator.free(result);

    // "{k:v}" = 5 bytes
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("{k:v}", result);
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

    // "{arr:[x]}" = 9 bytes
    try std.testing.expectEqual(@as(usize, 9), result.len);
    try std.testing.expectEqualStrings("{arr:[x]}", result);
}

test "encode pretty empty containers" {
    const allocator = std.testing.allocator;

    // Empty array stays compact even in pretty mode
    const empty_arr = Value{ .array = &.{} };
    const result1 = try encodeWithOptions(allocator, empty_arr, .{ .pretty = true });
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("[]\n", result1);

    // Empty object stays compact even in pretty mode
    const empty_obj = Value{ .object = &.{} };
    const result2 = try encodeWithOptions(allocator, empty_obj, .{ .pretty = true });
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("{}\n", result2);
}

test "encode pretty object" {
    const allocator = std.testing.allocator;

    const entries = [_]Entry{
        .{ .key = "name", .value = .{ .string = "Tav" } },
        .{ .key = "level", .value = .{ .string = "5" } },
    };
    const val = Value{ .object = &entries };

    const result = try encodeWithOptions(allocator, val, .{ .pretty = true });
    defer allocator.free(result);

    try std.testing.expectEqualStrings(
        "{\n\tname:Tav,\n\tlevel:5\n}\n",
        result,
    );
}

test "encode pretty nested structure" {
    const allocator = std.testing.allocator;

    // { "name": "Tav", "stats": { "str": "16" } }
    const inner_entries = [_]Entry{
        .{ .key = "str", .value = .{ .string = "16" } },
    };
    const entries = [_]Entry{
        .{ .key = "name", .value = .{ .string = "Tav" } },
        .{ .key = "stats", .value = .{ .object = &inner_entries } },
    };
    const val = Value{ .object = &entries };

    const result = try encodeWithOptions(allocator, val, .{ .pretty = true });
    defer allocator.free(result);

    try std.testing.expectEqualStrings(
        "{\n\tname:Tav,\n\tstats:{\n\t\tstr:16\n\t}\n}\n",
        result,
    );
}

test "encode pretty array" {
    const allocator = std.testing.allocator;

    const items = [_]Value{
        .{ .string = "a" },
        .{ .string = "b" },
        .{ .string = "c" },
    };
    const val = Value{ .array = &items };

    const result = try encodeWithOptions(allocator, val, .{ .pretty = true });
    defer allocator.free(result);

    try std.testing.expectEqualStrings(
        "[\n\ta,\n\tb,\n\tc\n]\n",
        result,
    );
}

test "encode pretty round-trips through decoder" {
    const allocator = std.testing.allocator;
    const decoder = @import("decoder.zig");

    // Build a nested structure
    const inner_arr = [_]Value{.{ .string = "x" }, .{ .string = "y" }};
    const entries = [_]Entry{
        .{ .key = "arr", .value = .{ .array = &inner_arr } },
        .{ .key = "val", .value = .{ .string = "z" } },
    };
    const original = Value{ .object = &entries };

    // Encode with pretty
    const pretty_bytes = try encodeWithOptions(allocator, original, .{ .pretty = true });
    defer allocator.free(pretty_bytes);

    // Decode (strips insignificant whitespace)
    const decoded = try decoder.decode(allocator, pretty_bytes);
    defer decoder.deinitValue(allocator, decoded);

    // Re-encode compact
    const compact_bytes = try encode(allocator, decoded);
    defer allocator.free(compact_bytes);

    // Should match compact encoding of original
    const original_compact = try encode(allocator, original);
    defer allocator.free(original_compact);

    try std.testing.expectEqualStrings(original_compact, compact_bytes);
}
