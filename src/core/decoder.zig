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

    // Ensure we consumed all input
    if (pos != bytes.len) {
        deinitValue(allocator, result);
        return DecodeError.TrailingData;
    }

    return result;
}

fn decodeValueInternal(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize, options: DecodeOptions) DecodeError!Value {
    if (pos.* >= bytes.len) {
        // Empty input = empty string
        return Value{ .string = "" };
    }

    const first = bytes[pos.*];

    if (first == enc.GS) {
        return decodeArrayInternal(allocator, bytes, pos, options);
    } else if (first == enc.FS) {
        return decodeObjectInternal(allocator, bytes, pos, options);
    } else {
        return decodeStringInternal(allocator, bytes, pos, options);
    }
}

fn decodeStringInternal(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize, options: DecodeOptions) DecodeError!Value {
    const start = pos.*;

    // Read until structural byte or end
    while (pos.* < bytes.len and !enc.isStructural(bytes[pos.*])) {
        pos.* += 1;
    }

    const encoded_payload = bytes[start..pos.*];

    // Decode the payload using smart decoding
    const decoded = enc.decodePayloadSmart(allocator, encoded_payload, .{
        .keep_printable = options.keep_printable,
    }) catch |err| switch (err) {
        error.OutOfMemory => return DecodeError.OutOfMemory,
    };

    return Value{ .string = decoded };
}

// Legacy internal functions that call the new ones with default options
fn decodeValue(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize) DecodeError!Value {
    return decodeValueInternal(allocator, bytes, pos, .{});
}

fn decodeString(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize) DecodeError!Value {
    return decodeStringInternal(allocator, bytes, pos, .{});
}

fn decodeArrayInternal(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize, options: DecodeOptions) DecodeError!Value {
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
        const item = try decodeValueInternal(allocator, bytes, pos, options);
        errdefer deinitValue(allocator, item);

        // Expect US after value
        if (pos.* >= bytes.len or bytes[pos.*] != enc.US) {
            return DecodeError.MissingUnitSeparator;
        }
        pos.* += 1; // Consume US

        items.append(allocator, item) catch return DecodeError.OutOfMemory;

        // Check if array ends:
        // - End of input: done
        // - RS: we're inside a parent object, let it handle the RS
        // - US: parent array's terminator (we're a nested array element)
        // - GS/FS: next element is a nested container, continue parsing
        if (pos.* >= bytes.len) {
            break;
        }
        const next_byte = bytes[pos.*];
        if (next_byte == enc.RS or next_byte == enc.US) {
            break;
        }
    }

    const slice = items.toOwnedSlice(allocator) catch return DecodeError.OutOfMemory;
    return Value{ .array = slice };
}

fn decodeObjectInternal(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize, options: DecodeOptions) DecodeError!Value {
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

        // RS means object is done (we already checked empty object above)
        if (next == enc.RS) {
            pos.* += 1; // Consume the RS
            break;
        }

        // FS/GS would be malformed (key must be a string), but let decodeString handle it
        // US means empty key, which is valid - continue to parse

        // Parse key (string until US)
        const key_val = try decodeStringInternal(allocator, bytes, pos, options);
        const key = key_val.string;
        errdefer if (key.len > 0) allocator.free(key);

        // Expect US after key
        if (pos.* >= bytes.len or bytes[pos.*] != enc.US) {
            return DecodeError.MissingUnitSeparator;
        }
        pos.* += 1; // Consume US

        // Parse value
        const val = try decodeValueInternal(allocator, bytes, pos, options);
        errdefer deinitValue(allocator, val);

        // Expect RS after value
        if (pos.* >= bytes.len or bytes[pos.*] != enc.RS) {
            return DecodeError.MissingRecordSeparator;
        }
        pos.* += 1; // Consume RS

        entries.append(allocator, .{ .key = key, .value = val }) catch return DecodeError.OutOfMemory;

        // After consuming RS, check if object ends:
        // - End of input: done
        // - Any structural byte (US from parent array, RS, FS, GS): done
        // - Non-structural: next entry's key, continue
        if (pos.* >= bytes.len or enc.isStructural(bytes[pos.*])) {
            break;
        }
    }

    const slice = entries.toOwnedSlice(allocator) catch return DecodeError.OutOfMemory;
    return Value{ .object = slice };
}

// Legacy wrappers for backwards compatibility
fn decodeArray(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize) DecodeError!Value {
    return decodeArrayInternal(allocator, bytes, pos, .{});
}

fn decodeObject(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize) DecodeError!Value {
    return decodeObjectInternal(allocator, bytes, pos, .{});
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
    // GS "a" US "b" US = "[a:b:"
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
    // FS "k" US "v" RS = "{k:v,"
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
    // { "arr": ["x"] } = FS "arr" US GS "x" US RS = "{arr:[x:,"
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
    // Valid object followed by garbage = "{,x"
    const input = [_]u8{ enc.FS, enc.RS, 'x' };

    const result = decode(allocator, &input);
    try std.testing.expectError(DecodeError.TrailingData, result);
}
