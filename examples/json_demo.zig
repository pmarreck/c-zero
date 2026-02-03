//! Full JSON <-> C0 Demo (Type-Preserving)
//!
//! Demonstrates round-trip conversion between JSON and C0 binary format
//! with all JSON types preserved: strings, numbers, booleans, null, arrays, objects.
//!
//! Content encoding scheme:
//!   strings: '"' + content (C0 structure delimits, no closing quote needed)
//!   numbers: bare decimal/scientific notation
//!   true/false/null: literal keywords
//!   empty string: just '"' (solves the [""] ambiguity!)
//!
//! Run with: zig build run-json-demo

const std = @import("std");
const core = @import("c0_core");
const json = core.json_content;

const JsonValue = json.JsonValue;
const Value = core.Value;

// ============================================================================
// Demo
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Set up stdout writer (Zig 0.15 API)
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    // Full JSON with all types
    const json_input =
        \\{
        \\  "project": "c0",
        \\  "version": "0.1.0",
        \\  "stable": false,
        \\  "downloads": 42,
        \\  "rating": 4.5,
        \\  "deprecated": null,
        \\  "keywords": ["binary", "format", "streaming"],
        \\  "empty_string_test": "",
        \\  "empty_array_test": [],
        \\  "config": {
        \\    "debug": true,
        \\    "timeout_ms": 30000,
        \\    "ratio": 1.5e-3,
        \\    "features": {
        \\      "escaping": false,
        \\      "utf8": true,
        \\      "nested_arrays": [[1, 2], [3, 4]],
        \\      "mixed": [null, true, "text", -42]
        \\    }
        \\  }
        \\}
    ;

    try stdout.print("=== Full JSON <-> C0 Demo (Type-Preserving) ===\n\n", .{});

    // Step 1: Parse JSON
    try stdout.print("1. Input JSON ({d} bytes):\n", .{json_input.len});
    try stdout.print("{s}\n\n", .{json_input});

    const parsed = json.parseJson(allocator, json_input) catch |err| {
        try stdout.print("JSON parse error: {any}\n", .{err});
        return;
    };
    defer json.freeJsonValue(allocator, parsed);

    // Step 2: Convert to C0 Value (applies content encoding)
    const c0_value = try json.toC0Value(allocator, parsed);
    defer json.freeC0Value(allocator, c0_value);

    // Step 3: Encode to C0 bytes
    const c0_encoded = try core.encode(allocator, c0_value);
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

        // Line break every 70 chars for readability
        if ((i + 1) % 70 == 0) {
            try stdout.print("\n", .{});
        }
    }
    try stdout.print("\n\n", .{});

    // Step 4: Decode C0 bytes back
    const decoded_c0 = try core.decode(allocator, c0_encoded);
    defer core.deinit(allocator, decoded_c0);

    // Step 5: Convert from C0 Value to JsonValue (applies content decoding)
    const decoded_json = try json.fromC0Value(allocator, decoded_c0);
    defer json.freeJsonValue(allocator, decoded_json);

    // Step 6: Stringify back to JSON
    const json_output = try json.stringify(allocator, decoded_json);
    defer allocator.free(json_output);

    try stdout.print("3. Decoded back to JSON ({d} bytes):\n", .{json_output.len});
    try stdout.print("{s}\n\n", .{json_output});

    // Step 7: Verify types are preserved
    try stdout.print("4. Type verification:\n", .{});
    try verifyTypes(stdout, decoded_json, 0);
    try stdout.print("\n", .{});

    // Show compression ratio
    const ratio = @as(f64, @floatFromInt(c0_encoded.len)) / @as(f64, @floatFromInt(json_input.len)) * 100.0;
    try stdout.print("=== Size: JSON {d} bytes -> C0 {d} bytes ({d:.1}%) ===\n", .{
        json_input.len,
        c0_encoded.len,
        ratio,
    });
}

fn verifyTypes(stdout: anytype, val: JsonValue, depth: usize) !void {
    const indent = "  " ** 8;
    const prefix = indent[0 .. depth * 2];

    switch (val) {
        .null => try stdout.print("{s}null: null\n", .{prefix}),
        .boolean => |b| try stdout.print("{s}boolean: {}\n", .{ prefix, b }),
        .number => |n| try stdout.print("{s}number: {s}\n", .{ prefix, n }),
        .string => |s| {
            if (s.len == 0) {
                try stdout.print("{s}string: \"\" (empty)\n", .{prefix});
            } else if (s.len > 20) {
                try stdout.print("{s}string: \"{s}...\" ({d} chars)\n", .{ prefix, s[0..20], s.len });
            } else {
                try stdout.print("{s}string: \"{s}\"\n", .{ prefix, s });
            }
        },
        .array => |arr| {
            try stdout.print("{s}array[{d}]:\n", .{ prefix, arr.len });
            for (arr[0..@min(arr.len, 3)]) |item| {
                try verifyTypes(stdout, item, depth + 1);
            }
            if (arr.len > 3) {
                try stdout.print("{s}  ... and {d} more\n", .{ prefix, arr.len - 3 });
            }
        },
        .object => |obj| {
            try stdout.print("{s}object{{{d} keys}}:\n", .{ prefix, obj.len });
            for (obj[0..@min(obj.len, 5)]) |entry| {
                try stdout.print("{s}  \"{s}\": ", .{ prefix, entry.key });
                switch (entry.value) {
                    .null => try stdout.print("null\n", .{}),
                    .boolean => |b| try stdout.print("{}\n", .{b}),
                    .number => |n| try stdout.print("{s}\n", .{n}),
                    .string => |s| {
                        if (s.len == 0) {
                            try stdout.print("\"\" (empty string)\n", .{});
                        } else {
                            try stdout.print("\"{s}\"\n", .{s[0..@min(s.len, 15)]});
                        }
                    },
                    .array => |a| try stdout.print("[{d} items]\n", .{a.len}),
                    .object => |o| try stdout.print("{{{d} keys}}\n", .{o.len}),
                }
            }
            if (obj.len > 5) {
                try stdout.print("{s}  ... and {d} more keys\n", .{ prefix, obj.len - 5 });
            }
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "JSON parse and stringify string" {
    const allocator = std.testing.allocator;
    const result = try json.parseJson(allocator, "\"hello\"");
    defer json.freeJsonValue(allocator, result);

    try std.testing.expect(result == .string);
    try std.testing.expectEqualStrings("hello", result.string);
}

test "JSON parse and stringify number" {
    const allocator = std.testing.allocator;
    const result = try json.parseJson(allocator, "42.5");
    defer json.freeJsonValue(allocator, result);

    try std.testing.expect(result == .number);
    try std.testing.expectEqualStrings("42.5", result.number);
}

test "JSON parse and stringify boolean" {
    const allocator = std.testing.allocator;

    const t = try json.parseJson(allocator, "true");
    defer json.freeJsonValue(allocator, t);
    try std.testing.expect(t == .boolean);
    try std.testing.expect(t.boolean == true);

    const f = try json.parseJson(allocator, "false");
    defer json.freeJsonValue(allocator, f);
    try std.testing.expect(f == .boolean);
    try std.testing.expect(f.boolean == false);
}

test "JSON parse and stringify null" {
    const allocator = std.testing.allocator;
    const result = try json.parseJson(allocator, "null");
    defer json.freeJsonValue(allocator, result);

    try std.testing.expect(result == .null);
}

test "JSON parse array with mixed types" {
    const allocator = std.testing.allocator;
    const result = try json.parseJson(allocator, "[1, \"two\", true, null]");
    defer json.freeJsonValue(allocator, result);

    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 4), result.array.len);
    try std.testing.expect(result.array[0] == .number);
    try std.testing.expect(result.array[1] == .string);
    try std.testing.expect(result.array[2] == .boolean);
    try std.testing.expect(result.array[3] == .null);
}

test "JSON parse object" {
    const allocator = std.testing.allocator;
    const result = try json.parseJson(allocator, "{\"key\": \"value\", \"num\": 42}");
    defer json.freeJsonValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 2), result.object.len);
}

test "JSON -> C0 -> JSON round-trip preserves types" {
    const allocator = std.testing.allocator;

    const input = "{\"s\": \"text\", \"n\": 42, \"b\": true, \"nil\": null}";

    // Parse
    const parsed = try json.parseJson(allocator, input);
    defer json.freeJsonValue(allocator, parsed);

    // To C0 Value
    const c0_val = try json.toC0Value(allocator, parsed);
    defer json.freeC0Value(allocator, c0_val);

    // Encode
    const encoded = try core.encode(allocator, c0_val);
    defer allocator.free(encoded);

    // Decode
    const decoded_c0 = try core.decode(allocator, encoded);
    defer core.deinit(allocator, decoded_c0);

    // From C0 Value
    const decoded = try json.fromC0Value(allocator, decoded_c0);
    defer json.freeJsonValue(allocator, decoded);

    // Verify types
    try std.testing.expect(decoded == .object);
    for (decoded.object) |entry| {
        if (std.mem.eql(u8, entry.key, "s")) {
            try std.testing.expect(entry.value == .string);
        } else if (std.mem.eql(u8, entry.key, "n")) {
            try std.testing.expect(entry.value == .number);
        } else if (std.mem.eql(u8, entry.key, "b")) {
            try std.testing.expect(entry.value == .boolean);
        } else if (std.mem.eql(u8, entry.key, "nil")) {
            try std.testing.expect(entry.value == .null);
        }
    }
}

test "empty string round-trip" {
    const allocator = std.testing.allocator;

    // This was the problematic case: [""] vs []
    const input = "[\"\"]";

    const parsed = try json.parseJson(allocator, input);
    defer json.freeJsonValue(allocator, parsed);

    const c0_val = try json.toC0Value(allocator, parsed);
    defer json.freeC0Value(allocator, c0_val);

    const encoded = try core.encode(allocator, c0_val);
    defer allocator.free(encoded);

    const decoded_c0 = try core.decode(allocator, encoded);
    defer core.deinit(allocator, decoded_c0);

    const decoded = try json.fromC0Value(allocator, decoded_c0);
    defer json.freeJsonValue(allocator, decoded);

    // Verify: array with one empty string
    try std.testing.expect(decoded == .array);
    try std.testing.expectEqual(@as(usize, 1), decoded.array.len);
    try std.testing.expect(decoded.array[0] == .string);
    try std.testing.expectEqualStrings("", decoded.array[0].string);
}

test "nested arrays round-trip" {
    const allocator = std.testing.allocator;

    const input = "[[1, 2], [3, 4]]";

    const parsed = try json.parseJson(allocator, input);
    defer json.freeJsonValue(allocator, parsed);

    const c0_val = try json.toC0Value(allocator, parsed);
    defer json.freeC0Value(allocator, c0_val);

    const encoded = try core.encode(allocator, c0_val);
    defer allocator.free(encoded);

    const decoded_c0 = try core.decode(allocator, encoded);
    defer core.deinit(allocator, decoded_c0);

    const decoded = try json.fromC0Value(allocator, decoded_c0);
    defer json.freeJsonValue(allocator, decoded);

    // Verify structure
    try std.testing.expect(decoded == .array);
    try std.testing.expectEqual(@as(usize, 2), decoded.array.len);
    try std.testing.expect(decoded.array[0] == .array);
    try std.testing.expect(decoded.array[1] == .array);
    try std.testing.expectEqual(@as(usize, 2), decoded.array[0].array.len);
    try std.testing.expectEqual(@as(usize, 2), decoded.array[1].array.len);
}
