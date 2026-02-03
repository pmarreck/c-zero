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
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    const mode = EncodeMode{ .smart = .{
        .allow_spaces = options.allow_spaces,
        .allow_tabs = options.allow_tabs,
    } };
    try encodeValue(allocator, &result, val, mode);

    return result.toOwnedSlice(allocator);
}

/// Encode a Value to C0 binary format without payload encoding
/// Payloads are written as-is (caller is responsible for ensuring no structural bytes)
/// Caller owns returned slice and must free with same allocator
pub fn encodeRaw(allocator: std.mem.Allocator, val: Value) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    try encodeValue(allocator, &result, val, .raw);

    return result.toOwnedSlice(allocator);
}

fn encodeValue(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), val: Value, mode: EncodeMode) !void {
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
            try out.append(allocator, enc.GS);
            for (arr) |item| {
                try encodeValue(allocator, out, item, mode);
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
                switch (mode) {
                    .smart => |opts| {
                        const key_encoded = try enc.encodePayloadSmart(allocator, entry.key, opts);
                        defer allocator.free(key_encoded);
                        try out.appendSlice(allocator, key_encoded);
                    },
                    .raw => {
                        try out.appendSlice(allocator, entry.key);
                    },
                }
                try out.append(allocator, enc.US);
                // Value
                try encodeValue(allocator, out, entry.value, mode);
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

    // Empty array = GS US = "[:"
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

    // GS "a" US "b" US = "[a:b:" = 5 bytes
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

    // Empty object = FS RS = "{,"
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

    // FS "k" US "v" RS = "{k:v," = 5 bytes
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

    // FS "arr" US GS "x" US RS = "{arr:[x:," = 9 bytes
    try std.testing.expectEqual(@as(usize, 9), result.len);
    try std.testing.expectEqual(enc.FS, result[0]);
    try std.testing.expectEqualStrings("arr", result[1..4]);
    try std.testing.expectEqual(enc.US, result[4]);
    try std.testing.expectEqual(enc.GS, result[5]);
    try std.testing.expectEqual(@as(u8, 'x'), result[6]);
    try std.testing.expectEqual(enc.US, result[7]);
    try std.testing.expectEqual(enc.RS, result[8]);
}
