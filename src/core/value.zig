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
