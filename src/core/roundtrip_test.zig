//! C0 Round-Trip Tests
//!
//! Comprehensive tests that encode a Value to C0 binary format,
//! decode it back, and verify the result matches the original.

const std = @import("std");
const Value = @import("value.zig").Value;
const Entry = @import("value.zig").Entry;
const encoder = @import("encoder.zig");
const decoder = @import("decoder.zig");

/// Round-trip helper: encode a Value, decode it back, verify equality
/// Returns error if encode/decode fails or values don't match
fn roundTrip(allocator: std.mem.Allocator, original: Value) !void {
    // Encode
    const encoded = try encoder.encode(allocator, original);
    defer allocator.free(encoded);

    // Decode
    const decoded = try decoder.decode(allocator, encoded);
    defer decoder.deinitValue(allocator, decoded);

    // Verify equality
    if (!original.eql(decoded)) {
        return error.RoundTripMismatch;
    }
}

// =============================================================================
// String Round-Trip Tests
// =============================================================================

test "round-trip: empty string" {
    const allocator = std.testing.allocator;
    const val = Value{ .string = "" };
    try roundTrip(allocator, val);
}

test "round-trip: simple string" {
    const allocator = std.testing.allocator;
    const val = Value{ .string = "hello world" };
    try roundTrip(allocator, val);
}

test "round-trip: string with special bytes (0x1C-0x1F)" {
    const allocator = std.testing.allocator;
    // These are old C0 control characters — still need pb-encoding as control chars
    const val = Value{ .string = "before\x1C\x1D\x1E\x1Fafter" };
    try roundTrip(allocator, val);
}

test "round-trip: string with null byte" {
    const allocator = std.testing.allocator;
    const val = Value{ .string = "hello\x00world" };
    try roundTrip(allocator, val);
}

test "round-trip: string with all control characters" {
    const allocator = std.testing.allocator;
    // Test all C0 control characters (0x00-0x1F)
    var buf: [32]u8 = undefined;
    for (0..32) |i| {
        buf[i] = @intCast(i);
    }
    const val = Value{ .string = &buf };
    try roundTrip(allocator, val);
}

test "round-trip: binary data" {
    const allocator = std.testing.allocator;
    // Test high bytes (0x80-0xFF)
    var buf: [128]u8 = undefined;
    for (0..128) |i| {
        buf[i] = @intCast(128 + i);
    }
    const val = Value{ .string = &buf };
    try roundTrip(allocator, val);
}

test "round-trip: unicode string" {
    const allocator = std.testing.allocator;
    const val = Value{ .string = "Hello, \xE4\xB8\x96\xE7\x95\x8C! \xF0\x9F\x8C\x8D" }; // "Hello, World! [globe emoji]" in UTF-8
    try roundTrip(allocator, val);
}

// =============================================================================
// Array Round-Trip Tests
// =============================================================================

test "round-trip: empty array" {
    const allocator = std.testing.allocator;
    const val = Value{ .array = &.{} };
    try roundTrip(allocator, val);
}

test "round-trip: array with single string" {
    const allocator = std.testing.allocator;
    const items = [_]Value{
        .{ .string = "only" },
    };
    const val = Value{ .array = &items };
    try roundTrip(allocator, val);
}

test "round-trip: array with multiple strings" {
    const allocator = std.testing.allocator;
    const items = [_]Value{
        .{ .string = "first" },
        .{ .string = "second" },
        .{ .string = "third" },
    };
    const val = Value{ .array = &items };
    try roundTrip(allocator, val);
}

// NOTE: With bracket-style format, arrays with 2+ empty strings round-trip correctly.
// ["","",""] encodes as "[,,]" which decodes back to 3 empty strings.
// ["",""] encodes as "[,]" which also round-trips.
// The single remaining ambiguity: [""] encodes as "[]" which decodes as an empty array.
// This is a fundamental limitation — a single empty string in an array can't be
// distinguished from an empty array.
test "round-trip: array with empty strings (3)" {
    const allocator = std.testing.allocator;
    const items = [_]Value{
        .{ .string = "" },
        .{ .string = "" },
        .{ .string = "" },
    };
    const val = Value{ .array = &items };
    try roundTrip(allocator, val);
}

test "round-trip: array with empty strings (2)" {
    const allocator = std.testing.allocator;
    const items = [_]Value{
        .{ .string = "" },
        .{ .string = "" },
    };
    const val = Value{ .array = &items };
    try roundTrip(allocator, val);
}

test "round-trip: array with special bytes in strings" {
    const allocator = std.testing.allocator;
    const items = [_]Value{
        .{ .string = "has\x1Cspecial" },
        .{ .string = "bytes\x1D\x1E\x1F" },
    };
    const val = Value{ .array = &items };
    try roundTrip(allocator, val);
}

// =============================================================================
// Object Round-Trip Tests
// =============================================================================

test "round-trip: empty object" {
    const allocator = std.testing.allocator;
    const val = Value{ .object = &.{} };
    try roundTrip(allocator, val);
}

test "round-trip: object with single entry" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .key = "name", .value = .{ .string = "value" } },
    };
    const val = Value{ .object = &entries };
    try roundTrip(allocator, val);
}

test "round-trip: object with multiple entries" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .key = "first", .value = .{ .string = "1" } },
        .{ .key = "second", .value = .{ .string = "2" } },
        .{ .key = "third", .value = .{ .string = "3" } },
    };
    const val = Value{ .object = &entries };
    try roundTrip(allocator, val);
}

// NOTE: Empty keys are valid (the key is just an empty string).
// This was previously a bug but is now fixed.
test "round-trip: object with empty key and value" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .key = "", .value = .{ .string = "" } },
    };
    const val = Value{ .object = &entries };
    try roundTrip(allocator, val);
}

test "round-trip: object with special bytes in key" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .key = "key\x1C\x1D\x1E\x1F", .value = .{ .string = "value" } },
    };
    const val = Value{ .object = &entries };
    try roundTrip(allocator, val);
}

// =============================================================================
// Nested Structure Round-Trip Tests
// =============================================================================

test "round-trip: nested array in object" {
    const allocator = std.testing.allocator;
    const inner_arr = [_]Value{
        .{ .string = "x" },
        .{ .string = "y" },
    };
    const entries = [_]Entry{
        .{ .key = "arr", .value = .{ .array = &inner_arr } },
    };
    const val = Value{ .object = &entries };
    try roundTrip(allocator, val);
}

test "round-trip: nested object in array" {
    const allocator = std.testing.allocator;
    const inner_entries = [_]Entry{
        .{ .key = "k", .value = .{ .string = "v" } },
    };
    const items = [_]Value{
        .{ .object = &inner_entries },
    };
    const val = Value{ .array = &items };
    try roundTrip(allocator, val);
}

test "round-trip: nested empty structures" {
    const allocator = std.testing.allocator;
    // Object containing empty array
    const entries1 = [_]Entry{
        .{ .key = "empty_arr", .value = .{ .array = &.{} } },
    };
    const val1 = Value{ .object = &entries1 };
    try roundTrip(allocator, val1);

    // Array containing empty object
    const items = [_]Value{
        .{ .object = &.{} },
    };
    const val2 = Value{ .array = &items };
    try roundTrip(allocator, val2);
}

test "round-trip: deeply nested array" {
    const allocator = std.testing.allocator;
    // [[["deep"]]]
    const level3 = [_]Value{.{ .string = "deep" }};
    const level2 = [_]Value{.{ .array = &level3 }};
    const level1 = [_]Value{.{ .array = &level2 }};
    const val = Value{ .array = &level1 };
    try roundTrip(allocator, val);
}

test "round-trip: deeply nested object" {
    const allocator = std.testing.allocator;
    // {"a": {"b": {"c": "deep"}}}
    const level3 = [_]Entry{
        .{ .key = "c", .value = .{ .string = "deep" } },
    };
    const level2 = [_]Entry{
        .{ .key = "b", .value = .{ .object = &level3 } },
    };
    const level1 = [_]Entry{
        .{ .key = "a", .value = .{ .object = &level2 } },
    };
    const val = Value{ .object = &level1 };
    try roundTrip(allocator, val);
}

// NOTE: This test was previously failing due to a decoder bug with arrays of objects.
// Fix: decoder only breaks array parsing on RS/US, not on GS/FS (which start nested containers).
test "round-trip: deeply nested mixed structures" {
    const allocator = std.testing.allocator;
    // {"data": [{"items": ["a", "b"]}, {"items": ["c"]}]}
    const items1 = [_]Value{
        .{ .string = "a" },
        .{ .string = "b" },
    };
    const items2 = [_]Value{
        .{ .string = "c" },
    };
    const obj1_entries = [_]Entry{
        .{ .key = "items", .value = .{ .array = &items1 } },
    };
    const obj2_entries = [_]Entry{
        .{ .key = "items", .value = .{ .array = &items2 } },
    };
    const arr = [_]Value{
        .{ .object = &obj1_entries },
        .{ .object = &obj2_entries },
    };
    const entries = [_]Entry{
        .{ .key = "data", .value = .{ .array = &arr } },
    };
    const val = Value{ .object = &entries };
    try roundTrip(allocator, val);
}

test "round-trip: complex structure with special bytes throughout" {
    const allocator = std.testing.allocator;
    // Object with special bytes in keys and values, nested structures
    const inner_arr = [_]Value{
        .{ .string = "item\x1C\x1D" },
        .{ .string = "\x00\x1E\x1F" },
    };
    const inner_obj_entries = [_]Entry{
        .{ .key = "inner\x1C", .value = .{ .string = "val\x1D" } },
    };
    const entries = [_]Entry{
        .{ .key = "arr\x1E", .value = .{ .array = &inner_arr } },
        .{ .key = "obj\x1F", .value = .{ .object = &inner_obj_entries } },
        .{ .key = "str", .value = .{ .string = "\x00\x01\x02\x1C\x1D\x1E\x1F" } },
    };
    const val = Value{ .object = &entries };
    try roundTrip(allocator, val);
}

// =============================================================================
// Edge Case Round-Trip Tests
// =============================================================================

// NOTE: This test was previously failing due to a decoder bug with nested empty arrays.
// Fix: decoder only breaks array parsing on RS/US, not on GS/FS (which start nested containers).
test "round-trip: array of empty arrays" {
    const allocator = std.testing.allocator;
    const items = [_]Value{
        .{ .array = &.{} },
        .{ .array = &.{} },
        .{ .array = &.{} },
    };
    const val = Value{ .array = &items };
    try roundTrip(allocator, val);
}

test "round-trip: object with array and object values" {
    const allocator = std.testing.allocator;
    const arr_items = [_]Value{.{ .string = "elem" }};
    const obj_entries = [_]Entry{
        .{ .key = "k", .value = .{ .string = "v" } },
    };
    const entries = [_]Entry{
        .{ .key = "my_array", .value = .{ .array = &arr_items } },
        .{ .key = "my_object", .value = .{ .object = &obj_entries } },
        .{ .key = "my_string", .value = .{ .string = "text" } },
    };
    const val = Value{ .object = &entries };
    try roundTrip(allocator, val);
}

test "round-trip: large string" {
    const allocator = std.testing.allocator;
    // Create a 10KB string
    var buf: [10 * 1024]u8 = undefined;
    for (0..buf.len) |i| {
        buf[i] = @intCast(i % 256);
    }
    const val = Value{ .string = &buf };
    try roundTrip(allocator, val);
}

test "round-trip: many array elements" {
    const allocator = std.testing.allocator;
    // Array with 100 elements
    var items: [100]Value = undefined;
    for (0..100) |i| {
        items[i] = .{ .string = "element" };
    }
    const val = Value{ .array = &items };
    try roundTrip(allocator, val);
}

test "round-trip: many object entries" {
    const allocator = std.testing.allocator;
    // Object with 50 entries
    var entries: [50]Entry = undefined;
    for (0..50) |i| {
        entries[i] = .{ .key = "key", .value = .{ .string = "value" } };
    }
    const val = Value{ .object = &entries };
    try roundTrip(allocator, val);
}
