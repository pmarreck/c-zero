//! JSON Content Encoder/Decoder for C0
//!
//! Encodes JSON scalar types into C0 payloads:
//! - strings: '"' + printable_binary(content) - only content is encoded
//! - numbers: decimal/scientific notation as-is (no encoding)
//! - true: literal "true" (no encoding)
//! - false: literal "false" (no encoding)
//! - null: literal "null" (no encoding)
//!
//! The C0 structural delimiters (US, RS) mark value boundaries.
//! Only string content goes through printable_binary encoding.
//! Type markers (", digits, keywords) stay as raw ASCII.

const std = @import("std");
const Value = @import("value.zig").Value;
const Entry = @import("value.zig").Entry;
const enc = @import("encoding.zig");

pub const JsonType = enum {
    string,
    number,
    boolean,
    null,
    array,
    object,
};

pub const JsonScalar = struct {
    type: ScalarType,
    content: []const u8,

    pub const ScalarType = enum {
        string,
        number,
        true,
        false,
        null,
    };
};

/// Encode a string for C0 payload (prepend quote marker)
pub fn encodeString(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, 1 + content.len);
    result[0] = '"';
    if (content.len > 0) {
        @memcpy(result[1..], content);
    }
    return result;
}

/// Encode a number for C0 payload (pass through as-is)
pub fn encodeNumber(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    return try allocator.dupe(u8, content);
}

/// Encode null for C0 payload
pub fn encodeNull(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.dupe(u8, "null");
}

/// Encode boolean for C0 payload
pub fn encodeBoolean(allocator: std.mem.Allocator, value: bool) ![]u8 {
    return try allocator.dupe(u8, if (value) "true" else "false");
}

/// Decode a C0 payload to determine its JSON type and content
pub fn decodeScalar(payload: []const u8) JsonScalar {
    // Empty payload = empty string
    if (payload.len == 0) {
        return .{ .type = .string, .content = "" };
    }

    // Starts with quote = string
    if (payload[0] == '"') {
        return .{ .type = .string, .content = payload[1..] };
    }

    // Exact matches for keywords
    if (std.mem.eql(u8, payload, "null")) {
        return .{ .type = .null, .content = "" };
    }
    if (std.mem.eql(u8, payload, "true")) {
        return .{ .type = .true, .content = "" };
    }
    if (std.mem.eql(u8, payload, "false")) {
        return .{ .type = .false, .content = "" };
    }

    // Looks like a number? (starts with digit or minus)
    if (isNumberStart(payload[0])) {
        return .{ .type = .number, .content = payload };
    }

    // Default: treat as raw string (backwards compat / binary data)
    return .{ .type = .string, .content = payload };
}

fn isNumberStart(c: u8) bool {
    return (c >= '0' and c <= '9') or c == '-';
}

// ============================================================================
// JSON Parsing (input) - Parse JSON string to typed values
// ============================================================================

pub const JsonValue = union(enum) {
    string: []const u8,
    number: []const u8,
    boolean: bool,
    null: void,
    array: []const JsonValue,
    object: []const JsonEntry,
};

pub const JsonEntry = struct {
    key: []const u8,
    value: JsonValue,
};

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEndOfInput,
    InvalidNumber,
    InvalidEscape,
    OutOfMemory,
};

/// Parse a JSON string into a JsonValue tree
pub fn parseJson(allocator: std.mem.Allocator, json: []const u8) ParseError!JsonValue {
    var pos: usize = 0;
    return parseValue(allocator, json, &pos);
}

fn parseValue(allocator: std.mem.Allocator, json: []const u8, pos: *usize) ParseError!JsonValue {
    skipWhitespace(json, pos);

    if (pos.* >= json.len) {
        return ParseError.UnexpectedEndOfInput;
    }

    const c = json[pos.*];

    if (c == '"') {
        const s = try parseString(allocator, json, pos);
        return JsonValue{ .string = s };
    } else if (c == '[') {
        return parseArray(allocator, json, pos);
    } else if (c == '{') {
        return parseObject(allocator, json, pos);
    } else if (c == 't') {
        return parseTrue(json, pos);
    } else if (c == 'f') {
        return parseFalse(json, pos);
    } else if (c == 'n') {
        return parseNull(json, pos);
    } else if (c == '-' or (c >= '0' and c <= '9')) {
        const n = try parseNumber(allocator, json, pos);
        return JsonValue{ .number = n };
    } else {
        return ParseError.UnexpectedToken;
    }
}

fn parseString(allocator: std.mem.Allocator, json: []const u8, pos: *usize) ParseError![]const u8 {
    std.debug.assert(json[pos.*] == '"');
    pos.* += 1; // consume opening quote

    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    while (pos.* < json.len) {
        const c = json[pos.*];
        if (c == '"') {
            pos.* += 1; // consume closing quote
            return result.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
        } else if (c == '\\') {
            pos.* += 1;
            if (pos.* >= json.len) return ParseError.UnexpectedEndOfInput;
            const escaped = json[pos.*];
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
                    // Parse \uXXXX
                    pos.* += 1;
                    if (pos.* + 4 > json.len) return ParseError.UnexpectedEndOfInput;
                    const hex = json[pos.*..][0..4];
                    const codepoint = std.fmt.parseInt(u21, hex, 16) catch return ParseError.InvalidEscape;
                    pos.* += 4;
                    // Encode as UTF-8
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &buf) catch return ParseError.InvalidEscape;
                    result.appendSlice(allocator, buf[0..len]) catch return ParseError.OutOfMemory;
                    continue;
                },
                else => return ParseError.InvalidEscape,
            };
            result.append(allocator, replacement) catch return ParseError.OutOfMemory;
            pos.* += 1;
        } else {
            result.append(allocator, c) catch return ParseError.OutOfMemory;
            pos.* += 1;
        }
    }

    return ParseError.UnexpectedEndOfInput;
}

fn parseNumber(allocator: std.mem.Allocator, json: []const u8, pos: *usize) ParseError![]const u8 {
    const start = pos.*;

    // Optional minus
    if (pos.* < json.len and json[pos.*] == '-') {
        pos.* += 1;
    }

    // Integer part
    if (pos.* >= json.len) return ParseError.InvalidNumber;
    if (json[pos.*] == '0') {
        pos.* += 1;
    } else if (json[pos.*] >= '1' and json[pos.*] <= '9') {
        while (pos.* < json.len and json[pos.*] >= '0' and json[pos.*] <= '9') {
            pos.* += 1;
        }
    } else {
        return ParseError.InvalidNumber;
    }

    // Fractional part
    if (pos.* < json.len and json[pos.*] == '.') {
        pos.* += 1;
        if (pos.* >= json.len or json[pos.*] < '0' or json[pos.*] > '9') {
            return ParseError.InvalidNumber;
        }
        while (pos.* < json.len and json[pos.*] >= '0' and json[pos.*] <= '9') {
            pos.* += 1;
        }
    }

    // Exponent part
    if (pos.* < json.len and (json[pos.*] == 'e' or json[pos.*] == 'E')) {
        pos.* += 1;
        if (pos.* < json.len and (json[pos.*] == '+' or json[pos.*] == '-')) {
            pos.* += 1;
        }
        if (pos.* >= json.len or json[pos.*] < '0' or json[pos.*] > '9') {
            return ParseError.InvalidNumber;
        }
        while (pos.* < json.len and json[pos.*] >= '0' and json[pos.*] <= '9') {
            pos.* += 1;
        }
    }

    return allocator.dupe(u8, json[start..pos.*]) catch return ParseError.OutOfMemory;
}

fn parseTrue(json: []const u8, pos: *usize) ParseError!JsonValue {
    if (pos.* + 4 > json.len) return ParseError.UnexpectedEndOfInput;
    if (!std.mem.eql(u8, json[pos.*..][0..4], "true")) return ParseError.UnexpectedToken;
    pos.* += 4;
    return JsonValue{ .boolean = true };
}

fn parseFalse(json: []const u8, pos: *usize) ParseError!JsonValue {
    if (pos.* + 5 > json.len) return ParseError.UnexpectedEndOfInput;
    if (!std.mem.eql(u8, json[pos.*..][0..5], "false")) return ParseError.UnexpectedToken;
    pos.* += 5;
    return JsonValue{ .boolean = false };
}

fn parseNull(json: []const u8, pos: *usize) ParseError!JsonValue {
    if (pos.* + 4 > json.len) return ParseError.UnexpectedEndOfInput;
    if (!std.mem.eql(u8, json[pos.*..][0..4], "null")) return ParseError.UnexpectedToken;
    pos.* += 4;
    return JsonValue{ .null = {} };
}

fn parseArray(allocator: std.mem.Allocator, json: []const u8, pos: *usize) ParseError!JsonValue {
    std.debug.assert(json[pos.*] == '[');
    pos.* += 1; // consume '['

    var items: std.ArrayListUnmanaged(JsonValue) = .{};
    errdefer {
        for (items.items) |item| {
            freeJsonValue(allocator, item);
        }
        items.deinit(allocator);
    }

    skipWhitespace(json, pos);

    // Empty array
    if (pos.* < json.len and json[pos.*] == ']') {
        pos.* += 1;
        return JsonValue{ .array = items.toOwnedSlice(allocator) catch return ParseError.OutOfMemory };
    }

    while (true) {
        const item = try parseValue(allocator, json, pos);
        items.append(allocator, item) catch return ParseError.OutOfMemory;

        skipWhitespace(json, pos);
        if (pos.* >= json.len) return ParseError.UnexpectedEndOfInput;

        if (json[pos.*] == ']') {
            pos.* += 1;
            break;
        } else if (json[pos.*] == ',') {
            pos.* += 1;
            skipWhitespace(json, pos);
        } else {
            return ParseError.UnexpectedToken;
        }
    }

    return JsonValue{ .array = items.toOwnedSlice(allocator) catch return ParseError.OutOfMemory };
}

fn parseObject(allocator: std.mem.Allocator, json: []const u8, pos: *usize) ParseError!JsonValue {
    std.debug.assert(json[pos.*] == '{');
    pos.* += 1; // consume '{'

    var entries: std.ArrayListUnmanaged(JsonEntry) = .{};
    errdefer {
        for (entries.items) |entry| {
            if (entry.key.len > 0) allocator.free(entry.key);
            freeJsonValue(allocator, entry.value);
        }
        entries.deinit(allocator);
    }

    skipWhitespace(json, pos);

    // Empty object
    if (pos.* < json.len and json[pos.*] == '}') {
        pos.* += 1;
        return JsonValue{ .object = entries.toOwnedSlice(allocator) catch return ParseError.OutOfMemory };
    }

    while (true) {
        skipWhitespace(json, pos);
        if (pos.* >= json.len or json[pos.*] != '"') return ParseError.UnexpectedToken;

        const key = try parseString(allocator, json, pos);
        errdefer if (key.len > 0) allocator.free(key);

        skipWhitespace(json, pos);
        if (pos.* >= json.len or json[pos.*] != ':') return ParseError.UnexpectedToken;
        pos.* += 1; // consume ':'

        const value = try parseValue(allocator, json, pos);

        entries.append(allocator, .{ .key = key, .value = value }) catch return ParseError.OutOfMemory;

        skipWhitespace(json, pos);
        if (pos.* >= json.len) return ParseError.UnexpectedEndOfInput;

        if (json[pos.*] == '}') {
            pos.* += 1;
            break;
        } else if (json[pos.*] == ',') {
            pos.* += 1;
        } else {
            return ParseError.UnexpectedToken;
        }
    }

    return JsonValue{ .object = entries.toOwnedSlice(allocator) catch return ParseError.OutOfMemory };
}

fn skipWhitespace(json: []const u8, pos: *usize) void {
    while (pos.* < json.len) {
        const c = json[pos.*];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            pos.* += 1;
        } else {
            break;
        }
    }
}

pub fn freeJsonValue(allocator: std.mem.Allocator, val: JsonValue) void {
    switch (val) {
        .string => |s| if (s.len > 0) allocator.free(s),
        .number => |n| if (n.len > 0) allocator.free(n),
        .boolean, .null => {},
        .array => |arr| {
            for (arr) |item| {
                freeJsonValue(allocator, item);
            }
            allocator.free(arr);
        },
        .object => |obj| {
            for (obj) |entry| {
                if (entry.key.len > 0) allocator.free(entry.key);
                freeJsonValue(allocator, entry.value);
            }
            allocator.free(obj);
        },
    }
}

// ============================================================================
// JSON Stringify (output) - Convert typed values to JSON string
// ============================================================================

pub fn stringify(allocator: std.mem.Allocator, val: JsonValue) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    try stringifyValue(allocator, &result, val, 0);

    return result.toOwnedSlice(allocator);
}

fn stringifyValue(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), val: JsonValue, depth: usize) !void {
    switch (val) {
        .null => try out.appendSlice(allocator, "null"),
        .boolean => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .number => |n| try out.appendSlice(allocator, n),
        .string => |s| {
            try out.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try out.appendSlice(allocator, "\\\""),
                    '\\' => try out.appendSlice(allocator, "\\\\"),
                    '\n' => try out.appendSlice(allocator, "\\n"),
                    '\r' => try out.appendSlice(allocator, "\\r"),
                    '\t' => try out.appendSlice(allocator, "\\t"),
                    0x08 => try out.appendSlice(allocator, "\\b"),
                    0x0C => try out.appendSlice(allocator, "\\f"),
                    0x00...0x07, 0x0B, 0x0E...0x1F => {
                        // Other control characters: \uXXXX
                        var buf: [6]u8 = undefined;
                        _ = std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{c}) catch unreachable;
                        try out.appendSlice(allocator, &buf);
                    },
                    else => try out.append(allocator, c),
                }
            }
            try out.append(allocator, '"');
        },
        .array => |arr| {
            try out.append(allocator, '[');
            for (arr, 0..) |item, i| {
                if (i > 0) try out.appendSlice(allocator, ", ");
                try stringifyValue(allocator, out, item, depth + 1);
            }
            try out.append(allocator, ']');
        },
        .object => |obj| {
            try out.append(allocator, '{');
            for (obj, 0..) |entry, i| {
                if (i > 0) try out.appendSlice(allocator, ", ");
                // Key
                try out.append(allocator, '"');
                try out.appendSlice(allocator, entry.key);
                try out.append(allocator, '"');
                try out.appendSlice(allocator, ": ");
                // Value
                try stringifyValue(allocator, out, entry.value, depth + 1);
            }
            try out.append(allocator, '}');
        },
    }
}

// ============================================================================
// C0 Conversion - Convert between JsonValue and C0 Value
// ============================================================================

/// Convert JsonValue to C0 Value (for encoding with encodeRaw)
/// - Strings: '"' marker (raw) + printable_binary encoded content
/// - Numbers/booleans/null: raw literals (no encoding)
/// - Keys: printable_binary encoded (keys are always strings)
/// Use encoder.encodeRaw() to write the result (not encode())
pub fn toC0Value(allocator: std.mem.Allocator, json: JsonValue) !Value {
    switch (json) {
        .null => {
            return Value{ .string = try allocator.dupe(u8, "null") };
        },
        .boolean => |b| {
            return Value{ .string = try allocator.dupe(u8, if (b) "true" else "false") };
        },
        .number => |n| {
            return Value{ .string = try allocator.dupe(u8, n) };
        },
        .string => |s| {
            // Encode string content with printable_binary, prepend raw quote marker
            const encoded_content = try enc.encodePayload(allocator, s);
            defer allocator.free(encoded_content);

            const result = try allocator.alloc(u8, 1 + encoded_content.len);
            result[0] = '"';
            if (encoded_content.len > 0) {
                @memcpy(result[1..], encoded_content);
            }
            return Value{ .string = result };
        },
        .array => |arr| {
            const items = try allocator.alloc(Value, arr.len);
            errdefer allocator.free(items);
            for (arr, 0..) |item, i| {
                items[i] = try toC0Value(allocator, item);
            }
            return Value{ .array = items };
        },
        .object => |obj| {
            const entries = try allocator.alloc(Entry, obj.len);
            errdefer allocator.free(entries);
            for (obj, 0..) |entry, i| {
                // Keys are strings, so encode them with printable_binary
                const encoded_key = try enc.encodePayload(allocator, entry.key);
                entries[i] = .{
                    .key = encoded_key,
                    .value = try toC0Value(allocator, entry.value),
                };
            }
            return Value{ .object = entries };
        },
    }
}

/// Convert C0 Value to JsonValue (for decoding)
/// - Strings: strip '"' marker, decode content with printable_binary
/// - Numbers/booleans/null: parse as-is
/// - Keys: decode with printable_binary
pub fn fromC0Value(allocator: std.mem.Allocator, val: Value) !JsonValue {
    switch (val) {
        .string => |payload| {
            const scalar = decodeScalar(payload);
            return switch (scalar.type) {
                .null => JsonValue{ .null = {} },
                .true => JsonValue{ .boolean = true },
                .false => JsonValue{ .boolean = false },
                .number => JsonValue{ .number = try allocator.dupe(u8, scalar.content) },
                .string => {
                    // Decode string content with printable_binary
                    const decoded = try enc.decodePayload(allocator, scalar.content);
                    return JsonValue{ .string = decoded };
                },
            };
        },
        .array => |arr| {
            const items = try allocator.alloc(JsonValue, arr.len);
            errdefer allocator.free(items);
            for (arr, 0..) |item, i| {
                items[i] = try fromC0Value(allocator, item);
            }
            return JsonValue{ .array = items };
        },
        .object => |obj| {
            const entries = try allocator.alloc(JsonEntry, obj.len);
            errdefer allocator.free(entries);
            for (obj, 0..) |entry, i| {
                // Decode key with printable_binary
                const decoded_key = try enc.decodePayload(allocator, entry.key);
                entries[i] = .{
                    .key = decoded_key,
                    .value = try fromC0Value(allocator, entry.value),
                };
            }
            return JsonValue{ .object = entries };
        },
    }
}

/// Free a C0 Value that was created by toC0Value
pub fn freeC0Value(allocator: std.mem.Allocator, val: Value) void {
    switch (val) {
        .string => |s| if (s.len > 0) allocator.free(s),
        .array => |arr| {
            for (arr) |item| {
                freeC0Value(allocator, item);
            }
            allocator.free(arr);
        },
        .object => |obj| {
            for (obj) |entry| {
                if (entry.key.len > 0) allocator.free(entry.key);
                freeC0Value(allocator, entry.value);
            }
            allocator.free(obj);
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "scalar encoding - string" {
    const allocator = std.testing.allocator;

    const encoded = try encodeString(allocator, "hello");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("\"hello", encoded);
}

test "scalar encoding - empty string" {
    const allocator = std.testing.allocator;

    const encoded = try encodeString(allocator, "");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("\"", encoded);
}

test "scalar decoding - string" {
    const scalar = decodeScalar("\"hello");
    try std.testing.expectEqual(JsonScalar.ScalarType.string, scalar.type);
    try std.testing.expectEqualStrings("hello", scalar.content);
}

test "scalar decoding - empty string" {
    const scalar = decodeScalar("\"");
    try std.testing.expectEqual(JsonScalar.ScalarType.string, scalar.type);
    try std.testing.expectEqualStrings("", scalar.content);
}

test "scalar decoding - null" {
    const scalar = decodeScalar("null");
    try std.testing.expectEqual(JsonScalar.ScalarType.null, scalar.type);
}

test "scalar decoding - true" {
    const scalar = decodeScalar("true");
    try std.testing.expectEqual(JsonScalar.ScalarType.true, scalar.type);
}

test "scalar decoding - false" {
    const scalar = decodeScalar("false");
    try std.testing.expectEqual(JsonScalar.ScalarType.false, scalar.type);
}

test "scalar decoding - number" {
    const scalar = decodeScalar("123.456");
    try std.testing.expectEqual(JsonScalar.ScalarType.number, scalar.type);
    try std.testing.expectEqualStrings("123.456", scalar.content);
}

test "scalar decoding - negative number" {
    const scalar = decodeScalar("-42");
    try std.testing.expectEqual(JsonScalar.ScalarType.number, scalar.type);
    try std.testing.expectEqualStrings("-42", scalar.content);
}

test "scalar decoding - scientific notation" {
    const scalar = decodeScalar("1.5e-10");
    try std.testing.expectEqual(JsonScalar.ScalarType.number, scalar.type);
    try std.testing.expectEqualStrings("1.5e-10", scalar.content);
}

test "parse and stringify null" {
    const allocator = std.testing.allocator;

    const val = try parseJson(allocator, "null");
    defer freeJsonValue(allocator, val);

    try std.testing.expect(val == .null);

    const json = try stringify(allocator, val);
    defer allocator.free(json);

    try std.testing.expectEqualStrings("null", json);
}

test "parse and stringify boolean" {
    const allocator = std.testing.allocator;

    const val_true = try parseJson(allocator, "true");
    defer freeJsonValue(allocator, val_true);
    try std.testing.expect(val_true == .boolean);
    try std.testing.expect(val_true.boolean == true);

    const val_false = try parseJson(allocator, "false");
    defer freeJsonValue(allocator, val_false);
    try std.testing.expect(val_false == .boolean);
    try std.testing.expect(val_false.boolean == false);
}

test "parse and stringify number" {
    const allocator = std.testing.allocator;

    const val = try parseJson(allocator, "-123.456e+10");
    defer freeJsonValue(allocator, val);

    try std.testing.expect(val == .number);
    try std.testing.expectEqualStrings("-123.456e+10", val.number);

    const json = try stringify(allocator, val);
    defer allocator.free(json);

    try std.testing.expectEqualStrings("-123.456e+10", json);
}

test "parse and stringify string" {
    const allocator = std.testing.allocator;

    const val = try parseJson(allocator, "\"hello world\"");
    defer freeJsonValue(allocator, val);

    try std.testing.expect(val == .string);
    try std.testing.expectEqualStrings("hello world", val.string);

    const json = try stringify(allocator, val);
    defer allocator.free(json);

    try std.testing.expectEqualStrings("\"hello world\"", json);
}

test "parse string with escapes" {
    const allocator = std.testing.allocator;

    const val = try parseJson(allocator, "\"hello\\nworld\\t!\"");
    defer freeJsonValue(allocator, val);

    try std.testing.expect(val == .string);
    try std.testing.expectEqualStrings("hello\nworld\t!", val.string);
}

test "parse and stringify array" {
    const allocator = std.testing.allocator;

    const val = try parseJson(allocator, "[1, \"two\", true, null]");
    defer freeJsonValue(allocator, val);

    try std.testing.expect(val == .array);
    try std.testing.expectEqual(@as(usize, 4), val.array.len);
    try std.testing.expect(val.array[0] == .number);
    try std.testing.expect(val.array[1] == .string);
    try std.testing.expect(val.array[2] == .boolean);
    try std.testing.expect(val.array[3] == .null);
}

test "parse and stringify object" {
    const allocator = std.testing.allocator;

    const val = try parseJson(allocator, "{\"name\": \"test\", \"count\": 42}");
    defer freeJsonValue(allocator, val);

    try std.testing.expect(val == .object);
    try std.testing.expectEqual(@as(usize, 2), val.object.len);
}

test "JSON -> C0 -> JSON round-trip with types" {
    const allocator = std.testing.allocator;
    const encoder = @import("encoder.zig");
    const decoder = @import("decoder.zig");

    const input_json =
        \\{"string": "hello", "number": 42, "float": 3.14, "bool": true, "nil": null, "array": [1, 2, 3]}
    ;

    // Parse JSON
    const json_val = try parseJson(allocator, input_json);
    defer freeJsonValue(allocator, json_val);

    // Convert to C0 Value
    const c0_val = try toC0Value(allocator, json_val);
    defer freeC0Value(allocator, c0_val);

    // Encode to C0 bytes
    const c0_bytes = try encoder.encodeRaw(allocator, c0_val);
    defer allocator.free(c0_bytes);

    // Decode C0 bytes
    const decoded_c0 = try decoder.decode(allocator, c0_bytes);
    defer decoder.deinitValue(allocator, decoded_c0);

    // Convert back to JsonValue
    const decoded_json = try fromC0Value(allocator, decoded_c0);
    defer freeJsonValue(allocator, decoded_json);

    // Stringify
    const output_json = try stringify(allocator, decoded_json);
    defer allocator.free(output_json);

    // Verify types preserved
    try std.testing.expect(decoded_json == .object);
    const obj = decoded_json.object;

    // Find and check each field
    for (obj) |entry| {
        if (std.mem.eql(u8, entry.key, "string")) {
            try std.testing.expect(entry.value == .string);
            try std.testing.expectEqualStrings("hello", entry.value.string);
        } else if (std.mem.eql(u8, entry.key, "number")) {
            try std.testing.expect(entry.value == .number);
            try std.testing.expectEqualStrings("42", entry.value.number);
        } else if (std.mem.eql(u8, entry.key, "float")) {
            try std.testing.expect(entry.value == .number);
            try std.testing.expectEqualStrings("3.14", entry.value.number);
        } else if (std.mem.eql(u8, entry.key, "bool")) {
            try std.testing.expect(entry.value == .boolean);
            try std.testing.expect(entry.value.boolean == true);
        } else if (std.mem.eql(u8, entry.key, "nil")) {
            try std.testing.expect(entry.value == .null);
        } else if (std.mem.eql(u8, entry.key, "array")) {
            try std.testing.expect(entry.value == .array);
            try std.testing.expectEqual(@as(usize, 3), entry.value.array.len);
        }
    }
}

test "empty string round-trip" {
    const allocator = std.testing.allocator;
    const encoder = @import("encoder.zig");
    const decoder = @import("decoder.zig");

    // Parse JSON with empty string
    const json_val = try parseJson(allocator, "[\"\"]");
    defer freeJsonValue(allocator, json_val);

    // Convert to C0
    const c0_val = try toC0Value(allocator, json_val);
    defer freeC0Value(allocator, c0_val);

    // Encode
    const c0_bytes = try encoder.encodeRaw(allocator, c0_val);
    defer allocator.free(c0_bytes);

    // Decode
    const decoded_c0 = try decoder.decode(allocator, c0_bytes);
    defer decoder.deinitValue(allocator, decoded_c0);

    // Convert back
    const decoded_json = try fromC0Value(allocator, decoded_c0);
    defer freeJsonValue(allocator, decoded_json);

    // Verify
    try std.testing.expect(decoded_json == .array);
    try std.testing.expectEqual(@as(usize, 1), decoded_json.array.len);
    try std.testing.expect(decoded_json.array[0] == .string);
    try std.testing.expectEqualStrings("", decoded_json.array[0].string);
}
