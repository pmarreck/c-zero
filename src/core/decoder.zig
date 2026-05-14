//! C0 Decoder - Parse C0 binary format to Value

const std = @import("std");
const Value = @import("value.zig").Value;
const Entry = @import("value.zig").Entry;
const enc = @import("encoding.zig");

pub const DecodeError = error{
    UnexpectedEndOfInput,
    UnexpectedByte,
    TrailingData,
    OutOfMemory,
};

/// Options for C0 decoding
pub const DecodeOptions = struct {
    /// If true, keep printable-binary encoded data as-is (don't decode)
    /// Useful for JSON output where we want readable strings
    keep_printable: bool = false,
};

/// Decode C0 binary to a Value
/// Caller owns returned Value and all nested allocations
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Value {
    return decodeWithOptions(allocator, bytes, .{});
}

/// Decode C0 binary to a Value with options
/// Caller owns returned Value and all nested allocations
pub fn decodeWithOptions(allocator: std.mem.Allocator, bytes: []const u8, options: DecodeOptions) DecodeError!Value {
    var pos: usize = 0;
    const result = try decodeValueInternal(allocator, bytes, &pos, options);

    // Skip trailing insignificant whitespace
    skipWhitespace(bytes, &pos);

    // Ensure we consumed all input
    if (pos != bytes.len) {
        deinitValue(allocator, result);
        return DecodeError.TrailingData;
    }

    return result;
}

/// Skip insignificant whitespace (tabs and newlines — NOT spaces, which are content)
fn skipWhitespace(bytes: []const u8, pos: *usize) void {
    while (pos.* < bytes.len) {
        const b = bytes[pos.*];
        if (b == '\t' or b == '\n' or b == '\r') {
            pos.* += 1;
        } else break;
    }
}

fn decodeValueInternal(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize, options: DecodeOptions) DecodeError!Value {
    skipWhitespace(bytes, pos);

    if (pos.* >= bytes.len) {
        // Empty input = empty string
        return Value{ .string = "" };
    }

    const first = bytes[pos.*];

    if (first == enc.ARRAY_OPEN) {
        return decodeArrayInternal(allocator, bytes, pos, options);
    } else if (first == enc.OBJECT_OPEN) {
        return decodeObjectInternal(allocator, bytes, pos, options);
    } else {
        return decodeStringInternal(allocator, bytes, pos, options);
    }
}

fn decodeStringInternal(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize, options: DecodeOptions) DecodeError!Value {
    const start = pos.*;

    // Read until structural byte or end
    while (pos.* < bytes.len and !enc.isStructural(bytes[pos.*])) {
        // Skip insignificant whitespace characters within strings
        // (they get stripped — tabs/newlines are not content)
        if (bytes[pos.*] == '\t' or bytes[pos.*] == '\n' or bytes[pos.*] == '\r') {
            pos.* += 1;
            continue;
        }
        pos.* += 1;
    }

    // Build payload without insignificant whitespace
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);
    payload.ensureTotalCapacity(allocator, pos.* - start) catch return DecodeError.OutOfMemory;
    for (bytes[start..pos.*]) |b| {
        if (b != '\t' and b != '\n' and b != '\r') {
            payload.appendAssumeCapacity(b);
        }
    }

    const encoded_payload = payload.items;

    // Decode the payload using smart decoding
    const decoded = enc.decodePayloadSmart(allocator, encoded_payload, .{
        .keep_printable = options.keep_printable,
    }) catch |err| switch (err) {
        error.OutOfMemory => return DecodeError.OutOfMemory,
    };

    return Value{ .string = decoded };
}

fn decodeArrayInternal(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize, options: DecodeOptions) DecodeError!Value {
    // Consume '['
    std.debug.assert(bytes[pos.*] == enc.ARRAY_OPEN);
    pos.* += 1;

    var items: std.ArrayListUnmanaged(Value) = .empty;
    errdefer {
        for (items.items) |item| {
            deinitValue(allocator, item);
        }
        items.deinit(allocator);
    }

    skipWhitespace(bytes, pos);

    // Check for empty array
    if (pos.* < bytes.len and bytes[pos.*] == enc.ARRAY_CLOSE) {
        pos.* += 1; // Consume ']'
        const slice = items.toOwnedSlice(allocator) catch return DecodeError.OutOfMemory;
        return Value{ .array = slice };
    }

    // Parse items separated by commas
    while (true) {
        const item = try decodeValueInternal(allocator, bytes, pos, options);
        errdefer deinitValue(allocator, item);
        items.append(allocator, item) catch return DecodeError.OutOfMemory;

        skipWhitespace(bytes, pos);

        if (pos.* >= bytes.len) {
            return DecodeError.UnexpectedEndOfInput;
        }

        const next = bytes[pos.*];
        if (next == enc.ARRAY_CLOSE) {
            pos.* += 1; // Consume ']'
            break;
        } else if (next == enc.COMMA) {
            pos.* += 1; // Consume ','
            // Continue to next item
        } else {
            return DecodeError.UnexpectedByte;
        }
    }

    const slice = items.toOwnedSlice(allocator) catch return DecodeError.OutOfMemory;
    return Value{ .array = slice };
}

fn decodeObjectInternal(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize, options: DecodeOptions) DecodeError!Value {
    // Consume '{'
    std.debug.assert(bytes[pos.*] == enc.OBJECT_OPEN);
    pos.* += 1;

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            if (entry.key.len > 0) {
                allocator.free(entry.key);
            }
            deinitValue(allocator, entry.value);
        }
        entries.deinit(allocator);
    }

    skipWhitespace(bytes, pos);

    // Check for empty object
    if (pos.* < bytes.len and bytes[pos.*] == enc.OBJECT_CLOSE) {
        pos.* += 1; // Consume '}'
        const slice = entries.toOwnedSlice(allocator) catch return DecodeError.OutOfMemory;
        return Value{ .object = slice };
    }

    // Parse entries separated by commas
    while (true) {
        // Parse key (string until ':')
        const key_val = try decodeStringInternal(allocator, bytes, pos, options);
        const key = key_val.string;
        errdefer if (key.len > 0) allocator.free(key);

        skipWhitespace(bytes, pos);

        // Expect ':' after key
        if (pos.* >= bytes.len or bytes[pos.*] != enc.COLON) {
            return DecodeError.UnexpectedByte;
        }
        pos.* += 1; // Consume ':'

        // Parse value
        const val = try decodeValueInternal(allocator, bytes, pos, options);
        errdefer deinitValue(allocator, val);

        entries.append(allocator, .{ .key = key, .value = val }) catch return DecodeError.OutOfMemory;

        skipWhitespace(bytes, pos);

        if (pos.* >= bytes.len) {
            return DecodeError.UnexpectedEndOfInput;
        }

        const next = bytes[pos.*];
        if (next == enc.OBJECT_CLOSE) {
            pos.* += 1; // Consume '}'
            break;
        } else if (next == enc.COMMA) {
            pos.* += 1; // Consume ','
            // Continue to next entry
        } else {
            return DecodeError.UnexpectedByte;
        }
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
            allocator.free(arr);
        },
        .object => |obj| {
            for (obj) |entry| {
                if (entry.key.len > 0) {
                    allocator.free(entry.key);
                }
                deinitValue(allocator, entry.value);
            }
            allocator.free(obj);
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
    const result = try decode(allocator, "[]");
    defer deinitValue(allocator, result);

    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 0), result.array.len);
}

test "decode array with strings" {
    const allocator = std.testing.allocator;
    // "[a,b]"
    const result = try decode(allocator, "[a,b]");
    defer deinitValue(allocator, result);

    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 2), result.array.len);
    try std.testing.expectEqualStrings("a", result.array[0].string);
    try std.testing.expectEqualStrings("b", result.array[1].string);
}

test "decode empty object" {
    const allocator = std.testing.allocator;
    const result = try decode(allocator, "{}");
    defer deinitValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 0), result.object.len);
}

test "decode object with entry" {
    const allocator = std.testing.allocator;
    // "{k:v}"
    const result = try decode(allocator, "{k:v}");
    defer deinitValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 1), result.object.len);
    try std.testing.expectEqualStrings("k", result.object[0].key);
    try std.testing.expectEqualStrings("v", result.object[0].value.string);
}

test "decode nested structure" {
    const allocator = std.testing.allocator;
    // { "arr": ["x"] } = "{arr:[x]}"
    const result = try decode(allocator, "{arr:[x]}");
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
    // Valid object followed by garbage = "{}x"
    const result = decode(allocator, "{}x");
    try std.testing.expectError(DecodeError.TrailingData, result);
}

test "decode with insignificant whitespace" {
    const allocator = std.testing.allocator;
    // Tabs and newlines are insignificant — stripped on parse
    const result = try decode(allocator, "{\n\tarr:\n\t[x,\n\ty]\n}");
    defer deinitValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 1), result.object.len);
    try std.testing.expectEqualStrings("arr", result.object[0].key);

    const arr = result.object[0].value;
    try std.testing.expect(arr == .array);
    try std.testing.expectEqual(@as(usize, 2), arr.array.len);
    try std.testing.expectEqualStrings("x", arr.array[0].string);
    try std.testing.expectEqualStrings("y", arr.array[1].string);
}
