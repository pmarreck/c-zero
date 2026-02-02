//! JSON Subset <-> C0 Demo
//!
//! Demonstrates round-trip conversion between JSON (strings, arrays, objects only)
//! and C0 binary format with deeply nested structures.
//!
//! Run with: zig build run-json-demo

const std = @import("std");
const core = @import("c0_core");

const Value = core.Value;
const Entry = core.Entry;

// ============================================================================
// JSON Parser (subset: strings, arrays, objects only)
// ============================================================================

const JsonError = error{
    UnexpectedToken,
    UnexpectedEndOfInput,
    InvalidEscape,
    UnsupportedType, // numbers, booleans, null
    OutOfMemory,
};

fn parseJson(allocator: std.mem.Allocator, input: []const u8) JsonError!Value {
    var pos: usize = 0;
    const result = try parseValue(allocator, input, &pos);
    skipWhitespace(input, &pos);
    if (pos != input.len) {
        // Trailing data - but we'll allow it for flexibility
    }
    return result;
}

fn skipWhitespace(input: []const u8, pos: *usize) void {
    while (pos.* < input.len and (input[pos.*] == ' ' or input[pos.*] == '\t' or
        input[pos.*] == '\n' or input[pos.*] == '\r'))
    {
        pos.* += 1;
    }
}

fn parseValue(allocator: std.mem.Allocator, input: []const u8, pos: *usize) JsonError!Value {
    skipWhitespace(input, pos);

    if (pos.* >= input.len) return JsonError.UnexpectedEndOfInput;

    const c = input[pos.*];

    if (c == '"') {
        return parseString(allocator, input, pos);
    } else if (c == '[') {
        return parseArray(allocator, input, pos);
    } else if (c == '{') {
        return parseObject(allocator, input, pos);
    } else if (c == 't' or c == 'f') {
        return JsonError.UnsupportedType; // boolean
    } else if (c == 'n') {
        return JsonError.UnsupportedType; // null
    } else if (c == '-' or (c >= '0' and c <= '9')) {
        return JsonError.UnsupportedType; // number
    } else {
        return JsonError.UnexpectedToken;
    }
}

fn parseString(allocator: std.mem.Allocator, input: []const u8, pos: *usize) JsonError!Value {
    if (pos.* >= input.len or input[pos.*] != '"') return JsonError.UnexpectedToken;
    pos.* += 1; // consume opening quote

    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    while (pos.* < input.len) {
        const c = input[pos.*];

        if (c == '"') {
            pos.* += 1; // consume closing quote
            const str = result.toOwnedSlice(allocator) catch return JsonError.OutOfMemory;
            return Value{ .string = str };
        } else if (c == '\\') {
            pos.* += 1;
            if (pos.* >= input.len) return JsonError.UnexpectedEndOfInput;
            const escaped = input[pos.*];
            const replacement: u8 = switch (escaped) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 0x08,
                'f' => 0x0C,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'u' => {
                    // Skip unicode escapes for now - just pass through
                    pos.* += 1;
                    if (pos.* + 4 > input.len) return JsonError.UnexpectedEndOfInput;
                    pos.* += 4;
                    continue;
                },
                else => return JsonError.InvalidEscape,
            };
            result.append(allocator, replacement) catch return JsonError.OutOfMemory;
            pos.* += 1;
        } else {
            result.append(allocator, c) catch return JsonError.OutOfMemory;
            pos.* += 1;
        }
    }

    return JsonError.UnexpectedEndOfInput;
}

fn parseArray(allocator: std.mem.Allocator, input: []const u8, pos: *usize) JsonError!Value {
    if (pos.* >= input.len or input[pos.*] != '[') return JsonError.UnexpectedToken;
    pos.* += 1; // consume '['

    var items: std.ArrayListUnmanaged(Value) = .{};
    errdefer {
        for (items.items) |item| {
            freeValue(allocator, item);
        }
        items.deinit(allocator);
    }

    skipWhitespace(input, pos);

    // Empty array
    if (pos.* < input.len and input[pos.*] == ']') {
        pos.* += 1;
        const slice = items.toOwnedSlice(allocator) catch return JsonError.OutOfMemory;
        return Value{ .array = slice };
    }

    while (true) {
        const item = try parseValue(allocator, input, pos);
        items.append(allocator, item) catch return JsonError.OutOfMemory;

        skipWhitespace(input, pos);

        if (pos.* >= input.len) return JsonError.UnexpectedEndOfInput;

        if (input[pos.*] == ']') {
            pos.* += 1;
            break;
        } else if (input[pos.*] == ',') {
            pos.* += 1;
        } else {
            return JsonError.UnexpectedToken;
        }
    }

    const slice = items.toOwnedSlice(allocator) catch return JsonError.OutOfMemory;
    return Value{ .array = slice };
}

fn parseObject(allocator: std.mem.Allocator, input: []const u8, pos: *usize) JsonError!Value {
    if (pos.* >= input.len or input[pos.*] != '{') return JsonError.UnexpectedToken;
    pos.* += 1; // consume '{'

    var entries: std.ArrayListUnmanaged(Entry) = .{};
    errdefer {
        for (entries.items) |entry| {
            if (entry.key.len > 0) allocator.free(entry.key);
            freeValue(allocator, entry.value);
        }
        entries.deinit(allocator);
    }

    skipWhitespace(input, pos);

    // Empty object
    if (pos.* < input.len and input[pos.*] == '}') {
        pos.* += 1;
        const slice = entries.toOwnedSlice(allocator) catch return JsonError.OutOfMemory;
        return Value{ .object = slice };
    }

    while (true) {
        skipWhitespace(input, pos);

        // Parse key (must be string)
        const key_val = try parseString(allocator, input, pos);
        const key = key_val.string;
        errdefer allocator.free(key);

        skipWhitespace(input, pos);

        // Expect colon
        if (pos.* >= input.len or input[pos.*] != ':') return JsonError.UnexpectedToken;
        pos.* += 1;

        // Parse value
        const val = try parseValue(allocator, input, pos);

        entries.append(allocator, .{ .key = key, .value = val }) catch return JsonError.OutOfMemory;

        skipWhitespace(input, pos);

        if (pos.* >= input.len) return JsonError.UnexpectedEndOfInput;

        if (input[pos.*] == '}') {
            pos.* += 1;
            break;
        } else if (input[pos.*] == ',') {
            pos.* += 1;
        } else {
            return JsonError.UnexpectedToken;
        }
    }

    const slice = entries.toOwnedSlice(allocator) catch return JsonError.OutOfMemory;
    return Value{ .object = slice };
}

fn freeValue(allocator: std.mem.Allocator, val: Value) void {
    switch (val) {
        .string => |s| if (s.len > 0) allocator.free(s),
        .array => |arr| {
            for (arr) |item| freeValue(allocator, item);
            allocator.free(arr);
        },
        .object => |obj| {
            for (obj) |entry| {
                if (entry.key.len > 0) allocator.free(entry.key);
                freeValue(allocator, entry.value);
            }
            allocator.free(obj);
        },
    }
}

// ============================================================================
// Value -> JSON String
// ============================================================================

fn valueToJson(allocator: std.mem.Allocator, val: Value, indent: usize) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    try writeValueJson(allocator, &result, val, indent, 0);

    return result.toOwnedSlice(allocator);
}

fn writeValueJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), val: Value, indent: usize, depth: usize) !void {
    switch (val) {
        .string => |s| {
            try out.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try out.appendSlice(allocator, "\\\""),
                    '\\' => try out.appendSlice(allocator, "\\\\"),
                    '\n' => try out.appendSlice(allocator, "\\n"),
                    '\r' => try out.appendSlice(allocator, "\\r"),
                    '\t' => try out.appendSlice(allocator, "\\t"),
                    else => {
                        if (c < 0x20) {
                            var buf: [6]u8 = undefined;
                            const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                            try out.appendSlice(allocator, hex);
                        } else {
                            try out.append(allocator, c);
                        }
                    },
                }
            }
            try out.append(allocator, '"');
        },
        .array => |arr| {
            if (arr.len == 0) {
                try out.appendSlice(allocator, "[]");
            } else {
                try out.appendSlice(allocator, "[\n");
                for (arr, 0..) |item, i| {
                    try writeIndent(allocator, out, indent, depth + 1);
                    try writeValueJson(allocator, out, item, indent, depth + 1);
                    if (i < arr.len - 1) {
                        try out.append(allocator, ',');
                    }
                    try out.append(allocator, '\n');
                }
                try writeIndent(allocator, out, indent, depth);
                try out.append(allocator, ']');
            }
        },
        .object => |obj| {
            if (obj.len == 0) {
                try out.appendSlice(allocator, "{}");
            } else {
                try out.appendSlice(allocator, "{\n");
                for (obj, 0..) |entry, i| {
                    try writeIndent(allocator, out, indent, depth + 1);
                    try out.append(allocator, '"');
                    try out.appendSlice(allocator, entry.key);
                    try out.appendSlice(allocator, "\": ");
                    try writeValueJson(allocator, out, entry.value, indent, depth + 1);
                    if (i < obj.len - 1) {
                        try out.append(allocator, ',');
                    }
                    try out.append(allocator, '\n');
                }
                try writeIndent(allocator, out, indent, depth);
                try out.append(allocator, '}');
            }
        },
    }
}

fn writeIndent(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), indent: usize, depth: usize) !void {
    for (0..indent * depth) |_| {
        try out.append(allocator, ' ');
    }
}

// ============================================================================
// Demo
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Set up stdout writer (Zig 0.15 API)
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    // Deeply nested JSON structure (C0 supports strings, arrays, objects)
    // Note: Some edge cases (arrays of arrays, empty containers) have known decoder bugs
    const json_input =
        \\{
        \\  "project": "c0",
        \\  "version": "0.1.0",
        \\  "description": "Hierarchical binary data stream format",
        \\  "features": ["no escaping", "streaming-safe", "UTF-8 compatible", "deterministic"],
        \\  "architecture": {
        \\    "design": "hexagonal",
        \\    "layers": {
        \\      "core": {
        \\        "language": "Zig",
        \\        "purpose": "pure encode/decode logic",
        \\        "modules": ["value", "encoder", "decoder", "encoding"]
        \\      },
        \\      "ffi": {
        \\        "language": "Zig with C ABI",
        \\        "purpose": "arena-based memory for C consumers"
        \\      },
        \\      "cli": {
        \\        "language": "C",
        \\        "purpose": "exercises FFI layer",
        \\        "commands": ["encode", "decode"]
        \\      }
        \\    }
        \\  },
        \\  "structural_bytes": {
        \\    "FS_0x1C": "begin object",
        \\    "GS_0x1D": "begin array",
        \\    "RS_0x1E": "terminate object entry",
        \\    "US_0x1F": "terminate array element or separate key from value"
        \\  },
        \\  "printable_binary": {
        \\    "purpose": "encodes payloads so structural bytes never appear",
        \\    "example_mappings": {
        \\      "0x1C_FS": "encoded as multi-byte UTF-8",
        \\      "0x1D_GS": "encoded as multi-byte UTF-8",
        \\      "0x1E_RS": "encoded as multi-byte UTF-8",
        \\      "0x1F_US": "encoded as multi-byte UTF-8"
        \\    }
        \\  }
        \\}
    ;

    try stdout.print("=== JSON -> C0 -> JSON Demo ===\n\n", .{});

    // Step 1: Parse JSON
    try stdout.print("1. Input JSON ({d} bytes):\n", .{json_input.len});
    try stdout.print("{s}\n\n", .{json_input});

    const parsed = parseJson(allocator, json_input) catch |err| {
        try stdout.print("JSON parse error: {any}\n", .{err});
        return;
    };
    defer freeValue(allocator, parsed);

    // Step 2: Encode to C0
    const c0_encoded = try core.encode(allocator, parsed);
    defer allocator.free(c0_encoded);

    try stdout.print("2. C0 encoded ({d} bytes):\n", .{c0_encoded.len});

    // Print C0 bytes in a readable format
    for (c0_encoded, 0..) |b, i| {
        if (b < 0x20) {
            const names = [_][]const u8{
                "NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL",
                "BS",  "HT",  "LF",  "VT",  "FF",  "CR",  "SO",  "SI",
                "DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB",
                "CAN", "EM",  "SUB", "ESC", "FS",  "GS",  "RS",  "US",
            };
            try stdout.print("[{s}]", .{names[b]});
        } else if (b < 0x7F) {
            try stdout.print("{c}", .{b});
        } else {
            try stdout.print("\\x{x:0>2}", .{b});
        }

        // Line break every 60 chars for readability
        if ((i + 1) % 60 == 0) {
            try stdout.print("\n", .{});
        }
    }
    try stdout.print("\n\n", .{});

    // Step 3: Decode back from C0
    const decoded = try core.decode(allocator, c0_encoded);
    defer core.deinit(allocator, decoded);

    // Step 4: Convert back to JSON
    const json_output = try valueToJson(allocator, decoded, 2);
    defer allocator.free(json_output);

    try stdout.print("3. Decoded back to JSON ({d} bytes):\n", .{json_output.len});
    try stdout.print("{s}\n\n", .{json_output});

    // Step 5: Verify round-trip
    if (parsed.eql(decoded)) {
        try stdout.print("=== Round-trip successful! Values are equal. ===\n", .{});
    } else {
        try stdout.print("=== WARNING: Round-trip mismatch! ===\n", .{});
    }

    // Show compression ratio
    const ratio = @as(f64, @floatFromInt(c0_encoded.len)) / @as(f64, @floatFromInt(json_input.len)) * 100.0;
    try stdout.print("\nSize comparison: JSON {d} bytes -> C0 {d} bytes ({d:.1}%)\n", .{
        json_input.len,
        c0_encoded.len,
        ratio,
    });
}

// ============================================================================
// Tests
// ============================================================================

test "JSON parse string" {
    const allocator = std.testing.allocator;
    const result = try parseJson(allocator, "\"hello\"");
    defer freeValue(allocator, result);

    try std.testing.expect(result == .string);
    try std.testing.expectEqualStrings("hello", result.string);
}

test "JSON parse array" {
    const allocator = std.testing.allocator;
    const result = try parseJson(allocator, "[\"a\", \"b\"]");
    defer freeValue(allocator, result);

    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 2), result.array.len);
}

test "JSON parse object" {
    const allocator = std.testing.allocator;
    const result = try parseJson(allocator, "{\"key\": \"value\"}");
    defer freeValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 1), result.object.len);
}

test "JSON parse nested" {
    const allocator = std.testing.allocator;
    const result = try parseJson(allocator, "{\"arr\": [\"x\", \"y\"]}");
    defer freeValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expect(result.object[0].value == .array);
}

test "JSON round-trip through C0" {
    const allocator = std.testing.allocator;

    const json = "{\"nested\": {\"deep\": [\"value\"]}}";
    const parsed = try parseJson(allocator, json);
    defer freeValue(allocator, parsed);

    const encoded = try core.encode(allocator, parsed);
    defer allocator.free(encoded);

    const decoded = try core.decode(allocator, encoded);
    defer core.deinit(allocator, decoded);

    try std.testing.expect(parsed.eql(decoded));
}

test "JSON rejects numbers" {
    const allocator = std.testing.allocator;
    const result = parseJson(allocator, "123");
    try std.testing.expectError(JsonError.UnsupportedType, result);
}

test "JSON rejects booleans" {
    const allocator = std.testing.allocator;
    const result = parseJson(allocator, "true");
    try std.testing.expectError(JsonError.UnsupportedType, result);
}

test "JSON rejects null" {
    const allocator = std.testing.allocator;
    const result = parseJson(allocator, "null");
    try std.testing.expectError(JsonError.UnsupportedType, result);
}
