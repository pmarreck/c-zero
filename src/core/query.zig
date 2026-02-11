//! C0 Value path query — jq-like access to C0 data
//!
//! Path syntax (jq-compatible subset):
//!   .              → root value
//!   .key           → object field "key"
//!   .key1.key2     → chained field access
//!   .[0]           → array index
//!   .key[0].key2   → mixed chaining
//!
//! Keys may contain alphanumerics, underscores, and hyphens.
//! For keys with other characters, use ["key with spaces"] syntax.

const std = @import("std");
const Value = @import("value.zig").Value;
const Entry = @import("value.zig").Entry;
const encoder = @import("encoder.zig");

pub const PathSegment = union(enum) {
    key: []const u8,
    index: usize,
};

pub const PathError = error{
    InvalidPath,
    EmptyPath,
    UnclosedBracket,
    InvalidIndex,
    EmptyKey,
};

/// Parse a jq-style path into segments.
/// The path must start with '.'. Just '.' means root (returns empty slice).
/// Does not allocate — segments reference slices of the input path string.
pub fn parsePath(allocator: std.mem.Allocator, path: []const u8) (PathError || error{OutOfMemory})![]const PathSegment {
    if (path.len == 0) return PathError.EmptyPath;
    if (path[0] != '.') return PathError.InvalidPath;
    if (path.len == 1) {
        // Just "." = root
        const empty = try allocator.alloc(PathSegment, 0);
        return empty;
    }

    var segments: std.ArrayListUnmanaged(PathSegment) = .{};
    errdefer segments.deinit(allocator);

    var pos: usize = 1; // skip leading '.'

    while (pos < path.len) {
        if (path[pos] == '[') {
            pos += 1;
            if (pos < path.len and path[pos] == '"') {
                // Quoted key: ["key with spaces"]
                pos += 1; // skip opening quote
                const key_start = pos;
                while (pos < path.len and path[pos] != '"') : (pos += 1) {}
                if (pos >= path.len) return PathError.UnclosedBracket;
                const key = path[key_start..pos];
                pos += 1; // skip closing quote
                if (pos >= path.len or path[pos] != ']') return PathError.UnclosedBracket;
                pos += 1; // skip ']'
                try segments.append(allocator, .{ .key = key });
            } else {
                // Numeric index: [0]
                const idx_start = pos;
                while (pos < path.len and path[pos] >= '0' and path[pos] <= '9') : (pos += 1) {}
                if (pos == idx_start) return PathError.InvalidIndex;
                if (pos >= path.len or path[pos] != ']') return PathError.UnclosedBracket;
                const idx = std.fmt.parseInt(usize, path[idx_start..pos], 10) catch return PathError.InvalidIndex;
                pos += 1; // skip ']'
                try segments.append(allocator, .{ .index = idx });
            }
        } else if (path[pos] == '.') {
            pos += 1; // skip '.'
            const key_start = pos;
            while (pos < path.len and path[pos] != '.' and path[pos] != '[') : (pos += 1) {}
            if (pos == key_start) return PathError.EmptyKey;
            try segments.append(allocator, .{ .key = path[key_start..pos] });
        } else {
            // Key directly after leading '.'
            const key_start = pos;
            while (pos < path.len and path[pos] != '.' and path[pos] != '[') : (pos += 1) {}
            if (pos == key_start) return PathError.EmptyKey;
            try segments.append(allocator, .{ .key = path[key_start..pos] });
        }
    }

    return segments.toOwnedSlice(allocator);
}

/// Traverse a Value tree following the given path segments.
/// Returns the sub-value at the path, or null if any segment fails to match.
pub fn queryValue(val: Value, segments: []const PathSegment) ?Value {
    var current = val;
    for (segments) |seg| {
        switch (seg) {
            .key => |key| {
                switch (current) {
                    .object => |entries| {
                        var found = false;
                        for (entries) |entry| {
                            if (std.mem.eql(u8, entry.key, key)) {
                                current = entry.value;
                                found = true;
                                break;
                            }
                        }
                        if (!found) return null;
                    },
                    else => return null,
                }
            },
            .index => |idx| {
                switch (current) {
                    .array => |items| {
                        if (idx >= items.len) return null;
                        current = items[idx];
                    },
                    else => return null,
                }
            },
        }
    }
    return current;
}

/// Set a value at the given path, returning a new Value tree.
/// If the path doesn't exist, returns an error.
/// The caller is responsible for memory management.
pub fn setValue(allocator: std.mem.Allocator, root: Value, segments: []const PathSegment, new_value: Value) !Value {
    if (segments.len == 0) {
        // Setting root — just return the new value
        return new_value;
    }

    // Recursive copy-on-write: rebuild path from root to target
    return setValueRecursive(allocator, root, segments, 0, new_value);
}

fn setValueRecursive(allocator: std.mem.Allocator, current: Value, segments: []const PathSegment, depth: usize, new_value: Value) !Value {
    const seg = segments[depth];
    const is_last = depth + 1 == segments.len;

    switch (seg) {
        .key => |key| {
            switch (current) {
                .object => |entries| {
                    const new_entries = try allocator.alloc(Entry, entries.len);
                    for (entries, 0..) |entry, i| {
                        if (std.mem.eql(u8, entry.key, key)) {
                            new_entries[i] = .{
                                .key = entry.key,
                                .value = if (is_last)
                                    new_value
                                else
                                    try setValueRecursive(allocator, entry.value, segments, depth + 1, new_value),
                            };
                        } else {
                            new_entries[i] = entry;
                        }
                    }
                    return Value{ .object = new_entries };
                },
                else => return error.PathNotFound,
            }
        },
        .index => |idx| {
            switch (current) {
                .array => |items| {
                    if (idx >= items.len) return error.PathNotFound;
                    const new_items = try allocator.alloc(Value, items.len);
                    @memcpy(new_items, items);
                    new_items[idx] = if (is_last)
                        new_value
                    else
                        try setValueRecursive(allocator, items[idx], segments, depth + 1, new_value);
                    return Value{ .array = new_items };
                },
                else => return error.PathNotFound,
            }
        },
    }
}

/// Format a query result for output. Strings are emitted raw (no C0 encoding),
/// structures are emitted as compact C0 text.
pub fn formatResult(allocator: std.mem.Allocator, val: Value) ![]u8 {
    switch (val) {
        .string => |s| {
            const result = try allocator.alloc(u8, s.len + 1);
            @memcpy(result[0..s.len], s);
            result[s.len] = '\n';
            return result;
        },
        .array, .object => {
            // Encode as compact C0 text
            const c0_bytes = try encoder.encode(allocator, val);
            const result = try allocator.alloc(u8, c0_bytes.len + 1);
            @memcpy(result[0..c0_bytes.len], c0_bytes);
            result[c0_bytes.len] = '\n';
            allocator.free(c0_bytes);
            return result;
        },
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

test "parsePath: root" {
    const allocator = std.testing.allocator;
    const segments = try parsePath(allocator, ".");
    defer allocator.free(segments);
    try std.testing.expectEqual(@as(usize, 0), segments.len);
}

test "parsePath: single key" {
    const allocator = std.testing.allocator;
    const segments = try parsePath(allocator, ".name");
    defer allocator.free(segments);
    try std.testing.expectEqual(@as(usize, 1), segments.len);
    try std.testing.expectEqualStrings("name", segments[0].key);
}

test "parsePath: chained keys" {
    const allocator = std.testing.allocator;
    const segments = try parsePath(allocator, ".user.name");
    defer allocator.free(segments);
    try std.testing.expectEqual(@as(usize, 2), segments.len);
    try std.testing.expectEqualStrings("user", segments[0].key);
    try std.testing.expectEqualStrings("name", segments[1].key);
}

test "parsePath: array index" {
    const allocator = std.testing.allocator;
    const segments = try parsePath(allocator, ".[0]");
    defer allocator.free(segments);
    try std.testing.expectEqual(@as(usize, 1), segments.len);
    try std.testing.expectEqual(@as(usize, 0), segments[0].index);
}

test "parsePath: mixed key and index" {
    const allocator = std.testing.allocator;
    const segments = try parsePath(allocator, ".users[0].name");
    defer allocator.free(segments);
    try std.testing.expectEqual(@as(usize, 3), segments.len);
    try std.testing.expectEqualStrings("users", segments[0].key);
    try std.testing.expectEqual(@as(usize, 0), segments[1].index);
    try std.testing.expectEqualStrings("name", segments[2].key);
}

test "parsePath: quoted key" {
    const allocator = std.testing.allocator;
    const segments = try parsePath(allocator, ".[\"key with spaces\"]");
    defer allocator.free(segments);
    try std.testing.expectEqual(@as(usize, 1), segments.len);
    try std.testing.expectEqualStrings("key with spaces", segments[0].key);
}

test "parsePath: errors" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(PathError.EmptyPath, parsePath(allocator, ""));
    try std.testing.expectError(PathError.InvalidPath, parsePath(allocator, "nope"));
    try std.testing.expectError(PathError.UnclosedBracket, parsePath(allocator, ".[0"));
    try std.testing.expectError(PathError.InvalidIndex, parsePath(allocator, ".[]"));
}

test "queryValue: object key" {
    const entries = &[_]Entry{
        .{ .key = "name", .value = .{ .string = "Alice" } },
        .{ .key = "age", .value = .{ .string = "30" } },
    };
    const val = Value{ .object = entries };

    const result = queryValue(val, &.{.{ .key = "name" }});
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Alice", result.?.string);
}

test "queryValue: array index" {
    const items = &[_]Value{
        .{ .string = "a" },
        .{ .string = "b" },
        .{ .string = "c" },
    };
    const val = Value{ .array = items };

    const result = queryValue(val, &.{.{ .index = 1 }});
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("b", result.?.string);
}

test "queryValue: nested path" {
    const inner_entries = &[_]Entry{
        .{ .key = "name", .value = .{ .string = "Alice" } },
    };
    const items = &[_]Value{
        .{ .object = inner_entries },
    };
    const entries = &[_]Entry{
        .{ .key = "users", .value = .{ .array = items } },
    };
    const val = Value{ .object = entries };

    const result = queryValue(val, &.{ .{ .key = "users" }, .{ .index = 0 }, .{ .key = "name" } });
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Alice", result.?.string);
}

test "queryValue: missing key returns null" {
    const entries = &[_]Entry{
        .{ .key = "name", .value = .{ .string = "Alice" } },
    };
    const val = Value{ .object = entries };

    const result = queryValue(val, &.{.{ .key = "missing" }});
    try std.testing.expect(result == null);
}

test "queryValue: index out of bounds returns null" {
    const items = &[_]Value{
        .{ .string = "a" },
    };
    const val = Value{ .array = items };

    const result = queryValue(val, &.{.{ .index = 5 }});
    try std.testing.expect(result == null);
}

test "setValue: replace string value" {
    const allocator = std.testing.allocator;

    const entries = &[_]Entry{
        .{ .key = "name", .value = .{ .string = "Alice" } },
        .{ .key = "age", .value = .{ .string = "30" } },
    };
    const val = Value{ .object = entries };

    const new_val = try setValue(allocator, val, &.{.{ .key = "name" }}, .{ .string = "Bob" });
    defer allocator.free(new_val.object);

    try std.testing.expectEqualStrings("Bob", new_val.object[0].value.string);
    try std.testing.expectEqualStrings("30", new_val.object[1].value.string);
}

test "setValue: replace nested value" {
    const allocator = std.testing.allocator;

    const inner_items = &[_]Value{ .{ .string = "a" }, .{ .string = "b" } };
    const entries = &[_]Entry{
        .{ .key = "items", .value = .{ .array = inner_items } },
    };
    const val = Value{ .object = entries };

    const new_val = try setValue(allocator, val, &.{ .{ .key = "items" }, .{ .index = 1 } }, .{ .string = "x" });
    defer {
        allocator.free(new_val.object[0].value.array);
        allocator.free(new_val.object);
    }

    try std.testing.expectEqualStrings("a", new_val.object[0].value.array[0].string);
    try std.testing.expectEqualStrings("x", new_val.object[0].value.array[1].string);
}
