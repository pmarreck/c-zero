//! PDF stream filter decoders and encoders.
//!
//! Supports: FlateDecode, ASCII85Decode, ASCIIHexDecode, LZWDecode, RunLengthDecode.
//! Used to decode/encode PDF content streams during expand/collapse.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlib = @import("zlib.zig");

pub const FilterError = error{
    InvalidData,
    UnsupportedFilter,
    OutOfMemory,
    DecompressionError,
    CompressionError,
};

pub const FilterType = enum {
    flate,
    ascii85,
    ascii_hex,
    lzw,
    run_length,
    unknown,
};

/// Map a PDF filter name to a FilterType.
pub fn detectFilter(name: []const u8) FilterType {
    // Strip leading / if present
    const clean = if (name.len > 0 and name[0] == '/') name[1..] else name;

    if (std.mem.eql(u8, clean, "FlateDecode") or std.mem.eql(u8, clean, "Fl"))
        return .flate;
    if (std.mem.eql(u8, clean, "ASCII85Decode") or std.mem.eql(u8, clean, "A85"))
        return .ascii85;
    if (std.mem.eql(u8, clean, "ASCIIHexDecode") or std.mem.eql(u8, clean, "AHx"))
        return .ascii_hex;
    if (std.mem.eql(u8, clean, "LZWDecode") or std.mem.eql(u8, clean, "LZW"))
        return .lzw;
    if (std.mem.eql(u8, clean, "RunLengthDecode") or std.mem.eql(u8, clean, "RL"))
        return .run_length;

    return .unknown;
}

/// Decode data through a single filter.
pub fn decodeFilter(allocator: Allocator, data: []const u8, filter: FilterType) FilterError![]u8 {
    return switch (filter) {
        .flate => decodeFlate(allocator, data),
        .ascii85 => decodeAscii85(allocator, data),
        .ascii_hex => decodeAsciiHex(allocator, data),
        .lzw => decodeLzw(allocator, data),
        .run_length => decodeRunLength(allocator, data),
        .unknown => FilterError.UnsupportedFilter,
    };
}

/// Encode data through a single filter.
pub fn encodeFilter(allocator: Allocator, data: []const u8, filter: FilterType) FilterError![]u8 {
    return switch (filter) {
        .flate => encodeFlate(allocator, data),
        .ascii85 => encodeAscii85(allocator, data),
        .ascii_hex => encodeAsciiHex(allocator, data),
        .lzw, .run_length => FilterError.UnsupportedFilter, // encode not needed for these
        .unknown => FilterError.UnsupportedFilter,
    };
}

/// Apply a chain of filters for decoding (filters applied in order).
pub fn applyDecodeChain(allocator: Allocator, data: []const u8, filters: []const FilterType) FilterError![]u8 {
    if (filters.len == 0) {
        return allocator.dupe(u8, data) catch return FilterError.OutOfMemory;
    }

    var current = allocator.dupe(u8, data) catch return FilterError.OutOfMemory;

    for (filters) |filter| {
        const decoded = decodeFilter(allocator, current, filter) catch |err| {
            allocator.free(current);
            return err;
        };
        allocator.free(current);
        current = decoded;
    }

    return current;
}

/// Apply a chain of filters for encoding (filters applied in reverse order).
pub fn applyEncodeChain(allocator: Allocator, data: []const u8, filters: []const FilterType) FilterError![]u8 {
    if (filters.len == 0) {
        return allocator.dupe(u8, data) catch return FilterError.OutOfMemory;
    }

    var current = allocator.dupe(u8, data) catch return FilterError.OutOfMemory;

    // Encode in reverse order
    var i: usize = filters.len;
    while (i > 0) {
        i -= 1;
        const encoded = encodeFilter(allocator, current, filters[i]) catch |err| {
            allocator.free(current);
            return err;
        };
        allocator.free(current);
        current = encoded;
    }

    return current;
}

// ============================================================================
// FlateDecode (zlib)
// ============================================================================

fn decodeFlate(allocator: Allocator, data: []const u8) FilterError![]u8 {
    // Try zlib format first (with header), fall back to raw deflate
    return zlib.inflateAlloc(allocator, data, 256 * 1024 * 1024) catch {
        return zlib.inflateRawAlloc(allocator, data, 256 * 1024 * 1024) catch {
            return FilterError.DecompressionError;
        };
    };
}

fn encodeFlate(allocator: Allocator, data: []const u8) FilterError![]u8 {
    return zlib.deflateAlloc(allocator, data) catch {
        return FilterError.CompressionError;
    };
}

// ============================================================================
// ASCII85Decode
// ============================================================================

fn decodeAscii85(allocator: Allocator, input: []const u8) FilterError![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    var group: [5]u8 = undefined;
    var group_len: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        const ch = input[i];

        // End-of-data marker
        if (ch == '~') {
            if (i + 1 < input.len and input[i + 1] == '>') break;
            return FilterError.InvalidData;
        }

        // Skip whitespace
        if (isWhitespace(ch)) {
            i += 1;
            continue;
        }

        // 'z' shorthand for 4 null bytes
        if (ch == 'z') {
            if (group_len != 0) return FilterError.InvalidData;
            result.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }) catch return FilterError.OutOfMemory;
            i += 1;
            continue;
        }

        if (ch < '!' or ch > 'u') return FilterError.InvalidData;

        group[group_len] = ch;
        group_len += 1;

        if (group_len == 5) {
            const bytes = ascii85DecodeGroup(&group, 5) orelse return FilterError.InvalidData;
            result.appendSlice(allocator, bytes[0..4]) catch return FilterError.OutOfMemory;
            group_len = 0;
        }

        i += 1;
    }

    // Process final partial group
    if (group_len > 1) {
        var padded: [5]u8 = .{ 'u', 'u', 'u', 'u', 'u' };
        @memcpy(padded[0..group_len], group[0..group_len]);
        const bytes = ascii85DecodeGroup(&padded, group_len) orelse return FilterError.InvalidData;
        result.appendSlice(allocator, bytes[0 .. group_len - 1]) catch return FilterError.OutOfMemory;
    } else if (group_len == 1) {
        return FilterError.InvalidData;
    }

    return result.toOwnedSlice(allocator) catch return FilterError.OutOfMemory;
}

fn ascii85DecodeGroup(group: *const [5]u8, actual_len: usize) ?[4]u8 {
    var value: u64 = 0;
    for (group) |ch| {
        value = value * 85 + (ch - '!');
    }
    if (actual_len == 5 and value > 0xFFFFFFFF) return null;
    if (value > 0xFFFFFFFF) value = 0xFFFFFFFF;

    const val32: u32 = @intCast(value);
    return .{
        @intCast((val32 >> 24) & 0xFF),
        @intCast((val32 >> 16) & 0xFF),
        @intCast((val32 >> 8) & 0xFF),
        @intCast(val32 & 0xFF),
    };
}

fn encodeAscii85(allocator: Allocator, data: []const u8) FilterError![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        const value: u32 = @as(u32, data[i]) << 24 |
            @as(u32, data[i + 1]) << 16 |
            @as(u32, data[i + 2]) << 8 |
            @as(u32, data[i + 3]);

        if (value == 0) {
            result.append(allocator, 'z') catch return FilterError.OutOfMemory;
        } else {
            var v = value;
            var digits: [5]u8 = undefined;
            var j: usize = 5;
            while (j > 0) {
                j -= 1;
                digits[j] = @intCast(v % 85 + '!');
                v /= 85;
            }
            result.appendSlice(allocator, &digits) catch return FilterError.OutOfMemory;
        }
    }

    // Handle remaining bytes (1-3)
    const remaining = data.len - i;
    if (remaining > 0) {
        var value: u32 = 0;
        for (0..remaining) |j| {
            value |= @as(u32, data[i + j]) << @intCast(24 - j * 8);
        }
        var v = value;
        var digits: [5]u8 = undefined;
        var j: usize = 5;
        while (j > 0) {
            j -= 1;
            digits[j] = @intCast(v % 85 + '!');
            v /= 85;
        }
        // Output remaining+1 digits
        result.appendSlice(allocator, digits[0 .. remaining + 1]) catch return FilterError.OutOfMemory;
    }

    // Append EOD marker
    result.appendSlice(allocator, "~>") catch return FilterError.OutOfMemory;

    return result.toOwnedSlice(allocator) catch return FilterError.OutOfMemory;
}

// ============================================================================
// ASCIIHexDecode
// ============================================================================

fn decodeAsciiHex(allocator: Allocator, input: []const u8) FilterError![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    var high_nibble: ?u4 = null;
    for (input) |ch| {
        if (ch == '>') break; // EOD

        if (isWhitespace(ch)) continue;

        const nibble = hexToNibble(ch) orelse return FilterError.InvalidData;

        if (high_nibble) |high| {
            result.append(allocator, @as(u8, high) << 4 | nibble) catch return FilterError.OutOfMemory;
            high_nibble = null;
        } else {
            high_nibble = nibble;
        }
    }

    // Odd number of digits: last digit treated as if followed by '0'
    if (high_nibble) |high| {
        result.append(allocator, @as(u8, high) << 4) catch return FilterError.OutOfMemory;
    }

    return result.toOwnedSlice(allocator) catch return FilterError.OutOfMemory;
}

fn encodeAsciiHex(allocator: Allocator, data: []const u8) FilterError![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    const hex_chars = "0123456789ABCDEF";
    for (data) |byte| {
        result.append(allocator, hex_chars[byte >> 4]) catch return FilterError.OutOfMemory;
        result.append(allocator, hex_chars[byte & 0x0F]) catch return FilterError.OutOfMemory;
    }
    result.append(allocator, '>') catch return FilterError.OutOfMemory;

    return result.toOwnedSlice(allocator) catch return FilterError.OutOfMemory;
}

fn hexToNibble(ch: u8) ?u4 {
    return switch (ch) {
        '0'...'9' => @intCast(ch - '0'),
        'A'...'F' => @intCast(ch - 'A' + 10),
        'a'...'f' => @intCast(ch - 'a' + 10),
        else => null,
    };
}

// ============================================================================
// LZWDecode
// ============================================================================

const CLEAR_TABLE: u16 = 256;
const EOD: u16 = 257;
const FIRST_CODE: u16 = 258;
const MAX_CODE: u16 = 4095;
const MAX_TABLE_SIZE: usize = 4096;

const DictEntry = struct {
    prefix: ?u16,
    suffix: u8,
    length: u16,
};

const BitReader = struct {
    data: []const u8,
    byte_pos: usize,
    bit_pos: u3,

    fn init(data: []const u8) BitReader {
        return .{ .data = data, .byte_pos = 0, .bit_pos = 0 };
    }

    fn readCode(self: *BitReader, bits: u4) ?u16 {
        var result: u16 = 0;
        var bits_needed: u4 = bits;

        while (bits_needed > 0) {
            if (self.byte_pos >= self.data.len) return null;

            const current_byte = self.data[self.byte_pos];
            const bits_in_byte: u4 = @intCast(8 - @as(u4, self.bit_pos));
            const bits_to_take: u4 = @min(bits_in_byte, bits_needed);

            const shift: u3 = @intCast(bits_in_byte - bits_to_take);
            const mask: u8 = @as(u8, @intCast((@as(u16, 1) << bits_to_take) - 1)) << shift;
            const extracted: u8 = (current_byte & mask) >> shift;

            result = (result << bits_to_take) | extracted;
            bits_needed -= bits_to_take;

            const new_bit_pos = @as(u4, self.bit_pos) + bits_to_take;
            if (new_bit_pos >= 8) {
                self.byte_pos += 1;
                self.bit_pos = 0;
            } else {
                self.bit_pos = @intCast(new_bit_pos);
            }
        }

        return result;
    }
};

fn decodeLzw(allocator: Allocator, input: []const u8) FilterError![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    var dict: [MAX_TABLE_SIZE]DictEntry = undefined;
    for (0..256) |i| {
        dict[i] = .{ .prefix = null, .suffix = @intCast(i), .length = 1 };
    }
    var next_code: u16 = FIRST_CODE;
    var code_bits: u4 = 9;
    var reader = BitReader.init(input);
    var prev_code: ?u16 = null;

    while (true) {
        const code = reader.readCode(code_bits) orelse break;

        if (code == EOD) break;
        if (code == CLEAR_TABLE) {
            next_code = FIRST_CODE;
            code_bits = 9;
            prev_code = null;
            continue;
        }

        if (code < next_code) {
            lzwOutputString(allocator, &result, &dict, code) catch return FilterError.OutOfMemory;
            if (prev_code) |pc| {
                if (next_code <= MAX_CODE) {
                    dict[next_code] = .{
                        .prefix = pc,
                        .suffix = lzwGetFirstByte(&dict, code),
                        .length = dict[pc].length + 1,
                    };
                    next_code += 1;
                    if (next_code == (@as(u16, 1) << code_bits) and code_bits < 12) {
                        code_bits += 1;
                    }
                }
            }
        } else if (code == next_code) {
            if (prev_code) |pc| {
                const first_byte = lzwGetFirstByte(&dict, pc);
                lzwOutputString(allocator, &result, &dict, pc) catch return FilterError.OutOfMemory;
                result.append(allocator, first_byte) catch return FilterError.OutOfMemory;
                if (next_code <= MAX_CODE) {
                    dict[next_code] = .{
                        .prefix = pc,
                        .suffix = first_byte,
                        .length = dict[pc].length + 1,
                    };
                    next_code += 1;
                    if (next_code == (@as(u16, 1) << code_bits) and code_bits < 12) {
                        code_bits += 1;
                    }
                }
            } else {
                return FilterError.InvalidData;
            }
        } else {
            return FilterError.InvalidData;
        }

        prev_code = code;
    }

    return result.toOwnedSlice(allocator) catch return FilterError.OutOfMemory;
}

fn lzwOutputString(allocator: Allocator, result: *std.ArrayListUnmanaged(u8), dict: []const DictEntry, code: u16) !void {
    const entry = dict[code];
    const len = entry.length;
    result.ensureUnusedCapacity(allocator, len) catch return error.OutOfMemory;
    const start_pos = result.items.len;
    result.items.len += len;

    var pos: usize = start_pos + len;
    var current: u16 = code;
    while (true) {
        pos -= 1;
        result.items[pos] = dict[current].suffix;
        if (dict[current].prefix) |prefix| {
            current = prefix;
        } else break;
    }
}

fn lzwGetFirstByte(dict: []const DictEntry, code: u16) u8 {
    var current = code;
    while (dict[current].prefix) |prefix| {
        current = prefix;
    }
    return dict[current].suffix;
}

// ============================================================================
// RunLengthDecode
// ============================================================================

fn decodeRunLength(allocator: Allocator, input: []const u8) FilterError![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const length_byte = input[i];
        i += 1;

        if (length_byte == 128) break; // EOD

        if (length_byte < 128) {
            const count = @as(usize, length_byte) + 1;
            if (i + count > input.len) return FilterError.InvalidData;
            result.appendSlice(allocator, input[i .. i + count]) catch return FilterError.OutOfMemory;
            i += count;
        } else {
            if (i >= input.len) return FilterError.InvalidData;
            const count = 257 - @as(usize, length_byte);
            result.appendNTimes(allocator, input[i], count) catch return FilterError.OutOfMemory;
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator) catch return FilterError.OutOfMemory;
}

// ============================================================================
// Helpers
// ============================================================================

fn isWhitespace(ch: u8) bool {
    return switch (ch) {
        ' ', '\t', '\n', '\r', '\x0c', '\x00' => true,
        else => false,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "detectFilter names" {
    try std.testing.expectEqual(FilterType.flate, detectFilter("FlateDecode"));
    try std.testing.expectEqual(FilterType.flate, detectFilter("/FlateDecode"));
    try std.testing.expectEqual(FilterType.flate, detectFilter("Fl"));
    try std.testing.expectEqual(FilterType.ascii85, detectFilter("ASCII85Decode"));
    try std.testing.expectEqual(FilterType.ascii_hex, detectFilter("ASCIIHexDecode"));
    try std.testing.expectEqual(FilterType.lzw, detectFilter("LZWDecode"));
    try std.testing.expectEqual(FilterType.run_length, detectFilter("RunLengthDecode"));
    try std.testing.expectEqual(FilterType.unknown, detectFilter("SomethingElse"));
}

test "FlateDecode round-trip" {
    const allocator = std.testing.allocator;
    const original = "Hello, PDF stream! This tests FlateDecode round-trip.";

    const encoded = try encodeFilter(allocator, original, .flate);
    defer allocator.free(encoded);

    const decoded = try decodeFilter(allocator, encoded, .flate);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}

test "ASCII85 decode" {
    const allocator = std.testing.allocator;
    const result = try decodeFilter(allocator, "87cURDZ~>", .ascii85);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "ASCII85 round-trip" {
    const allocator = std.testing.allocator;
    const original = "Hello, World!123";

    const encoded = try encodeFilter(allocator, original, .ascii85);
    defer allocator.free(encoded);

    const decoded = try decodeFilter(allocator, encoded, .ascii85);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}

test "ASCIIHex decode" {
    const allocator = std.testing.allocator;
    const result = try decodeFilter(allocator, "48656C6C6F>", .ascii_hex);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "ASCIIHex round-trip" {
    const allocator = std.testing.allocator;
    const original = "Hello";

    const encoded = try encodeFilter(allocator, original, .ascii_hex);
    defer allocator.free(encoded);

    const decoded = try decodeFilter(allocator, encoded, .ascii_hex);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}

test "RunLength decode literal" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 0x04, 'H', 'e', 'l', 'l', 'o', 128 };
    const result = try decodeFilter(allocator, &input, .run_length);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "RunLength decode repeat" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 0xFC, 'A', 128 };
    const result = try decodeFilter(allocator, &input, .run_length);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("AAAAA", result);
}

test "filter chain decode" {
    const allocator = std.testing.allocator;
    const original = "Hello filter chain";

    // Encode with flate
    const compressed = try encodeFilter(allocator, original, .flate);
    defer allocator.free(compressed);

    // Then encode with ascii_hex
    const hex_encoded = try encodeFilter(allocator, compressed, .ascii_hex);
    defer allocator.free(hex_encoded);

    // Decode chain: ascii_hex first, then flate
    const filters = [_]FilterType{ .ascii_hex, .flate };
    const decoded = try applyDecodeChain(allocator, hex_encoded, &filters);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}
