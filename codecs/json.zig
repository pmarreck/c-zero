//! JSON Codec - Bidirectional JSON ↔ C0 with type-prefixed scalars
//!
//! JSON values are represented in C0 with single-character type prefixes:
//!   "hello  → JSON string "hello"     (double-quote prefix)
//!   i42    → JSON integer 42          (i prefix)
//!   f3.14  → JSON float 3.14         (f prefix)
//!   bT     → JSON boolean true        (b prefix + T/F)
//!   bF     → JSON boolean false
//!   n      → JSON null
//!
//! Arrays and objects map directly to C0 arrays and objects.
//! Object keys have no prefix (they're always strings in both formats).
//!
//! C0 output structure:
//!   {format:json, value:<converted JSON>}

const std = @import("std");
const core = @import("c0_core");
const codec = @import("mod.zig");

const Value = core.Value;
const Entry = core.Entry;
const CodecInfo = codec.CodecInfo;
const CodecOptions = codec.CodecOptions;
const CodecError = codec.CodecError;

const json_content = core.json_content;
const JsonValue = json_content.JsonValue;
const JsonEntry = json_content.JsonEntry;

pub const JsonCodec = struct {
    pub fn getInfo(_: *JsonCodec) CodecInfo {
        return .{
            .name = "json",
            .description = "JSON format (bidirectional with type-prefixed scalars)",
            .extensions = &.{".json"},
            .magic = &.{},
            .format_names = &.{"json"},
            .supports_faithful = true,
            .supports_editable = true,
        };
    }

    pub fn expandImpl(_: *JsonCodec, allocator: std.mem.Allocator, data: []const u8, _: CodecOptions) CodecError!Value {
        return expandJson(allocator, data);
    }

    pub fn collapseImpl(_: *JsonCodec, allocator: std.mem.Allocator, value: Value, _: CodecOptions) CodecError![]u8 {
        return collapseJson(allocator, value);
    }
};

// ── Expand: JSON bytes → C0 Value ──────────────────────────────────────

fn expandJson(allocator: std.mem.Allocator, data: []const u8) CodecError!Value {
    const json_val = json_content.parseJson(allocator, data) catch return CodecError.InvalidFormat;

    const c0_val = jsonToC0(allocator, json_val) catch return CodecError.OutOfMemory;

    const entries = allocator.alloc(Entry, 2) catch return CodecError.OutOfMemory;
    entries[0] = .{ .key = allocator.dupe(u8, "format") catch return CodecError.OutOfMemory, .value = .{ .string = allocator.dupe(u8, "json") catch return CodecError.OutOfMemory } };
    entries[1] = .{ .key = allocator.dupe(u8, "value") catch return CodecError.OutOfMemory, .value = c0_val };

    return Value{ .object = entries };
}

/// Convert JsonValue → C0 Value with type prefixes
fn jsonToC0(allocator: std.mem.Allocator, jv: JsonValue) error{OutOfMemory}!Value {
    switch (jv) {
        .string => |s| {
            // Prefix with " to mark as string type
            const result = try allocator.alloc(u8, 1 + s.len);
            result[0] = '"';
            @memcpy(result[1..], s);
            return Value{ .string = result };
        },
        .number => |n| {
            // Integer (i prefix) vs float (f prefix) based on presence of . or e/E
            const is_float = for (n) |c| {
                if (c == '.' or c == 'e' or c == 'E') break true;
            } else false;
            const prefix: u8 = if (is_float) 'f' else 'i';
            const result = try allocator.alloc(u8, 1 + n.len);
            result[0] = prefix;
            @memcpy(result[1..], n);
            return Value{ .string = result };
        },
        .boolean => |b| {
            return Value{ .string = try allocator.dupe(u8, if (b) "bT" else "bF") };
        },
        .null => {
            return Value{ .string = try allocator.dupe(u8, "n") };
        },
        .array => |arr| {
            const items = try allocator.alloc(Value, arr.len);
            for (arr, 0..) |item, idx| {
                items[idx] = try jsonToC0(allocator, item);
            }
            return Value{ .array = items };
        },
        .object => |obj_entries| {
            const c0_entries = try allocator.alloc(Entry, obj_entries.len);
            for (obj_entries, 0..) |entry, idx| {
                c0_entries[idx] = .{
                    .key = try allocator.dupe(u8, entry.key),
                    .value = try jsonToC0(allocator, entry.value),
                };
            }
            return Value{ .object = c0_entries };
        },
    }
}

// ── Collapse: C0 Value → JSON bytes ────────────────────────────────────

fn collapseJson(allocator: std.mem.Allocator, value: Value) CodecError![]u8 {
    // Extract the "value" entry from {format:json, value:...}
    const inner = switch (value) {
        .object => |entries| blk: {
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, "value")) break :blk entry.value;
            }
            return CodecError.InvalidFormat;
        },
        else => return CodecError.InvalidFormat,
    };

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    c0ToJson(allocator, &result, inner, 0) catch return CodecError.OutOfMemory;
    result.append(allocator, '\n') catch return CodecError.OutOfMemory;

    return result.toOwnedSlice(allocator) catch return CodecError.OutOfMemory;
}

/// Convert C0 Value with type prefixes → JSON text
fn c0ToJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), val: Value, depth: usize) error{OutOfMemory}!void {
    switch (val) {
        .string => |s| try emitJsonScalar(allocator, out, s),
        .array => |items| {
            if (items.len == 0) {
                try out.appendSlice(allocator, "[]");
                return;
            }
            try out.appendSlice(allocator, "[\n");
            for (items, 0..) |item, idx| {
                try writeIndent(allocator, out, depth + 1);
                try c0ToJson(allocator, out, item, depth + 1);
                if (idx < items.len - 1) try out.append(allocator, ',');
                try out.append(allocator, '\n');
            }
            try writeIndent(allocator, out, depth);
            try out.append(allocator, ']');
        },
        .object => |entries| {
            if (entries.len == 0) {
                try out.appendSlice(allocator, "{}");
                return;
            }
            try out.appendSlice(allocator, "{\n");
            for (entries, 0..) |entry, idx| {
                try writeIndent(allocator, out, depth + 1);
                try out.append(allocator, '"');
                try writeJsonEscaped(allocator, out, entry.key);
                try out.appendSlice(allocator, "\": ");
                try c0ToJson(allocator, out, entry.value, depth + 1);
                if (idx < entries.len - 1) try out.append(allocator, ',');
                try out.append(allocator, '\n');
            }
            try writeIndent(allocator, out, depth);
            try out.append(allocator, '}');
        },
    }
}

/// Emit a C0 type-prefixed scalar as JSON
fn emitJsonScalar(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) error{OutOfMemory}!void {
    if (s.len == 0) {
        // Empty string → JSON empty string
        try out.appendSlice(allocator, "\"\"");
        return;
    }
    switch (s[0]) {
        '"' => {
            // String type: strip prefix, emit as JSON string
            try out.append(allocator, '"');
            try writeJsonEscaped(allocator, out, s[1..]);
            try out.append(allocator, '"');
        },
        'b' => {
            if (s.len == 2 and s[1] == 'T') {
                try out.appendSlice(allocator, "true");
            } else if (s.len == 2 and s[1] == 'F') {
                try out.appendSlice(allocator, "false");
            } else {
                // Unrecognized — emit as JSON string
                try emitAsJsonString(allocator, out, s);
            }
        },
        'n' => {
            if (s.len == 1) {
                try out.appendSlice(allocator, "null");
            } else {
                try emitAsJsonString(allocator, out, s);
            }
        },
        'i', 'f' => {
            if (s.len > 1) {
                // Number type: strip prefix, emit raw
                try out.appendSlice(allocator, s[1..]);
            } else {
                try emitAsJsonString(allocator, out, s);
            }
        },
        else => {
            // Unknown prefix — emit as JSON string
            try emitAsJsonString(allocator, out, s);
        },
    }
}

fn emitAsJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) error{OutOfMemory}!void {
    try out.append(allocator, '"');
    try writeJsonEscaped(allocator, out, s);
    try out.append(allocator, '"');
}

fn writeIndent(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), depth: usize) error{OutOfMemory}!void {
    for (0..depth) |_| {
        try out.appendSlice(allocator, "  ");
    }
}

fn writeJsonEscaped(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) error{OutOfMemory}!void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0C => try out.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{c}) catch unreachable;
                    try out.appendSlice(allocator, &buf);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
}

fn hexDigit(v: u4) u8 {
    return if (v < 10) '0' + v else 'a' + v - 10;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "JSON codec expand simple object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var json_codec = JsonCodec{};
    const c = codec.Codec.init(&json_codec);

    const result = try c.expand(allocator,
        \\{"name": "Alice", "age": 30}
    , .{});

    // Top-level: {format:json, value:...}
    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 2), result.object.len);
    try std.testing.expectEqualStrings("format", result.object[0].key);
    try std.testing.expectEqualStrings("json", result.object[0].value.string);
    try std.testing.expectEqualStrings("value", result.object[1].key);

    // Inner object
    const inner = result.object[1].value;
    try std.testing.expect(inner == .object);
    try std.testing.expectEqualStrings("name", inner.object[0].key);
    try std.testing.expectEqualStrings("\"Alice", inner.object[0].value.string);
    try std.testing.expectEqualStrings("age", inner.object[1].key);
    try std.testing.expectEqualStrings("i30", inner.object[1].value.string);
}

test "JSON codec type prefixes for all JSON types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var json_codec = JsonCodec{};
    const c = codec.Codec.init(&json_codec);

    const result = try c.expand(allocator,
        \\["hello", 42, 3.14, true, false, null]
    , .{});

    const inner = result.object[1].value;
    try std.testing.expect(inner == .array);
    const items = inner.array;
    try std.testing.expectEqual(@as(usize, 6), items.len);
    try std.testing.expectEqualStrings("\"hello", items[0].string);
    try std.testing.expectEqualStrings("i42", items[1].string);
    try std.testing.expectEqualStrings("f3.14", items[2].string);
    try std.testing.expectEqualStrings("bT", items[3].string);
    try std.testing.expectEqualStrings("bF", items[4].string);
    try std.testing.expectEqualStrings("n", items[5].string);
}

test "JSON codec collapse to pretty JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build a C0 Value representing {format:json, value:{name:"Alice, age:i30}}
    const inner_entries = try allocator.alloc(Entry, 2);
    inner_entries[0] = .{ .key = "name", .value = .{ .string = "\"Alice" } };
    inner_entries[1] = .{ .key = "age", .value = .{ .string = "i30" } };

    const top_entries = try allocator.alloc(Entry, 2);
    top_entries[0] = .{ .key = "format", .value = .{ .string = "json" } };
    top_entries[1] = .{ .key = "value", .value = .{ .object = inner_entries } };

    var json_codec = JsonCodec{};
    const c = codec.Codec.init(&json_codec);
    const output = try c.collapse(allocator, .{ .object = top_entries }, .{});

    const expected =
        \\{
        \\  "name": "Alice",
        \\  "age": 30
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, output);
}

test "JSON codec round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input =
        \\{
        \\  "name": "Alice",
        \\  "scores": [100, 95.5, 87],
        \\  "active": true,
        \\  "notes": null
        \\}
    ;

    var json_codec = JsonCodec{};
    const c = codec.Codec.init(&json_codec);

    // Expand JSON → C0 Value
    const value = try c.expand(allocator, input, .{});

    // Collapse C0 Value → JSON
    const output = try c.collapse(allocator, value, .{});

    // Re-expand to verify semantic round-trip
    const value2 = try c.expand(allocator, output, .{});

    // Compare inner values
    try std.testing.expect(value.object[1].value.eql(value2.object[1].value));
}

test "JSON codec full pipeline round-trip (expand → encode → decode → collapse)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input =
        \\{"greeting": "hello, world", "count": 42, "pi": 3.14159, "ok": true, "nothing": null}
    ;

    var json_codec = JsonCodec{};
    const c = codec.Codec.init(&json_codec);

    // Expand JSON → C0 Value
    const value = try c.expand(allocator, input, .{});

    // Encode C0 Value → C0 wire format
    const c0_bytes = core.encode(allocator, value) catch return error.CoreEncodeError;

    // Decode C0 wire format → C0 Value
    const decoded = core.decode(allocator, c0_bytes) catch return error.CoreDecodeError;

    // Collapse C0 Value → JSON
    const output = try c.collapse(allocator, decoded, .{});

    // Re-expand to verify semantic equivalence
    const value3 = try c.expand(allocator, output, .{});
    try std.testing.expect(value.object[1].value.eql(value3.object[1].value));
}

test "JSON codec handles nested structures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input =
        \\{"users": [{"name": "Alice", "tags": ["admin", "user"]}, {"name": "Bob", "tags": []}]}
    ;

    var json_codec = JsonCodec{};
    const c = codec.Codec.init(&json_codec);

    const value = try c.expand(allocator, input, .{});
    const output = try c.collapse(allocator, value, .{});
    const value2 = try c.expand(allocator, output, .{});

    try std.testing.expect(value.object[1].value.eql(value2.object[1].value));
}

test "JSON codec rejects non-JSON input" {
    var json_codec = JsonCodec{};
    const c = codec.Codec.init(&json_codec);

    const result = c.expand(std.testing.allocator, "not json at all {{{", .{});
    try std.testing.expectError(CodecError.InvalidFormat, result);
}

test "JSON codec info" {
    var json_codec = JsonCodec{};
    const c = codec.Codec.init(&json_codec);
    const info = c.info();

    try std.testing.expectEqualStrings("json", info.name);
    try std.testing.expectEqual(@as(usize, 1), info.extensions.len);
    try std.testing.expectEqualStrings(".json", info.extensions[0]);
    try std.testing.expect(info.supports_faithful);
    try std.testing.expect(info.supports_editable);
}

test "JSON codec collapse all scalar types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Array with all scalar types
    const items = try allocator.alloc(Value, 6);
    items[0] = .{ .string = "\"hello" };
    items[1] = .{ .string = "i42" };
    items[2] = .{ .string = "f3.14" };
    items[3] = .{ .string = "bT" };
    items[4] = .{ .string = "bF" };
    items[5] = .{ .string = "n" };

    const top_entries = try allocator.alloc(Entry, 2);
    top_entries[0] = .{ .key = "format", .value = .{ .string = "json" } };
    top_entries[1] = .{ .key = "value", .value = .{ .array = items } };

    var json_codec = JsonCodec{};
    const c = codec.Codec.init(&json_codec);
    const output = try c.collapse(allocator, .{ .object = top_entries }, .{});

    const expected =
        \\[
        \\  "hello",
        \\  42,
        \\  3.14,
        \\  true,
        \\  false,
        \\  null
        \\]
        \\
    ;
    try std.testing.expectEqualStrings(expected, output);
}
