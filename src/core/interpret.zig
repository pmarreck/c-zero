//! Type Interpretation — bidirectional binary ↔ human-readable conversion
//!
//! C0 is type-agnostic — all values are raw bytes. This module provides
//! a "lens" to interpret bytes as specific types and encode human-readable
//! text back to bytes. Used by `c0 get --as` and `c0 set --as`.
//!
//! Default endianness is little-endian (modern convention).
//! Append "be" for big-endian variants (e.g., u32be, f64be).

const std = @import("std");

pub const TypeSpec = enum {
    // Unsigned integers (LE)
    uint8,
    uint16,
    uint32,
    uint64,
    // Signed integers (LE)
    int8,
    int16,
    int32,
    int64,
    // Unsigned integers (BE)
    uint16be,
    uint32be,
    uint64be,
    // Signed integers (BE)
    int16be,
    int32be,
    int64be,
    // Floats (LE)
    float32,
    float64,
    // Floats (BE)
    float32be,
    float64be,
    // UUID
    uuid,
    // Datetime (epoch → ISO 8601, stored as i64 LE)
    datetime_s,
    datetime_ms,
    datetime_ns,
    // Text encoding
    utf16,
    utf16be,
    // Raw representations
    hex,
    base64,
    // Arbitrary-width unsigned integers
    bigint,
    bigint_be,
};

pub const InterpretError = error{
    InsufficientBytes,
    InvalidFormat,
    OutOfMemory,
    UnknownType,
};

/// Parse a CLI type name string into a TypeSpec.
pub fn parseTypeName(name: []const u8) InterpretError!TypeSpec {
    const map = .{
        .{ "u8", TypeSpec.uint8 },
        .{ "u16", TypeSpec.uint16 },
        .{ "u32", TypeSpec.uint32 },
        .{ "u64", TypeSpec.uint64 },
        .{ "i8", TypeSpec.int8 },
        .{ "i16", TypeSpec.int16 },
        .{ "i32", TypeSpec.int32 },
        .{ "i64", TypeSpec.int64 },
        .{ "u16be", TypeSpec.uint16be },
        .{ "u32be", TypeSpec.uint32be },
        .{ "u64be", TypeSpec.uint64be },
        .{ "i16be", TypeSpec.int16be },
        .{ "i32be", TypeSpec.int32be },
        .{ "i64be", TypeSpec.int64be },
        .{ "f32", TypeSpec.float32 },
        .{ "f64", TypeSpec.float64 },
        .{ "f32be", TypeSpec.float32be },
        .{ "f64be", TypeSpec.float64be },
        .{ "uuid", TypeSpec.uuid },
        .{ "datetime-s", TypeSpec.datetime_s },
        .{ "datetime-ms", TypeSpec.datetime_ms },
        .{ "datetime-ns", TypeSpec.datetime_ns },
        .{ "utf16", TypeSpec.utf16 },
        .{ "utf16be", TypeSpec.utf16be },
        .{ "hex", TypeSpec.hex },
        .{ "base64", TypeSpec.base64 },
        .{ "bigint", TypeSpec.bigint },
        .{ "bigint-be", TypeSpec.bigint_be },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return InterpretError.UnknownType;
}

// ── interpret: bytes → human-readable text ─────────────────────────────

/// Interpret raw bytes as the given type, returning a human-readable string.
pub fn interpret(allocator: std.mem.Allocator, bytes: []const u8, spec: TypeSpec) InterpretError![]u8 {
    return switch (spec) {
        .uint8 => interpretInt(u8, .little, allocator, bytes),
        .uint16 => interpretInt(u16, .little, allocator, bytes),
        .uint32 => interpretInt(u32, .little, allocator, bytes),
        .uint64 => interpretInt(u64, .little, allocator, bytes),
        .int8 => interpretInt(i8, .little, allocator, bytes),
        .int16 => interpretInt(i16, .little, allocator, bytes),
        .int32 => interpretInt(i32, .little, allocator, bytes),
        .int64 => interpretInt(i64, .little, allocator, bytes),
        .uint16be => interpretInt(u16, .big, allocator, bytes),
        .uint32be => interpretInt(u32, .big, allocator, bytes),
        .uint64be => interpretInt(u64, .big, allocator, bytes),
        .int16be => interpretInt(i16, .big, allocator, bytes),
        .int32be => interpretInt(i32, .big, allocator, bytes),
        .int64be => interpretInt(i64, .big, allocator, bytes),
        .float32 => interpretFloat(f32, .little, allocator, bytes),
        .float64 => interpretFloat(f64, .little, allocator, bytes),
        .float32be => interpretFloat(f32, .big, allocator, bytes),
        .float64be => interpretFloat(f64, .big, allocator, bytes),
        .uuid => interpretUuid(allocator, bytes),
        .datetime_s => interpretDatetime(allocator, bytes, 1),
        .datetime_ms => interpretDatetime(allocator, bytes, 1_000),
        .datetime_ns => interpretDatetime(allocator, bytes, 1_000_000_000),
        .utf16 => interpretUtf16(allocator, bytes, .little),
        .utf16be => interpretUtf16(allocator, bytes, .big),
        .hex => interpretHex(allocator, bytes),
        .base64 => interpretBase64(allocator, bytes),
        .bigint => interpretBigint(allocator, bytes, false),
        .bigint_be => interpretBigint(allocator, bytes, true),
    };
}

// ── encode: human-readable text → bytes ────────────────────────────────

/// Encode a human-readable string as raw bytes for the given type.
pub fn encode(allocator: std.mem.Allocator, text: []const u8, spec: TypeSpec) InterpretError![]u8 {
    return switch (spec) {
        .uint8 => encodeInt(u8, .little, allocator, text),
        .uint16 => encodeInt(u16, .little, allocator, text),
        .uint32 => encodeInt(u32, .little, allocator, text),
        .uint64 => encodeInt(u64, .little, allocator, text),
        .int8 => encodeInt(i8, .little, allocator, text),
        .int16 => encodeInt(i16, .little, allocator, text),
        .int32 => encodeInt(i32, .little, allocator, text),
        .int64 => encodeInt(i64, .little, allocator, text),
        .uint16be => encodeInt(u16, .big, allocator, text),
        .uint32be => encodeInt(u32, .big, allocator, text),
        .uint64be => encodeInt(u64, .big, allocator, text),
        .int16be => encodeInt(i16, .big, allocator, text),
        .int32be => encodeInt(i32, .big, allocator, text),
        .int64be => encodeInt(i64, .big, allocator, text),
        .float32 => encodeFloat(f32, .little, allocator, text),
        .float64 => encodeFloat(f64, .little, allocator, text),
        .float32be => encodeFloat(f32, .big, allocator, text),
        .float64be => encodeFloat(f64, .big, allocator, text),
        .uuid => encodeUuid(allocator, text),
        .datetime_s => encodeDatetime(allocator, text, 1),
        .datetime_ms => encodeDatetime(allocator, text, 1_000),
        .datetime_ns => encodeDatetime(allocator, text, 1_000_000_000),
        .utf16 => encodeUtf16(allocator, text, .little),
        .utf16be => encodeUtf16(allocator, text, .big),
        .hex => encodeHex(allocator, text),
        .base64 => encodeBase64(allocator, text),
        .bigint => encodeBigint(allocator, text, false),
        .bigint_be => encodeBigint(allocator, text, true),
    };
}

// ── Integer implementation ─────────────────────────────────────────────

fn interpretInt(comptime T: type, comptime endian: std.builtin.Endian, allocator: std.mem.Allocator, bytes: []const u8) InterpretError![]u8 {
    const size = @sizeOf(T);
    if (bytes.len < size) return InterpretError.InsufficientBytes;
    const val = std.mem.readInt(T, bytes[0..size], endian);
    return std.fmt.allocPrint(allocator, "{d}", .{val}) catch return InterpretError.OutOfMemory;
}

fn encodeInt(comptime T: type, comptime endian: std.builtin.Endian, allocator: std.mem.Allocator, text: []const u8) InterpretError![]u8 {
    const val = std.fmt.parseInt(T, text, 10) catch return InterpretError.InvalidFormat;
    const size = @sizeOf(T);
    const result = allocator.alloc(u8, size) catch return InterpretError.OutOfMemory;
    std.mem.writeInt(T, result[0..size], val, endian);
    return result;
}

// ── Float implementation ───────────────────────────────────────────────

fn interpretFloat(comptime T: type, comptime endian: std.builtin.Endian, allocator: std.mem.Allocator, bytes: []const u8) InterpretError![]u8 {
    const size = @sizeOf(T);
    if (bytes.len < size) return InterpretError.InsufficientBytes;
    const IntType = std.meta.Int(.unsigned, @bitSizeOf(T));
    const bits = std.mem.readInt(IntType, bytes[0..size], endian);
    const val: T = @bitCast(bits);
    // Check for special values
    if (std.math.isNan(val)) {
        return allocator.dupe(u8, "NaN") catch return InterpretError.OutOfMemory;
    }
    if (std.math.isInf(val)) {
        if (val < 0) {
            return allocator.dupe(u8, "-Infinity") catch return InterpretError.OutOfMemory;
        }
        return allocator.dupe(u8, "Infinity") catch return InterpretError.OutOfMemory;
    }
    return std.fmt.allocPrint(allocator, "{d}", .{val}) catch return InterpretError.OutOfMemory;
}

fn encodeFloat(comptime T: type, comptime endian: std.builtin.Endian, allocator: std.mem.Allocator, text: []const u8) InterpretError![]u8 {
    const val = std.fmt.parseFloat(T, text) catch return InterpretError.InvalidFormat;
    const IntType = std.meta.Int(.unsigned, @bitSizeOf(T));
    const bits: IntType = @bitCast(val);
    const size = @sizeOf(T);
    const result = allocator.alloc(u8, size) catch return InterpretError.OutOfMemory;
    std.mem.writeInt(IntType, result[0..size], bits, endian);
    return result;
}

// ── UUID implementation ────────────────────────────────────────────────

fn interpretUuid(allocator: std.mem.Allocator, bytes: []const u8) InterpretError![]u8 {
    if (bytes.len < 16) return InterpretError.InsufficientBytes;
    const result = allocator.alloc(u8, 36) catch return InterpretError.OutOfMemory;
    var pos: usize = 0;
    for (0..16) |i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            result[pos] = '-';
            pos += 1;
        }
        result[pos] = hexChar(bytes[i] >> 4);
        result[pos + 1] = hexChar(@truncate(bytes[i] & 0x0f));
        pos += 2;
    }
    return result;
}

fn encodeUuid(allocator: std.mem.Allocator, text: []const u8) InterpretError![]u8 {
    // Strip dashes, decode hex
    var hex_buf: [32]u8 = undefined;
    var hex_len: usize = 0;
    for (text) |c| {
        if (c == '-') continue;
        if (hex_len >= 32) return InterpretError.InvalidFormat;
        hex_buf[hex_len] = c;
        hex_len += 1;
    }
    if (hex_len != 32) return InterpretError.InvalidFormat;

    const result = allocator.alloc(u8, 16) catch return InterpretError.OutOfMemory;
    for (0..16) |i| {
        const hi = parseHexChar(hex_buf[i * 2]) orelse return InterpretError.InvalidFormat;
        const lo = parseHexChar(hex_buf[i * 2 + 1]) orelse return InterpretError.InvalidFormat;
        result[i] = (hi << 4) | lo;
    }
    return result;
}

// ── Datetime implementation ────────────────────────────────────────────

const DateTime = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

fn interpretDatetime(allocator: std.mem.Allocator, bytes: []const u8, comptime divisor: u64) InterpretError![]u8 {
    if (bytes.len < 8) return InterpretError.InsufficientBytes;
    const raw = std.mem.readInt(i64, bytes[0..8], .little);

    // Split into seconds and fractional part
    const epoch_secs = @divFloor(raw, @as(i64, @intCast(divisor)));
    const remainder = @mod(raw, @as(i64, @intCast(divisor)));
    const frac: u64 = @intCast(if (remainder < 0) remainder + @as(i64, @intCast(divisor)) else remainder);

    const dt = epochToDatetime(epoch_secs);

    // Handle year sign separately to avoid '+' prefix from signed formatting
    const year_abs: u32 = @intCast(@abs(dt.year));
    const sign: []const u8 = if (dt.year < 0) "-" else "";

    if (divisor == 1) {
        return std.fmt.allocPrint(allocator, "{s}{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            sign, year_abs, dt.month, dt.day, dt.hour, dt.minute, dt.second,
        }) catch return InterpretError.OutOfMemory;
    } else if (divisor == 1_000) {
        return std.fmt.allocPrint(allocator, "{s}{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            sign, year_abs, dt.month, dt.day, dt.hour, dt.minute, dt.second, frac,
        }) catch return InterpretError.OutOfMemory;
    } else {
        // nanoseconds
        return std.fmt.allocPrint(allocator, "{s}{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z", .{
            sign, year_abs, dt.month, dt.day, dt.hour, dt.minute, dt.second, frac,
        }) catch return InterpretError.OutOfMemory;
    }
}

fn encodeDatetime(allocator: std.mem.Allocator, text: []const u8, comptime divisor: u64) InterpretError![]u8 {
    const parsed = parseIso8601(text) catch return InterpretError.InvalidFormat;
    const epoch_secs = datetimeToEpoch(parsed.dt);
    const total = epoch_secs * @as(i64, @intCast(divisor)) + @as(i64, @intCast(parsed.frac));

    const result = allocator.alloc(u8, 8) catch return InterpretError.OutOfMemory;
    std.mem.writeInt(i64, result[0..8], total, .little);
    return result;
}

// Hinnant's civil_from_days: epoch days → year/month/day
fn epochToDatetime(epoch_secs: i64) DateTime {
    const secs_per_day: i64 = 86400;
    var days = @divFloor(epoch_secs, secs_per_day);
    var time_of_day = @mod(epoch_secs, secs_per_day);
    if (time_of_day < 0) {
        time_of_day += secs_per_day;
        days -= 1;
    }

    // Shift epoch from 1970-01-01 to 0000-03-01
    const z = days + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe_i: i64 = z - era * 146097;
    const doe: u64 = @intCast(doe_i); // [0, 146096]
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    const y_i: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    const mp: u64 = (5 * doy + 2) / 153; // [0, 11]
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1); // [1, 31]
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9); // [1, 12]

    return .{
        .year = @intCast(y_i + @as(i64, @intFromBool(m <= 2))),
        .month = m,
        .day = d,
        .hour = @intCast(@divFloor(time_of_day, 3600)),
        .minute = @intCast(@divFloor(@mod(time_of_day, 3600), 60)),
        .second = @intCast(@mod(time_of_day, 60)),
    };
}

// Hinnant's days_from_civil: year/month/day → epoch days
fn datetimeToEpoch(dt: DateTime) i64 {
    var y: i64 = dt.year;
    const m: i64 = dt.month;
    const d: i64 = dt.day;

    if (m <= 2) y -= 1;
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: u64 = @intCast(y - era * 400); // [0, 399]
    const mp: u64 = @intCast(if (m > 2) m - 3 else m + 9);
    const doy: u64 = (153 * mp + 2) / 5 + @as(u64, @intCast(d)) - 1; // [0, 365]
    const doe: u64 = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    const days: i64 = era * 146097 + @as(i64, @intCast(doe)) - 719468;

    return days * 86400 + @as(i64, dt.hour) * 3600 + @as(i64, dt.minute) * 60 + @as(i64, dt.second);
}

const Iso8601Parsed = struct { dt: DateTime, frac: u64 };

fn parseIso8601(text: []const u8) !Iso8601Parsed {
    // Minimum: "YYYY-MM-DDThh:mm:ssZ" = 20 chars
    if (text.len < 20) return error.InvalidFormat;
    if (text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':' or text[16] != ':')
        return error.InvalidFormat;

    const year = std.fmt.parseInt(i32, text[0..4], 10) catch return error.InvalidFormat;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return error.InvalidFormat;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return error.InvalidFormat;
    const hour = std.fmt.parseInt(u8, text[11..13], 10) catch return error.InvalidFormat;
    const minute = std.fmt.parseInt(u8, text[14..16], 10) catch return error.InvalidFormat;
    const second = std.fmt.parseInt(u8, text[17..19], 10) catch return error.InvalidFormat;

    var frac: u64 = 0;
    if (text.len > 19 and text[19] == '.') {
        var end: usize = 20;
        while (end < text.len and text[end] >= '0' and text[end] <= '9') : (end += 1) {}
        const frac_str = text[20..end];
        // Parse and scale to appropriate precision
        var raw = std.fmt.parseInt(u64, frac_str, 10) catch return error.InvalidFormat;
        const digits = frac_str.len;
        // Scale: if 3 digits → milliseconds, if 9 → nanoseconds, etc.
        // We just pass through the raw parsed value — the caller's divisor handles it
        if (digits < 9) {
            var scale: usize = 9 - digits;
            while (scale > 0) : (scale -= 1) raw *= 10;
        }
        frac = raw;
    }

    return .{
        .dt = .{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute, .second = second },
        .frac = frac,
    };
}

// ── UTF-16 implementation ──────────────────────────────────────────────

fn interpretUtf16(allocator: std.mem.Allocator, bytes: []const u8, comptime endian: std.builtin.Endian) InterpretError![]u8 {
    if (bytes.len % 2 != 0) return InterpretError.InvalidFormat;

    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i + 1 < bytes.len) {
        const unit = std.mem.readInt(u16, bytes[i..][0..2], endian);
        i += 2;

        var codepoint: u21 = undefined;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            // High surrogate — need low surrogate
            if (i + 1 >= bytes.len) return InterpretError.InvalidFormat;
            const low = std.mem.readInt(u16, bytes[i..][0..2], endian);
            i += 2;
            if (low < 0xDC00 or low > 0xDFFF) return InterpretError.InvalidFormat;
            codepoint = 0x10000 + (@as(u21, unit - 0xD800) << 10) + @as(u21, low - 0xDC00);
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            return InterpretError.InvalidFormat; // Lone low surrogate
        } else {
            codepoint = @intCast(unit);
        }

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return InterpretError.InvalidFormat;
        result.appendSlice(allocator, buf[0..len]) catch return InterpretError.OutOfMemory;
    }

    return result.toOwnedSlice(allocator) catch return InterpretError.OutOfMemory;
}

fn encodeUtf16(allocator: std.mem.Allocator, text: []const u8, comptime endian: std.builtin.Endian) InterpretError![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch return InterpretError.InvalidFormat;
        if (i + cp_len > text.len) return InterpretError.InvalidFormat;
        const cp = std.unicode.utf8Decode(text[i..][0..cp_len]) catch return InterpretError.InvalidFormat;
        i += cp_len;

        if (cp < 0x10000) {
            var buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &buf, @intCast(cp), endian);
            result.appendSlice(allocator, &buf) catch return InterpretError.OutOfMemory;
        } else {
            // Surrogate pair
            const val = cp - 0x10000;
            const high: u16 = @intCast(0xD800 + (val >> 10));
            const low: u16 = @intCast(0xDC00 + (val & 0x3FF));
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u16, buf[0..2], high, endian);
            std.mem.writeInt(u16, buf[2..4], low, endian);
            result.appendSlice(allocator, &buf) catch return InterpretError.OutOfMemory;
        }
    }

    return result.toOwnedSlice(allocator) catch return InterpretError.OutOfMemory;
}

// ── Hex implementation ─────────────────────────────────────────────────

fn interpretHex(allocator: std.mem.Allocator, bytes: []const u8) InterpretError![]u8 {
    if (bytes.len == 0) {
        return allocator.dupe(u8, "") catch return InterpretError.OutOfMemory;
    }
    const result = allocator.alloc(u8, bytes.len * 2) catch return InterpretError.OutOfMemory;
    for (bytes, 0..) |b, i| {
        result[i * 2] = hexChar(b >> 4);
        result[i * 2 + 1] = hexChar(@truncate(b & 0x0f));
    }
    return result;
}

fn encodeHex(allocator: std.mem.Allocator, text: []const u8) InterpretError![]u8 {
    if (text.len % 2 != 0) return InterpretError.InvalidFormat;
    const result = allocator.alloc(u8, text.len / 2) catch return InterpretError.OutOfMemory;
    for (0..result.len) |i| {
        const hi = parseHexChar(text[i * 2]) orelse return InterpretError.InvalidFormat;
        const lo = parseHexChar(text[i * 2 + 1]) orelse return InterpretError.InvalidFormat;
        result[i] = (hi << 4) | lo;
    }
    return result;
}

// ── Base64 implementation ──────────────────────────────────────────────

fn interpretBase64(allocator: std.mem.Allocator, bytes: []const u8) InterpretError![]u8 {
    const encoder = std.base64.standard;
    const len = encoder.Encoder.calcSize(bytes.len);
    const result = allocator.alloc(u8, len) catch return InterpretError.OutOfMemory;
    _ = encoder.Encoder.encode(result, bytes);
    return result;
}

fn encodeBase64(allocator: std.mem.Allocator, text: []const u8) InterpretError![]u8 {
    const decoder = std.base64.standard;
    const max_len = decoder.Decoder.calcSizeForSlice(text) catch return InterpretError.InvalidFormat;
    const result = allocator.alloc(u8, max_len) catch return InterpretError.OutOfMemory;
    decoder.Decoder.decode(result, text) catch return InterpretError.InvalidFormat;
    return result;
}

// ── BigInt implementation ──────────────────────────────────────────────

fn interpretBigint(allocator: std.mem.Allocator, bytes: []const u8, big_endian: bool) InterpretError![]u8 {
    if (bytes.len == 0) {
        return allocator.dupe(u8, "0") catch return InterpretError.OutOfMemory;
    }

    // Copy bytes in LE order for processing
    var num = allocator.alloc(u8, bytes.len) catch return InterpretError.OutOfMemory;
    defer allocator.free(num);
    if (big_endian) {
        for (0..bytes.len) |i| num[i] = bytes[bytes.len - 1 - i];
    } else {
        @memcpy(num, bytes);
    }

    // Trim trailing zeros (high bytes in LE)
    var len = num.len;
    while (len > 1 and num[len - 1] == 0) len -= 1;

    // All zeros?
    if (len == 1 and num[0] == 0) {
        return allocator.dupe(u8, "0") catch return InterpretError.OutOfMemory;
    }

    // Repeatedly divide by 10, collecting remainders
    var digits: std.ArrayListUnmanaged(u8) = .{};
    defer digits.deinit(allocator);

    while (len > 0) {
        // Divide num[0..len] by 10
        var remainder: u16 = 0;
        var i = len;
        while (i > 0) {
            i -= 1;
            const dividend: u16 = (remainder << 8) | num[i];
            num[i] = @intCast(dividend / 10);
            remainder = dividend % 10;
        }
        digits.append(allocator, '0' + @as(u8, @intCast(remainder))) catch return InterpretError.OutOfMemory;

        // Trim leading zeros (high end in LE)
        while (len > 0 and num[len - 1] == 0) len -= 1;
    }

    if (digits.items.len == 0) {
        digits.append(allocator, '0') catch return InterpretError.OutOfMemory;
    }

    const result = digits.toOwnedSlice(allocator) catch return InterpretError.OutOfMemory;
    std.mem.reverse(u8, result);
    return result;
}

fn encodeBigint(allocator: std.mem.Allocator, text: []const u8, big_endian: bool) InterpretError![]u8 {
    if (text.len == 0) return InterpretError.InvalidFormat;

    // Start with [0], for each digit: multiply by 10 and add
    var num: std.ArrayListUnmanaged(u8) = .{};
    defer num.deinit(allocator);
    num.append(allocator, 0) catch return InterpretError.OutOfMemory;

    for (text) |c| {
        if (c < '0' or c > '9') return InterpretError.InvalidFormat;
        const digit: u16 = c - '0';

        // Multiply by 10
        var carry: u16 = 0;
        for (num.items) |*b| {
            const product: u16 = @as(u16, b.*) * 10 + carry;
            b.* = @intCast(product & 0xff);
            carry = product >> 8;
        }
        if (carry > 0) {
            num.append(allocator, @intCast(carry)) catch return InterpretError.OutOfMemory;
        }

        // Add digit
        carry = digit;
        for (num.items) |*b| {
            const sum: u16 = @as(u16, b.*) + carry;
            b.* = @intCast(sum & 0xff);
            carry = sum >> 8;
            if (carry == 0) break;
        }
        if (carry > 0) {
            num.append(allocator, @intCast(carry)) catch return InterpretError.OutOfMemory;
        }
    }

    // Result is in LE order
    if (big_endian) std.mem.reverse(u8, num.items);

    return num.toOwnedSlice(allocator) catch return InterpretError.OutOfMemory;
}

// ── Helpers ────────────────────────────────────────────────────────────

fn hexChar(v: u8) u8 {
    return if (v < 10) '0' + v else 'a' + v - 10;
}

fn parseHexChar(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

// ════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════

// ── parseTypeName tests ────────────────────────────────────────────────

test "parseTypeName: integer types" {
    try std.testing.expectEqual(TypeSpec.uint8, try parseTypeName("u8"));
    try std.testing.expectEqual(TypeSpec.int32, try parseTypeName("i32"));
    try std.testing.expectEqual(TypeSpec.uint64, try parseTypeName("u64"));
    try std.testing.expectEqual(TypeSpec.int32be, try parseTypeName("i32be"));
    try std.testing.expectEqual(TypeSpec.uint16be, try parseTypeName("u16be"));
}

test "parseTypeName: float types" {
    try std.testing.expectEqual(TypeSpec.float32, try parseTypeName("f32"));
    try std.testing.expectEqual(TypeSpec.float64, try parseTypeName("f64"));
    try std.testing.expectEqual(TypeSpec.float32be, try parseTypeName("f32be"));
}

test "parseTypeName: other types" {
    try std.testing.expectEqual(TypeSpec.uuid, try parseTypeName("uuid"));
    try std.testing.expectEqual(TypeSpec.datetime_s, try parseTypeName("datetime-s"));
    try std.testing.expectEqual(TypeSpec.hex, try parseTypeName("hex"));
    try std.testing.expectEqual(TypeSpec.base64, try parseTypeName("base64"));
    try std.testing.expectEqual(TypeSpec.bigint, try parseTypeName("bigint"));
    try std.testing.expectEqual(TypeSpec.bigint_be, try parseTypeName("bigint-be"));
}

test "parseTypeName: unknown type" {
    try std.testing.expectError(InterpretError.UnknownType, parseTypeName("nope"));
}

// ── Integer tests ──────────────────────────────────────────────────────

test "interpret u8" {
    const allocator = std.testing.allocator;
    const result = try interpret(allocator, &.{42}, .uint8);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("42", result);
}

test "interpret i8 negative" {
    const allocator = std.testing.allocator;
    const result = try interpret(allocator, &.{0xFE}, .int8); // -2
    defer allocator.free(result);
    try std.testing.expectEqualStrings("-2", result);
}

test "interpret u16 little-endian" {
    const allocator = std.testing.allocator;
    // 0x0100 = 256 in LE: low byte first
    const result = try interpret(allocator, &.{ 0x00, 0x01 }, .uint16);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("256", result);
}

test "interpret u16 big-endian" {
    const allocator = std.testing.allocator;
    // 0x0100 = 256 in BE: high byte first
    const result = try interpret(allocator, &.{ 0x01, 0x00 }, .uint16be);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("256", result);
}

test "interpret u32 little-endian" {
    const allocator = std.testing.allocator;
    // 0x01020304 = 16909060 → LE bytes: 04, 03, 02, 01
    const result = try interpret(allocator, &.{ 0x04, 0x03, 0x02, 0x01 }, .uint32);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("16909060", result);
}

test "interpret u32 big-endian" {
    const allocator = std.testing.allocator;
    // Same value in BE: 01, 02, 03, 04
    const result = try interpret(allocator, &.{ 0x01, 0x02, 0x03, 0x04 }, .uint32be);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("16909060", result);
}

test "interpret u32 endianness: same bytes, different values" {
    const allocator = std.testing.allocator;
    const bytes = [_]u8{ 0x01, 0x00, 0x00, 0x00 };

    const le = try interpret(allocator, &bytes, .uint32);
    defer allocator.free(le);
    try std.testing.expectEqualStrings("1", le); // LE: 0x00000001

    const be = try interpret(allocator, &bytes, .uint32be);
    defer allocator.free(be);
    try std.testing.expectEqualStrings("16777216", be); // BE: 0x01000000
}

test "interpret i32 little-endian negative" {
    const allocator = std.testing.allocator;
    // -1 = 0xFFFFFFFF → LE: FF FF FF FF
    const result = try interpret(allocator, &.{ 0xFF, 0xFF, 0xFF, 0xFF }, .int32);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("-1", result);
}

test "interpret u64 little-endian" {
    const allocator = std.testing.allocator;
    // 1 in u64 LE
    const result = try interpret(allocator, &.{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, .uint64);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("1", result);
}

test "interpret u64 big-endian" {
    const allocator = std.testing.allocator;
    // 1 in u64 BE
    const result = try interpret(allocator, &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 }, .uint64be);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("1", result);
}

test "encode u32 little-endian" {
    const allocator = std.testing.allocator;
    const result = try encode(allocator, "16909060", .uint32);
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x03, 0x02, 0x01 }, result);
}

test "encode u32 big-endian" {
    const allocator = std.testing.allocator;
    const result = try encode(allocator, "16909060", .uint32be);
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03, 0x04 }, result);
}

test "integer round-trip u32" {
    const allocator = std.testing.allocator;
    const original = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const text = try interpret(allocator, &original, .uint32);
    defer allocator.free(text);
    const encoded = try encode(allocator, text, .uint32);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &original, encoded);
}

test "integer round-trip i64" {
    const allocator = std.testing.allocator;
    const original = [_]u8{ 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const text = try interpret(allocator, &original, .int64);
    defer allocator.free(text);
    const encoded = try encode(allocator, text, .int64);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &original, encoded);
}

test "insufficient bytes" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(InterpretError.InsufficientBytes, interpret(allocator, &.{0x01}, .uint32));
}

// ── Float tests ────────────────────────────────────────────────────────

test "interpret f32 little-endian" {
    const allocator = std.testing.allocator;
    // 3.14 as f32 LE
    const val: f32 = 3.14;
    const bits: u32 = @bitCast(val);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, bits, .little);

    const result = try interpret(allocator, &bytes, .float32);
    defer allocator.free(result);

    // Parse back to verify
    const parsed = try std.fmt.parseFloat(f32, result);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), parsed, 0.001);
}

test "interpret f32 big-endian" {
    const allocator = std.testing.allocator;
    const val: f32 = 3.14;
    const bits: u32 = @bitCast(val);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, bits, .big);

    const result = try interpret(allocator, &bytes, .float32be);
    defer allocator.free(result);

    const parsed = try std.fmt.parseFloat(f32, result);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), parsed, 0.001);
}

test "f32 endianness: same bytes, different values" {
    const allocator = std.testing.allocator;
    // f32 1.0 in LE: 00 00 80 3F
    const le_bytes = [_]u8{ 0x00, 0x00, 0x80, 0x3F };

    const le_result = try interpret(allocator, &le_bytes, .float32);
    defer allocator.free(le_result);
    const le_val = try std.fmt.parseFloat(f32, le_result);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), le_val, 0.001);

    // Same bytes interpreted as BE give a very different value
    const be_result = try interpret(allocator, &le_bytes, .float32be);
    defer allocator.free(be_result);
    const be_val = try std.fmt.parseFloat(f32, be_result);
    try std.testing.expect(@abs(be_val - 1.0) > 0.001); // Definitely not 1.0
}

test "float round-trip f64" {
    const allocator = std.testing.allocator;
    const val: f64 = 3.141592653589793;
    const bits: u64 = @bitCast(val);
    var original: [8]u8 = undefined;
    std.mem.writeInt(u64, &original, bits, .little);

    const text = try interpret(allocator, &original, .float64);
    defer allocator.free(text);
    const encoded = try encode(allocator, text, .float64);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &original, encoded);
}

test "encode f32 little-endian" {
    const allocator = std.testing.allocator;
    const result = try encode(allocator, "1.0", .float32);
    defer allocator.free(result);
    // f32 1.0 in LE: 00 00 80 3F
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x80, 0x3F }, result);
}

test "encode f32 big-endian" {
    const allocator = std.testing.allocator;
    const result = try encode(allocator, "1.0", .float32be);
    defer allocator.free(result);
    // f32 1.0 in BE: 3F 80 00 00
    try std.testing.expectEqualSlices(u8, &.{ 0x3F, 0x80, 0x00, 0x00 }, result);
}

// ── UUID tests ─────────────────────────────────────────────────────────

test "interpret uuid" {
    const allocator = std.testing.allocator;
    const bytes = [16]u8{ 0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00 };
    const result = try interpret(allocator, &bytes, .uuid);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", result);
}

test "uuid round-trip" {
    const allocator = std.testing.allocator;
    const original = [16]u8{ 0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00 };
    const text = try interpret(allocator, &original, .uuid);
    defer allocator.free(text);
    const encoded = try encode(allocator, text, .uuid);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &original, encoded);
}

// ── Datetime tests ─────────────────────────────────────────────────────

test "interpret datetime-s: Unix epoch" {
    const allocator = std.testing.allocator;
    // 0 seconds = 1970-01-01T00:00:00Z
    const result = try interpret(allocator, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, .datetime_s);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", result);
}

test "interpret datetime-s: known date" {
    const allocator = std.testing.allocator;
    // 1705314600 = 2024-01-15T10:30:00Z
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, 1705314600, .little);
    const result = try interpret(allocator, &bytes, .datetime_s);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("2024-01-15T10:30:00Z", result);
}

test "interpret datetime-ms" {
    const allocator = std.testing.allocator;
    // 1705314600500 ms = 2024-01-15T10:30:00.500Z
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, 1705314600500, .little);
    const result = try interpret(allocator, &bytes, .datetime_ms);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("2024-01-15T10:30:00.500Z", result);
}

test "interpret datetime-ns" {
    const allocator = std.testing.allocator;
    // 1705314600123456789 ns
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, 1705314600123456789, .little);
    const result = try interpret(allocator, &bytes, .datetime_ns);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("2024-01-15T10:30:00.123456789Z", result);
}

test "datetime-s round-trip" {
    const allocator = std.testing.allocator;
    var original: [8]u8 = undefined;
    std.mem.writeInt(i64, &original, 1705314600, .little);
    const text = try interpret(allocator, &original, .datetime_s);
    defer allocator.free(text);
    const encoded = try encode(allocator, text, .datetime_s);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &original, encoded);
}

// ── UTF-16 tests ───────────────────────────────────────────────────────

test "interpret utf16le: ASCII" {
    const allocator = std.testing.allocator;
    // "Hi" in UTF-16LE: 48 00 69 00
    const result = try interpret(allocator, &.{ 0x48, 0x00, 0x69, 0x00 }, .utf16);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hi", result);
}

test "interpret utf16be: ASCII" {
    const allocator = std.testing.allocator;
    // "Hi" in UTF-16BE: 00 48 00 69
    const result = try interpret(allocator, &.{ 0x00, 0x48, 0x00, 0x69 }, .utf16be);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hi", result);
}

test "utf16 endianness: same bytes, different results" {
    const allocator = std.testing.allocator;
    const bytes = [_]u8{ 0x48, 0x00, 0x69, 0x00 };

    const le = try interpret(allocator, &bytes, .utf16);
    defer allocator.free(le);
    try std.testing.expectEqualStrings("Hi", le); // LE: 'H', 'i'

    const be = try interpret(allocator, &bytes, .utf16be);
    defer allocator.free(be);
    // BE: 0x4800 = U+4800, 0x6900 = U+6900 (CJK ideographs)
    try std.testing.expect(!std.mem.eql(u8, "Hi", be));
}

test "utf16 round-trip with emoji" {
    const allocator = std.testing.allocator;
    const text = "Hello \xF0\x9F\x8C\x8D"; // "Hello 🌍" (U+1F30D, needs surrogate pair)
    const encoded = try encode(allocator, text, .utf16);
    defer allocator.free(encoded);
    const decoded = try interpret(allocator, encoded, .utf16);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(text, decoded);
}

// ── Hex tests ──────────────────────────────────────────────────────────

test "interpret hex" {
    const allocator = std.testing.allocator;
    const result = try interpret(allocator, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, .hex);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("deadbeef", result);
}

test "hex round-trip" {
    const allocator = std.testing.allocator;
    const original = [_]u8{ 0xCA, 0xFE, 0xBA, 0xBE };
    const text = try interpret(allocator, &original, .hex);
    defer allocator.free(text);
    const encoded = try encode(allocator, text, .hex);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &original, encoded);
}

// ── Base64 tests ───────────────────────────────────────────────────────

test "interpret base64" {
    const allocator = std.testing.allocator;
    const result = try interpret(allocator, "Hello", .base64);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("SGVsbG8=", result);
}

test "base64 round-trip" {
    const allocator = std.testing.allocator;
    const original = "Hello, World!";
    const text = try interpret(allocator, original, .base64);
    defer allocator.free(text);
    const decoded = try encode(allocator, text, .base64);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, original, decoded);
}

// ── BigInt tests ───────────────────────────────────────────────────────

test "interpret bigint: small value" {
    const allocator = std.testing.allocator;
    // 255 as single byte LE
    const result = try interpret(allocator, &.{0xFF}, .bigint);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("255", result);
}

test "interpret bigint: zero" {
    const allocator = std.testing.allocator;
    const result = try interpret(allocator, &.{0x00}, .bigint);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("0", result);
}

test "interpret bigint: 256 in LE" {
    const allocator = std.testing.allocator;
    // 256 = 0x0100 → LE: 00 01
    const result = try interpret(allocator, &.{ 0x00, 0x01 }, .bigint);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("256", result);
}

test "interpret bigint: 256 in BE" {
    const allocator = std.testing.allocator;
    // 256 = 0x0100 → BE: 01 00
    const result = try interpret(allocator, &.{ 0x01, 0x00 }, .bigint_be);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("256", result);
}

test "interpret bigint: large value (16 bytes)" {
    const allocator = std.testing.allocator;
    // 2^64 = 18446744073709551616 → LE: 00 00 00 00 00 00 00 00 01 ...
    var bytes = [_]u8{0} ** 16;
    bytes[8] = 1; // 2^64 in LE (byte 8 = 1, rest 0)
    const result = try interpret(allocator, &bytes, .bigint);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("18446744073709551616", result);
}

test "bigint endianness: same bytes, different values" {
    const allocator = std.testing.allocator;
    const bytes = [_]u8{ 0x01, 0x00 };

    const le = try interpret(allocator, &bytes, .bigint);
    defer allocator.free(le);
    try std.testing.expectEqualStrings("1", le); // LE: 0x0001 = 1

    const be = try interpret(allocator, &bytes, .bigint_be);
    defer allocator.free(be);
    try std.testing.expectEqualStrings("256", be); // BE: 0x0100 = 256
}

test "bigint round-trip" {
    const allocator = std.testing.allocator;
    const original = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }; // 2^64 - 1
    const text = try interpret(allocator, &original, .bigint);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("18446744073709551615", text);
    const encoded = try encode(allocator, text, .bigint);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &original, encoded);
}

test "bigint-be round-trip" {
    const allocator = std.testing.allocator;
    const original = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }; // 2^64 in BE
    const text = try interpret(allocator, &original, .bigint_be);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("18446744073709551616", text);
    const encoded = try encode(allocator, text, .bigint_be);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &original, encoded);
}

test "encode bigint: zero" {
    const allocator = std.testing.allocator;
    const result = try encode(allocator, "0", .bigint);
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, &.{0x00}, result);
}
