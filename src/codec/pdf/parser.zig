//! PDF value and object parser.
//!
//! Parses PDF syntax (dictionaries, arrays, strings, names, numbers, refs)
//! into C0 Value types. Operates on raw byte buffers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("c0_core");
const Value = core.Value;
const Entry = core.Entry;
const util = @import("util.zig");

pub const ParseError = error{
    InvalidSyntax,
    UnexpectedEof,
    OutOfMemory,
    NestingTooDeep,
};

const max_nesting: usize = 64;

/// Result of parsing a value
pub const ParseResult = struct {
    value: Value,
    end: usize,
};

/// Result of parsing an indirect object
pub const ObjectResult = struct {
    num: u32,
    gen: u16,
    dict: Value,
    stream_start: ?usize, // byte offset of stream data (after "stream\n")
    stream_end: ?usize, // byte offset of end of stream data (before "endstream")
    end: usize, // position after endobj
};

/// Skip PDF whitespace characters and comments.
pub fn skipWhitespace(data: []const u8, start: usize) usize {
    var i = start;
    while (i < data.len) {
        switch (data[i]) {
            ' ', '\t', '\n', '\r', '\x0c', '\x00' => i += 1,
            '%' => {
                // Skip comment to end of line
                while (i < data.len and data[i] != '\n' and data[i] != '\r') : (i += 1) {}
            },
            else => break,
        }
    }
    return i;
}

/// Parse any PDF value, producing a C0 Value.
pub fn parseValue(allocator: Allocator, data: []const u8, pos: usize) ParseError!ParseResult {
    return parseValueWithDepth(allocator, data, pos, 0);
}

fn parseValueWithDepth(allocator: Allocator, data: []const u8, start: usize, depth: usize) ParseError!ParseResult {
    if (depth > max_nesting) return ParseError.NestingTooDeep;

    const pos = skipWhitespace(data, start);
    if (pos >= data.len) return ParseError.UnexpectedEof;

    const ch = data[pos];

    // Dictionary << ... >>
    if (ch == '<' and pos + 1 < data.len and data[pos + 1] == '<') {
        return parseDictWithDepth(allocator, data, pos, depth);
    }

    // Hex string < ... >
    if (ch == '<') {
        return parseHexString(allocator, data, pos);
    }

    // Literal string ( ... )
    if (ch == '(') {
        return parseLiteralString(allocator, data, pos);
    }

    // Array [ ... ]
    if (ch == '[') {
        return parseArrayWithDepth(allocator, data, pos, depth);
    }

    // Name /...
    if (ch == '/') {
        return parseName(data, pos);
    }

    // Number, boolean, null, or indirect reference
    if (ch == '-' or ch == '+' or ch == '.' or (ch >= '0' and ch <= '9')) {
        return parseNumberOrRef(allocator, data, pos);
    }

    // Boolean true/false
    if (pos + 4 <= data.len and std.mem.eql(u8, data[pos .. pos + 4], "true")) {
        if (pos + 4 >= data.len or isDelimiter(data[pos + 4])) {
            return .{ .value = .{ .string = "true" }, .end = pos + 4 };
        }
    }
    if (pos + 5 <= data.len and std.mem.eql(u8, data[pos .. pos + 5], "false")) {
        if (pos + 5 >= data.len or isDelimiter(data[pos + 5])) {
            return .{ .value = .{ .string = "false" }, .end = pos + 5 };
        }
    }

    // null
    if (pos + 4 <= data.len and std.mem.eql(u8, data[pos .. pos + 4], "null")) {
        if (pos + 4 >= data.len or isDelimiter(data[pos + 4])) {
            return .{ .value = .{ .string = "null" }, .end = pos + 4 };
        }
    }

    return ParseError.InvalidSyntax;
}

/// Parse a PDF name: /SomeName
fn parseName(data: []const u8, start: usize) ParseError!ParseResult {
    if (start >= data.len or data[start] != '/') return ParseError.InvalidSyntax;
    var i = start + 1;
    while (i < data.len) {
        if (isWhitespaceChar(data[i]) or isDelimiterChar(data[i])) break;
        i += 1;
    }
    // The name value strips the leading /
    return .{ .value = .{ .string = data[start + 1 .. i] }, .end = i };
}

/// Parse a literal string: (text with \escapes and (nested parens))
fn parseLiteralString(allocator: Allocator, data: []const u8, start: usize) ParseError!ParseResult {
    if (start >= data.len or data[start] != '(') return ParseError.InvalidSyntax;

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i = start + 1;
    var paren_depth: usize = 1;

    while (i < data.len and paren_depth > 0) {
        const ch = data[i];

        if (ch == '\\' and i + 1 < data.len) {
            // Escape sequence
            i += 1;
            switch (data[i]) {
                'n' => result.append(allocator, '\n') catch return ParseError.OutOfMemory,
                'r' => result.append(allocator, '\r') catch return ParseError.OutOfMemory,
                't' => result.append(allocator, '\t') catch return ParseError.OutOfMemory,
                'b' => result.append(allocator, 0x08) catch return ParseError.OutOfMemory,
                'f' => result.append(allocator, 0x0C) catch return ParseError.OutOfMemory,
                '(' => result.append(allocator, '(') catch return ParseError.OutOfMemory,
                ')' => result.append(allocator, ')') catch return ParseError.OutOfMemory,
                '\\' => result.append(allocator, '\\') catch return ParseError.OutOfMemory,
                '\r' => {
                    // Backslash + CR (or CR+LF) = line continuation, skip
                    if (i + 1 < data.len and data[i + 1] == '\n') i += 1;
                },
                '\n' => {}, // Backslash + LF = line continuation, skip
                '0'...'7' => {
                    // Octal escape: 1-3 digits
                    var octal: u8 = data[i] - '0';
                    if (i + 1 < data.len and data[i + 1] >= '0' and data[i + 1] <= '7') {
                        i += 1;
                        octal = octal * 8 + (data[i] - '0');
                        if (i + 1 < data.len and data[i + 1] >= '0' and data[i + 1] <= '7') {
                            i += 1;
                            octal = octal * 8 + (data[i] - '0');
                        }
                    }
                    result.append(allocator, octal) catch return ParseError.OutOfMemory;
                },
                else => {
                    // Unknown escape: just output the character after backslash
                    result.append(allocator, data[i]) catch return ParseError.OutOfMemory;
                },
            }
        } else if (ch == '(') {
            paren_depth += 1;
            result.append(allocator, ch) catch return ParseError.OutOfMemory;
        } else if (ch == ')') {
            paren_depth -= 1;
            if (paren_depth > 0) {
                result.append(allocator, ch) catch return ParseError.OutOfMemory;
            }
        } else {
            result.append(allocator, ch) catch return ParseError.OutOfMemory;
        }

        i += 1;
    }

    const str = result.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
    return .{ .value = .{ .string = str }, .end = i };
}

/// Parse a hex string: <48656C6C6F>
fn parseHexString(allocator: Allocator, data: []const u8, start: usize) ParseError!ParseResult {
    if (start >= data.len or data[start] != '<') return ParseError.InvalidSyntax;

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var high_nibble: ?u4 = null;
    var i = start + 1;

    while (i < data.len) {
        const ch = data[i];
        if (ch == '>') {
            i += 1;
            break;
        }
        if (isWhitespaceChar(ch)) {
            i += 1;
            continue;
        }

        const nibble = hexToNibble(ch) orelse return ParseError.InvalidSyntax;
        if (high_nibble) |high| {
            result.append(allocator, @as(u8, high) << 4 | nibble) catch return ParseError.OutOfMemory;
            high_nibble = null;
        } else {
            high_nibble = nibble;
        }
        i += 1;
    }

    // Odd number of hex digits: pad with 0
    if (high_nibble) |high| {
        result.append(allocator, @as(u8, high) << 4) catch return ParseError.OutOfMemory;
    }

    const str = result.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
    return .{ .value = .{ .string = str }, .end = i };
}

/// Parse a number (integer or real). May also detect indirect references (N G R).
fn parseNumberOrRef(allocator: Allocator, data: []const u8, start: usize) ParseError!ParseResult {
    var i = start;
    // Allow leading sign
    if (i < data.len and (data[i] == '+' or data[i] == '-')) i += 1;

    var has_dot = false;
    const num_start = i;
    while (i < data.len) {
        if (data[i] >= '0' and data[i] <= '9') {
            i += 1;
        } else if (data[i] == '.' and !has_dot) {
            has_dot = true;
            i += 1;
        } else {
            break;
        }
    }

    if (i == num_start and start == num_start) return ParseError.InvalidSyntax;

    const num_str = data[start..i];

    // Check for indirect reference: "N G R"
    if (!has_dot) {
        const after_num = skipWhitespace(data, i);
        if (after_num < data.len and data[after_num] >= '0' and data[after_num] <= '9') {
            // Could be generation number
            var j = after_num;
            while (j < data.len and data[j] >= '0' and data[j] <= '9') : (j += 1) {}
            const gen_str = data[after_num..j];
            const after_gen = skipWhitespace(data, j);
            if (after_gen < data.len and data[after_gen] == 'R') {
                // It's an indirect reference: N G R
                const entries = allocator.alloc(Entry, 2) catch return ParseError.OutOfMemory;
                entries[0] = .{ .key = "ref", .value = .{ .string = num_str } };
                entries[1] = .{ .key = "gen", .value = .{ .string = gen_str } };
                return .{ .value = .{ .object = entries }, .end = after_gen + 1 };
            }
        }
    }

    return .{ .value = .{ .string = num_str }, .end = i };
}

/// Parse a PDF dictionary: << /Key value /Key value >>
fn parseDictWithDepth(allocator: Allocator, data: []const u8, start: usize, depth: usize) ParseError!ParseResult {
    if (start + 1 >= data.len or data[start] != '<' or data[start + 1] != '<')
        return ParseError.InvalidSyntax;

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer entries.deinit(allocator);

    var i = start + 2;

    while (true) {
        i = skipWhitespace(data, i);
        if (i >= data.len) return ParseError.UnexpectedEof;

        // End of dictionary
        if (i + 1 < data.len and data[i] == '>' and data[i + 1] == '>') {
            i += 2;
            break;
        }

        // Key must be a name
        if (data[i] != '/') return ParseError.InvalidSyntax;
        const key_result = try parseName(data, i);
        i = key_result.end;

        // Value
        const val_result = try parseValueWithDepth(allocator, data, i, depth + 1);
        i = val_result.end;

        entries.append(allocator, .{
            .key = key_result.value.string,
            .value = val_result.value,
        }) catch return ParseError.OutOfMemory;
    }

    const owned = entries.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
    return .{ .value = .{ .object = owned }, .end = i };
}

/// Parse a PDF array: [ value value value ]
fn parseArrayWithDepth(allocator: Allocator, data: []const u8, start: usize, depth: usize) ParseError!ParseResult {
    if (start >= data.len or data[start] != '[') return ParseError.InvalidSyntax;

    var elements: std.ArrayListUnmanaged(Value) = .empty;
    errdefer elements.deinit(allocator);

    var i = start + 1;

    while (true) {
        i = skipWhitespace(data, i);
        if (i >= data.len) return ParseError.UnexpectedEof;

        if (data[i] == ']') {
            i += 1;
            break;
        }

        const val_result = try parseValueWithDepth(allocator, data, i, depth + 1);
        elements.append(allocator, val_result.value) catch return ParseError.OutOfMemory;
        i = val_result.end;
    }

    const owned = elements.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
    return .{ .value = .{ .array = owned }, .end = i };
}

/// Parse an indirect object definition: N G obj ... endobj
pub fn parseIndirectObject(allocator: Allocator, data: []const u8, start: usize) ParseError!ObjectResult {
    var i = skipWhitespace(data, start);

    // Parse object number
    const num = parseUint(data, i) orelse return ParseError.InvalidSyntax;
    i = skipWhitespace(data, num.end);

    // Parse generation number
    const gen = parseUint(data, i) orelse return ParseError.InvalidSyntax;
    i = skipWhitespace(data, gen.end);

    // Expect "obj"
    if (i + 3 > data.len or !std.mem.eql(u8, data[i .. i + 3], "obj")) return ParseError.InvalidSyntax;
    i += 3;

    // Parse the object's value (usually a dictionary)
    const val_result = try parseValue(allocator, data, i);
    i = val_result.end;

    // Check for stream
    var stream_start: ?usize = null;
    var stream_end: ?usize = null;

    i = skipWhitespace(data, i);
    if (i + 6 <= data.len and std.mem.eql(u8, data[i .. i + 6], "stream")) {
        i += 6;
        // Skip the EOL after "stream" (required: \r\n or \n)
        if (i < data.len and data[i] == '\r') i += 1;
        if (i < data.len and data[i] == '\n') i += 1;

        stream_start = i;

        // Try to use /Length from dictionary to find stream end
        const length_val = getDictInt(val_result.value, "Length");
        if (length_val) |len| {
            const end = i + len;
            if (end <= data.len) {
                stream_end = end;
                i = end;
            }
        }

        // If /Length didn't work or was missing, search for "endstream"
        if (stream_end == null) {
            stream_end = findEndstream(data, i);
            if (stream_end) |end| {
                i = end;
            }
        }

        // Skip to after "endstream"
        if (stream_end != null) {
            // Find "endstream" keyword
            const es = findKeyword(data, i, "endstream");
            if (es) |es_pos| {
                i = es_pos + 9;
            } else {
                // Search from stream_start for endstream
                const es2 = findKeyword(data, stream_start.?, "endstream");
                if (es2) |es_pos| {
                    // Adjust stream_end to match where endstream actually is
                    stream_end = es_pos;
                    // Skip whitespace before endstream
                    var se = es_pos;
                    while (se > stream_start.? and (data[se - 1] == '\n' or data[se - 1] == '\r')) {
                        se -= 1;
                    }
                    stream_end = se;
                    i = es_pos + 9;
                }
            }
        }
    }

    // Find "endobj"
    const eo = findKeyword(data, i, "endobj");
    const end_pos = if (eo) |p| p + 6 else i;

    return .{
        .num = @intCast(num.value),
        .gen = @intCast(gen.value),
        .dict = val_result.value,
        .stream_start = stream_start,
        .stream_end = stream_end,
        .end = end_pos,
    };
}

/// Get an integer value from a dictionary by key name.
pub fn getDictInt(value: Value, key: []const u8) ?usize {
    switch (value) {
        .object => |entries| {
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, key)) {
                    switch (entry.value) {
                        .string => |s| return std.fmt.parseInt(usize, s, 10) catch null,
                        else => return null,
                    }
                }
            }
        },
        else => {},
    }
    return null;
}

/// Get a string value from a dictionary by key name.
pub fn getDictString(value: Value, key: []const u8) ?[]const u8 {
    switch (value) {
        .object => |entries| {
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, key)) {
                    switch (entry.value) {
                        .string => |s| return s,
                        else => return null,
                    }
                }
            }
        },
        else => {},
    }
    return null;
}

/// Get a value from a dictionary by key name.
pub fn getDictValue(value: Value, key: []const u8) ?Value {
    switch (value) {
        .object => |entries| {
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, key)) {
                    return entry.value;
                }
            }
        },
        else => {},
    }
    return null;
}

/// Linear scan for indirect objects in the file (fallback when xref is broken).
pub fn scanForObjects(allocator: Allocator, data: []const u8) ParseError![]ObjectResult {
    var objects: std.ArrayListUnmanaged(ObjectResult) = .empty;
    errdefer objects.deinit(allocator);

    var i: usize = 0;
    while (i + 5 < data.len) {
        // Look for "N G obj" pattern
        if (data[i] >= '0' and data[i] <= '9') {
            const result = parseIndirectObject(allocator, data, i) catch {
                i += 1;
                continue;
            };
            objects.append(allocator, result) catch return ParseError.OutOfMemory;
            i = result.end;
        } else {
            i += 1;
        }
    }

    return objects.toOwnedSlice(allocator) catch return ParseError.OutOfMemory;
}

// ============================================================================
// Internal helpers
// ============================================================================

const UintResult = struct { value: u64, end: usize };

fn parseUint(data: []const u8, start: usize) ?UintResult {
    var i = start;
    if (i >= data.len or data[i] < '0' or data[i] > '9') return null;

    var value: u64 = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') {
        value = value * 10 + (data[i] - '0');
        i += 1;
    }
    return .{ .value = value, .end = i };
}

fn findEndstream(data: []const u8, start: usize) ?usize {
    var i = start;
    while (i + 9 <= data.len) {
        if (std.mem.eql(u8, data[i .. i + 9], "endstream")) {
            // Walk back over whitespace before endstream
            var end = i;
            while (end > start and (data[end - 1] == '\n' or data[end - 1] == '\r')) {
                end -= 1;
            }
            return end;
        }
        i += 1;
    }
    return null;
}

fn findKeyword(data: []const u8, start: usize, keyword: []const u8) ?usize {
    if (data.len < keyword.len) return null;
    var i = start;
    while (i + keyword.len <= data.len) {
        if (std.mem.eql(u8, data[i .. i + keyword.len], keyword)) return i;
        i += 1;
    }
    return null;
}

const hexToNibble = util.hexToNibble;

const isWhitespaceChar = util.isWhitespace;

fn isDelimiterChar(ch: u8) bool {
    return switch (ch) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
        else => false,
    };
}

fn isDelimiter(ch: u8) bool {
    return isWhitespaceChar(ch) or isDelimiterChar(ch);
}

// ============================================================================
// Tests
// ============================================================================

test "parse name" {
    const result = try parseName("/Catalog", 0);
    try std.testing.expectEqualStrings("Catalog", result.value.string);
    try std.testing.expectEqual(@as(usize, 8), result.end);
}

test "parse name with digits" {
    const result = try parseName("/Type1", 0);
    try std.testing.expectEqualStrings("Type1", result.value.string);
}

test "parse literal string" {
    const allocator = std.testing.allocator;
    const result = try parseLiteralString(allocator, "(Hello World)", 0);
    defer allocator.free(result.value.string);
    try std.testing.expectEqualStrings("Hello World", result.value.string);
}

test "parse literal string with escapes" {
    const allocator = std.testing.allocator;
    const result = try parseLiteralString(allocator, "(Hello\\nWorld)", 0);
    defer allocator.free(result.value.string);
    try std.testing.expectEqualStrings("Hello\nWorld", result.value.string);
}

test "parse literal string with nested parens" {
    const allocator = std.testing.allocator;
    const result = try parseLiteralString(allocator, "(a(b)c)", 0);
    defer allocator.free(result.value.string);
    try std.testing.expectEqualStrings("a(b)c", result.value.string);
}

test "parse hex string" {
    const allocator = std.testing.allocator;
    const result = try parseHexString(allocator, "<48656C6C6F>", 0);
    defer allocator.free(result.value.string);
    try std.testing.expectEqualStrings("Hello", result.value.string);
}

test "parse number" {
    const allocator = std.testing.allocator;
    const result = try parseNumberOrRef(allocator, "42 ", 0);
    try std.testing.expectEqualStrings("42", result.value.string);
}

test "parse real number" {
    const allocator = std.testing.allocator;
    const result = try parseNumberOrRef(allocator, "3.14 ", 0);
    try std.testing.expectEqualStrings("3.14", result.value.string);
}

test "parse indirect reference" {
    const allocator = std.testing.allocator;
    const result = try parseNumberOrRef(allocator, "5 0 R ", 0);
    defer allocator.free(result.value.object);

    const entries = result.value.object;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("ref", entries[0].key);
    try std.testing.expectEqualStrings("5", entries[0].value.string);
    try std.testing.expectEqualStrings("gen", entries[1].key);
    try std.testing.expectEqualStrings("0", entries[1].value.string);
}

test "parse dictionary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try parseValue(allocator, "<< /Type /Catalog /Pages 2 0 R >>", 0);

    const entries = result.value.object;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("Type", entries[0].key);
    try std.testing.expectEqualStrings("Catalog", entries[0].value.string);
    try std.testing.expectEqualStrings("Pages", entries[1].key);
    // Pages value should be an indirect ref object
    try std.testing.expectEqual(Value.object, std.meta.activeTag(entries[1].value));
}

test "parse array" {
    const allocator = std.testing.allocator;
    const result = try parseValue(allocator, "[0 0 612 792]", 0);
    defer allocator.free(result.value.array);

    const arr = result.value.array;
    try std.testing.expectEqual(@as(usize, 4), arr.len);
    try std.testing.expectEqualStrings("0", arr[0].string);
    try std.testing.expectEqualStrings("612", arr[2].string);
}

test "parse boolean true" {
    const allocator = std.testing.allocator;
    const result = try parseValue(allocator, "true ", 0);
    try std.testing.expectEqualStrings("true", result.value.string);
}

test "parse boolean false" {
    const allocator = std.testing.allocator;
    const result = try parseValue(allocator, "false ", 0);
    try std.testing.expectEqualStrings("false", result.value.string);
}

test "parse null" {
    const allocator = std.testing.allocator;
    const result = try parseValue(allocator, "null ", 0);
    try std.testing.expectEqualStrings("null", result.value.string);
}

test "skip whitespace with comments" {
    const result = skipWhitespace("  % this is a comment\n  42", 0);
    try std.testing.expectEqual(@as(usize, 24), result);
}

test "parse indirect object" {
    const allocator = std.testing.allocator;
    const pdf = "1 0 obj\n<< /Type /Catalog >>\nendobj\n";
    const result = try parseIndirectObject(allocator, pdf, 0);
    defer allocator.free(result.dict.object);

    try std.testing.expectEqual(@as(u32, 1), result.num);
    try std.testing.expectEqual(@as(u16, 0), result.gen);
    try std.testing.expect(result.stream_start == null);
    try std.testing.expectEqualStrings("Type", result.dict.object[0].key);
    try std.testing.expectEqualStrings("Catalog", result.dict.object[0].value.string);
}

test "getDictInt" {
    const entries = [_]Entry{
        .{ .key = "Length", .value = .{ .string = "42" } },
    };
    const val = Value{ .object = &entries };
    try std.testing.expectEqual(@as(?usize, 42), getDictInt(val, "Length"));
    try std.testing.expectEqual(@as(?usize, null), getDictInt(val, "Width"));
}
