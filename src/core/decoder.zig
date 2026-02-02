//! C0 Decoder - Parse C0 binary format to Value

const std = @import("std");
const Value = @import("value.zig").Value;
const Entry = @import("value.zig").Entry;
const enc = @import("encoding.zig");

pub const DecodeError = error{
    UnexpectedEndOfInput,
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
        for (items.items) |item| {
            deinitValue(allocator, item);
        }
        items.deinit(allocator);
    }

    // Check for empty array (GS US)
    if (pos.* < bytes.len and bytes[pos.*] == enc.US) {
        pos.* += 1; // Consume US
        const slice = items.toOwnedSlice(allocator) catch return DecodeError.OutOfMemory;
        return Value{ .array = slice };
    }

    while (pos.* < bytes.len) {
        // If we see a structural byte that's not part of a nested structure, array ends
        // (This handles malformed input or nested containers)
        const next = bytes[pos.*];
        if (next == enc.RS) {
            // We hit parent object's RS - don't consume, let parent handle it
            break;
        }

        // Parse value (handles GS/FS for nested containers, or string otherwise)
        const item = try decodeValue(allocator, bytes, pos);
        errdefer deinitValue(allocator, item);

        // Expect US after value
        if (pos.* >= bytes.len or bytes[pos.*] != enc.US) {
            return DecodeError.MissingUnitSeparator;
        }
        pos.* += 1; // Consume US

        items.append(allocator, item) catch return DecodeError.OutOfMemory;

        // Check if array ends (next byte is structural or end of input)
        if (pos.* >= bytes.len or enc.isStructural(bytes[pos.*])) {
            break;
        }
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
        for (entries.items) |entry| {
            if (entry.key.len > 0) {
                allocator.free(entry.key);
            }
            deinitValue(allocator, entry.value);
        }
        entries.deinit(allocator);
    }

    // Check for empty object (FS RS)
    if (pos.* < bytes.len and bytes[pos.*] == enc.RS) {
        pos.* += 1; // Consume RS
        const slice = entries.toOwnedSlice(allocator) catch return DecodeError.OutOfMemory;
        return Value{ .object = slice };
    }

    while (pos.* < bytes.len) {
        const next = bytes[pos.*];

        // If we see a structural byte, object ends (shouldn't happen for well-formed input)
        if (enc.isStructural(next)) {
            break;
        }

        // Parse key (string until US)
        const key_val = try decodeString(allocator, bytes, pos);
        const key = key_val.string;
        errdefer if (key.len > 0) allocator.free(key);

        // Expect US after key
        if (pos.* >= bytes.len or bytes[pos.*] != enc.US) {
            if (key.len > 0) allocator.free(key);
            return DecodeError.MissingUnitSeparator;
        }
        pos.* += 1; // Consume US

        // Parse value
        const val = try decodeValue(allocator, bytes, pos);
        errdefer deinitValue(allocator, val);

        // Expect RS after value
        if (pos.* >= bytes.len or bytes[pos.*] != enc.RS) {
            return DecodeError.MissingRecordSeparator;
        }
        pos.* += 1; // Consume RS

        entries.append(allocator, .{ .key = key, .value = val }) catch return DecodeError.OutOfMemory;

        // Check if object ends (next byte is structural or end of input)
        if (pos.* >= bytes.len or enc.isStructural(bytes[pos.*])) {
            break;
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
