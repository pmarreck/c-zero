//! BG3 LSF Attribute Type Definitions
//!
//! The LSF format defines 34 attribute types that map raw binary values to
//! semantic C0 representations. Each type has a decode function (raw -> C0)
//! and an encode function (C0 -> raw).

const std = @import("std");
const core = @import("c0_core");
const Value = core.Value;
const Entry = core.Entry;

pub const AttributeType = enum(u8) {
    None = 0,
    Byte = 1,
    Short = 2,
    UShort = 3,
    Int = 4,
    UInt = 5,
    Float = 6,
    Double = 7,
    IVec2 = 8,
    IVec3 = 9,
    IVec4 = 10,
    Vec2 = 11,
    Vec3 = 12,
    Vec4 = 13,
    Mat2 = 14,
    Mat3 = 15,
    Mat3x4 = 16,
    Mat4x3 = 17,
    Mat4 = 18,
    Bool = 19,
    String = 20,
    Path = 21,
    FixedString = 22,
    LSString = 23,
    ULongLong = 24,
    ScratchBuffer = 25,
    Long = 26,
    Int8 = 27,
    TranslatedString = 28,
    WString = 29,
    LSWString = 30,
    UUID = 31,
    Int64 = 32,
    TranslatedFSString = 33,
    _,

    pub fn name(self: AttributeType) []const u8 {
        return switch (self) {
            .None => "none",
            .Byte => "byte",
            .Short => "short",
            .UShort => "ushort",
            .Int => "int",
            .UInt => "uint",
            .Float => "float",
            .Double => "double",
            .IVec2 => "ivec2",
            .IVec3 => "ivec3",
            .IVec4 => "ivec4",
            .Vec2 => "vec2",
            .Vec3 => "vec3",
            .Vec4 => "vec4",
            .Mat2 => "mat2",
            .Mat3 => "mat3",
            .Mat3x4 => "mat3x4",
            .Mat4x3 => "mat4x3",
            .Mat4 => "mat4",
            .Bool => "bool",
            .String => "string",
            .Path => "path",
            .FixedString => "fixed_string",
            .LSString => "ls_string",
            .ULongLong => "ulonglong",
            .ScratchBuffer => "scratch_buffer",
            .Long => "long",
            .Int8 => "int8",
            .TranslatedString => "translated_string",
            .WString => "wstring",
            .LSWString => "ls_wstring",
            .UUID => "uuid",
            .Int64 => "int64",
            .TranslatedFSString => "translated_fs_string",
            _ => "unknown",
        };
    }

    /// Look up an AttributeType from its string name
    pub fn fromName(name_str: []const u8) AttributeType {
        const mapping = .{
            .{ "none", AttributeType.None },
            .{ "byte", AttributeType.Byte },
            .{ "short", AttributeType.Short },
            .{ "ushort", AttributeType.UShort },
            .{ "int", AttributeType.Int },
            .{ "uint", AttributeType.UInt },
            .{ "float", AttributeType.Float },
            .{ "double", AttributeType.Double },
            .{ "ivec2", AttributeType.IVec2 },
            .{ "ivec3", AttributeType.IVec3 },
            .{ "ivec4", AttributeType.IVec4 },
            .{ "vec2", AttributeType.Vec2 },
            .{ "vec3", AttributeType.Vec3 },
            .{ "vec4", AttributeType.Vec4 },
            .{ "mat2", AttributeType.Mat2 },
            .{ "mat3", AttributeType.Mat3 },
            .{ "mat3x4", AttributeType.Mat3x4 },
            .{ "mat4x3", AttributeType.Mat4x3 },
            .{ "mat4", AttributeType.Mat4 },
            .{ "bool", AttributeType.Bool },
            .{ "string", AttributeType.String },
            .{ "path", AttributeType.Path },
            .{ "fixed_string", AttributeType.FixedString },
            .{ "ls_string", AttributeType.LSString },
            .{ "ulonglong", AttributeType.ULongLong },
            .{ "scratch_buffer", AttributeType.ScratchBuffer },
            .{ "long", AttributeType.Long },
            .{ "int8", AttributeType.Int8 },
            .{ "translated_string", AttributeType.TranslatedString },
            .{ "wstring", AttributeType.WString },
            .{ "ls_wstring", AttributeType.LSWString },
            .{ "uuid", AttributeType.UUID },
            .{ "int64", AttributeType.Int64 },
            .{ "translated_fs_string", AttributeType.TranslatedFSString },
        };

        inline for (mapping) |pair| {
            if (std.mem.eql(u8, name_str, pair[0])) return pair[1];
        }
        return .FixedString; // default fallback
    }

    /// Expected size of the attribute data (0 = variable length)
    pub fn fixedSize(self: AttributeType) usize {
        return switch (self) {
            .None => 0,
            .Byte, .Int8, .Bool => 1,
            .Short, .UShort => 2,
            .Int, .UInt, .Float => 4,
            .Double, .Long, .ULongLong, .Int64 => 8,
            .IVec2 => 8,
            .IVec3 => 12,
            .IVec4 => 16,
            .Vec2 => 8,
            .Vec3 => 12,
            .Vec4 => 16,
            .Mat2 => 16,
            .Mat3 => 36,
            .Mat3x4 => 48,
            .Mat4x3 => 48,
            .Mat4 => 64,
            .UUID => 16,
            // Variable-length types
            .String, .Path, .FixedString, .LSString => 0,
            .WString, .LSWString => 0,
            .ScratchBuffer => 0,
            .TranslatedString => 0,
            .TranslatedFSString => 0,
            _ => 0,
        };
    }
};

pub const TypeDecodeError = error{
    TruncatedData,
    InvalidType,
    OutOfMemory,
};

/// Decode a raw attribute value into a C0 string representation
pub fn decodeScalar(allocator: std.mem.Allocator, attr_type: AttributeType, data: []const u8) TypeDecodeError![]u8 {
    return switch (attr_type) {
        .None => allocator.dupe(u8, "") catch return TypeDecodeError.OutOfMemory,
        .Byte => formatInt(allocator, i16, @as(i16, @intCast(data[0]))),
        .Int8 => formatInt(allocator, i8, @as(i8, @bitCast(data[0]))),
        .Bool => allocator.dupe(u8, if (data[0] != 0) "true" else "false") catch return TypeDecodeError.OutOfMemory,
        .Short => blk: {
            if (data.len < 2) return TypeDecodeError.TruncatedData;
            break :blk formatInt(allocator, i16, std.mem.readInt(i16, data[0..2], .little));
        },
        .UShort => blk: {
            if (data.len < 2) return TypeDecodeError.TruncatedData;
            break :blk formatInt(allocator, u16, std.mem.readInt(u16, data[0..2], .little));
        },
        .Int => blk: {
            if (data.len < 4) return TypeDecodeError.TruncatedData;
            break :blk formatInt(allocator, i32, std.mem.readInt(i32, data[0..4], .little));
        },
        .UInt => blk: {
            if (data.len < 4) return TypeDecodeError.TruncatedData;
            break :blk formatInt(allocator, u32, std.mem.readInt(u32, data[0..4], .little));
        },
        .Float => blk: {
            if (data.len < 4) return TypeDecodeError.TruncatedData;
            const bits = std.mem.readInt(u32, data[0..4], .little);
            const f: f32 = @bitCast(bits);
            break :blk formatFloat(allocator, f);
        },
        .Double => blk: {
            if (data.len < 8) return TypeDecodeError.TruncatedData;
            const bits = std.mem.readInt(u64, data[0..8], .little);
            const f: f64 = @bitCast(bits);
            break :blk formatDouble(allocator, f);
        },
        .Long => blk: {
            if (data.len < 8) return TypeDecodeError.TruncatedData;
            break :blk formatInt(allocator, i64, std.mem.readInt(i64, data[0..8], .little));
        },
        .ULongLong, .Int64 => blk: {
            if (data.len < 8) return TypeDecodeError.TruncatedData;
            break :blk formatInt(allocator, u64, std.mem.readInt(u64, data[0..8], .little));
        },
        .UUID => blk: {
            if (data.len < 16) return TypeDecodeError.TruncatedData;
            break :blk formatUuid(allocator, data[0..16]);
        },
        // String types: strip trailing null terminator if present
        .String, .Path, .FixedString, .LSString, .WString, .LSWString => {
            const str_data = if (data.len > 0 and data[data.len - 1] == 0)
                data[0 .. data.len - 1]
            else
                data;
            return allocator.dupe(u8, str_data) catch return TypeDecodeError.OutOfMemory;
        },
        // ScratchBuffer: opaque binary, return as-is (will be pb-encoded by C0)
        .ScratchBuffer => allocator.dupe(u8, data) catch return TypeDecodeError.OutOfMemory,
        // Vectors and matrices are handled separately
        else => allocator.dupe(u8, data) catch return TypeDecodeError.OutOfMemory,
    };
}

/// Decode a TranslatedString attribute into a C0 object Value
/// Format: {_handle: "hash...", _version: N}
pub fn decodeTranslatedString(allocator: std.mem.Allocator, data: []const u8) TypeDecodeError!Value {
    // TranslatedString: version(u16) + handle_length(u32) + handle(bytes)
    if (data.len < 6) return TypeDecodeError.TruncatedData;

    const version = std.mem.readInt(u16, data[0..2], .little);
    const handle_len = std.mem.readInt(u32, data[2..6], .little);

    if (data.len < 6 + handle_len) return TypeDecodeError.TruncatedData;
    const handle = data[6..][0..handle_len];

    const version_str = formatInt(allocator, u16, version) catch return TypeDecodeError.OutOfMemory;

    const entries = allocator.alloc(Entry, 2) catch return TypeDecodeError.OutOfMemory;
    entries[0] = .{ .key = "_handle", .value = .{ .string = handle } };
    entries[1] = .{ .key = "_version", .value = .{ .string = version_str } };
    return Value{ .object = entries };
}

/// Format an integer as a decimal string
fn formatInt(allocator: std.mem.Allocator, comptime T: type, value: T) TypeDecodeError![]u8 {
    var buf: [32]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return TypeDecodeError.OutOfMemory;
    return allocator.dupe(u8, slice) catch return TypeDecodeError.OutOfMemory;
}

/// Format a float as a string
fn formatFloat(allocator: std.mem.Allocator, value: f32) TypeDecodeError![]u8 {
    var buf: [32]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return TypeDecodeError.OutOfMemory;
    return allocator.dupe(u8, slice) catch return TypeDecodeError.OutOfMemory;
}

/// Format a double as a string
fn formatDouble(allocator: std.mem.Allocator, value: f64) TypeDecodeError![]u8 {
    var buf: [64]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return TypeDecodeError.OutOfMemory;
    return allocator.dupe(u8, slice) catch return TypeDecodeError.OutOfMemory;
}

/// Format a UUID as "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
fn formatUuid(allocator: std.mem.Allocator, data: *const [16]u8) TypeDecodeError![]u8 {
    var buf: [36]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        data[3],  data[2],  data[1],  data[0], // time_low (LE)
        data[5],  data[4], // time_mid (LE)
        data[7],  data[6], // time_hi (LE)
        data[8],  data[9], // clock_seq
        data[10], data[11], data[12], data[13], data[14], data[15],
    }) catch return TypeDecodeError.OutOfMemory;
    return allocator.dupe(u8, slice) catch return TypeDecodeError.OutOfMemory;
}

/// Decode a vector (IVec2/3/4, Vec2/3/4) into a C0 array of values
pub fn decodeVector(allocator: std.mem.Allocator, attr_type: AttributeType, data: []const u8) TypeDecodeError!Value {
    return switch (attr_type) {
        .IVec2 => decodeIntVector(allocator, data, 2),
        .IVec3 => decodeIntVector(allocator, data, 3),
        .IVec4 => decodeIntVector(allocator, data, 4),
        .Vec2 => decodeFloatVector(allocator, data, 2),
        .Vec3 => decodeFloatVector(allocator, data, 3),
        .Vec4 => decodeFloatVector(allocator, data, 4),
        else => TypeDecodeError.InvalidType,
    };
}

fn decodeIntVector(allocator: std.mem.Allocator, data: []const u8, count: usize) TypeDecodeError!Value {
    if (data.len < count * 4) return TypeDecodeError.TruncatedData;

    const values = allocator.alloc(Value, count) catch return TypeDecodeError.OutOfMemory;
    for (0..count) |i| {
        const v = std.mem.readInt(i32, data[i * 4 ..][0..4], .little);
        const str = formatInt(allocator, i32, v) catch return TypeDecodeError.OutOfMemory;
        values[i] = .{ .string = str };
    }
    return Value{ .array = values };
}

fn decodeFloatVector(allocator: std.mem.Allocator, data: []const u8, count: usize) TypeDecodeError!Value {
    if (data.len < count * 4) return TypeDecodeError.TruncatedData;

    const values = allocator.alloc(Value, count) catch return TypeDecodeError.OutOfMemory;
    for (0..count) |i| {
        const bits = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
        const f: f32 = @bitCast(bits);
        const str = formatFloat(allocator, f) catch return TypeDecodeError.OutOfMemory;
        values[i] = .{ .string = str };
    }
    return Value{ .array = values };
}

// ============================================================================
// Encode helpers (C0 string -> raw bytes)
// ============================================================================

pub const TypeEncodeError = error{
    InvalidFormat,
    OutOfMemory,
    Overflow,
};

/// Encode a C0 string representation back to raw attribute bytes
pub fn encodeScalar(allocator: std.mem.Allocator, attr_type: AttributeType, str_value: []const u8) TypeEncodeError![]u8 {
    return switch (attr_type) {
        .None => allocator.alloc(u8, 0) catch return TypeEncodeError.OutOfMemory,
        .Byte => blk: {
            const v = std.fmt.parseInt(u8, str_value, 10) catch return TypeEncodeError.InvalidFormat;
            const buf = allocator.alloc(u8, 1) catch return TypeEncodeError.OutOfMemory;
            buf[0] = v;
            break :blk buf;
        },
        .Int8 => blk: {
            const v = std.fmt.parseInt(i8, str_value, 10) catch return TypeEncodeError.InvalidFormat;
            const buf = allocator.alloc(u8, 1) catch return TypeEncodeError.OutOfMemory;
            buf[0] = @bitCast(v);
            break :blk buf;
        },
        .Bool => blk: {
            const buf = allocator.alloc(u8, 1) catch return TypeEncodeError.OutOfMemory;
            buf[0] = if (std.mem.eql(u8, str_value, "true")) 1 else 0;
            break :blk buf;
        },
        .Short => blk: {
            const v = std.fmt.parseInt(i16, str_value, 10) catch return TypeEncodeError.InvalidFormat;
            const buf = allocator.alloc(u8, 2) catch return TypeEncodeError.OutOfMemory;
            std.mem.writeInt(i16, buf[0..2], v, .little);
            break :blk buf;
        },
        .UShort => blk: {
            const v = std.fmt.parseInt(u16, str_value, 10) catch return TypeEncodeError.InvalidFormat;
            const buf = allocator.alloc(u8, 2) catch return TypeEncodeError.OutOfMemory;
            std.mem.writeInt(u16, buf[0..2], v, .little);
            break :blk buf;
        },
        .Int => blk: {
            const v = std.fmt.parseInt(i32, str_value, 10) catch return TypeEncodeError.InvalidFormat;
            const buf = allocator.alloc(u8, 4) catch return TypeEncodeError.OutOfMemory;
            std.mem.writeInt(i32, buf[0..4], v, .little);
            break :blk buf;
        },
        .UInt => blk: {
            const v = std.fmt.parseInt(u32, str_value, 10) catch return TypeEncodeError.InvalidFormat;
            const buf = allocator.alloc(u8, 4) catch return TypeEncodeError.OutOfMemory;
            std.mem.writeInt(u32, buf[0..4], v, .little);
            break :blk buf;
        },
        .Float => blk: {
            const f = std.fmt.parseFloat(f32, str_value) catch return TypeEncodeError.InvalidFormat;
            const bits: u32 = @bitCast(f);
            const buf = allocator.alloc(u8, 4) catch return TypeEncodeError.OutOfMemory;
            std.mem.writeInt(u32, buf[0..4], bits, .little);
            break :blk buf;
        },
        .Double => blk: {
            const f = std.fmt.parseFloat(f64, str_value) catch return TypeEncodeError.InvalidFormat;
            const bits: u64 = @bitCast(f);
            const buf = allocator.alloc(u8, 8) catch return TypeEncodeError.OutOfMemory;
            std.mem.writeInt(u64, buf[0..8], bits, .little);
            break :blk buf;
        },
        .Long => blk: {
            const v = std.fmt.parseInt(i64, str_value, 10) catch return TypeEncodeError.InvalidFormat;
            const buf = allocator.alloc(u8, 8) catch return TypeEncodeError.OutOfMemory;
            std.mem.writeInt(i64, buf[0..8], v, .little);
            break :blk buf;
        },
        .ULongLong, .Int64 => blk: {
            const v = std.fmt.parseInt(u64, str_value, 10) catch return TypeEncodeError.InvalidFormat;
            const buf = allocator.alloc(u8, 8) catch return TypeEncodeError.OutOfMemory;
            std.mem.writeInt(u64, buf[0..8], v, .little);
            break :blk buf;
        },
        .UUID => encodeUuid(allocator, str_value),
        // String types: value is already the string
        .String, .Path, .FixedString, .LSString, .WString, .LSWString => {
            return allocator.dupe(u8, str_value) catch return TypeEncodeError.OutOfMemory;
        },
        .ScratchBuffer => allocator.dupe(u8, str_value) catch return TypeEncodeError.OutOfMemory,
        else => allocator.dupe(u8, str_value) catch return TypeEncodeError.OutOfMemory,
    };
}

fn encodeUuid(allocator: std.mem.Allocator, str: []const u8) TypeEncodeError![]u8 {
    // Parse "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -> 16 bytes (mixed endian)
    if (str.len != 36) return TypeEncodeError.InvalidFormat;

    var buf = allocator.alloc(u8, 16) catch return TypeEncodeError.OutOfMemory;
    errdefer allocator.free(buf);

    // Parse hex pairs from the UUID string, accounting for hyphens
    // Format: 8-4-4-4-12 hex chars
    const hex_positions = [_]struct { src: usize, dst: usize }{
        // time_low: LE bytes
        .{ .src = 6, .dst = 0 },
        .{ .src = 4, .dst = 1 },
        .{ .src = 2, .dst = 2 },
        .{ .src = 0, .dst = 3 },
        // time_mid: LE
        .{ .src = 11, .dst = 4 },
        .{ .src = 9, .dst = 5 },
        // time_hi: LE
        .{ .src = 16, .dst = 6 },
        .{ .src = 14, .dst = 7 },
        // clock_seq + node: big-endian
        .{ .src = 19, .dst = 8 },
        .{ .src = 21, .dst = 9 },
        .{ .src = 24, .dst = 10 },
        .{ .src = 26, .dst = 11 },
        .{ .src = 28, .dst = 12 },
        .{ .src = 30, .dst = 13 },
        .{ .src = 32, .dst = 14 },
        .{ .src = 34, .dst = 15 },
    };

    for (hex_positions) |pos| {
        buf[pos.dst] = parseHexByte(str[pos.src..][0..2]) catch return TypeEncodeError.InvalidFormat;
    }

    return buf;
}

fn parseHexByte(hex: *const [2]u8) !u8 {
    return std.fmt.parseInt(u8, hex, 16) catch return error.InvalidFormat;
}

/// Encode a TranslatedString from C0 object entries back to raw bytes
pub fn encodeTranslatedString(allocator: std.mem.Allocator, entries: []const Entry) TypeEncodeError![]u8 {
    var handle: []const u8 = "";
    var version: u16 = 0;

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, "_handle")) {
            handle = switch (entry.value) {
                .string => |s| s,
                else => "",
            };
        } else if (std.mem.eql(u8, entry.key, "_version")) {
            const ver_str = switch (entry.value) {
                .string => |s| s,
                else => "0",
            };
            version = std.fmt.parseInt(u16, ver_str, 10) catch 0;
        }
    }

    const total = 2 + 4 + handle.len;
    const buf = allocator.alloc(u8, total) catch return TypeEncodeError.OutOfMemory;
    std.mem.writeInt(u16, buf[0..2], version, .little);
    std.mem.writeInt(u32, buf[2..6], @intCast(handle.len), .little);
    @memcpy(buf[6..], handle);
    return buf;
}

/// Encode a vector from C0 array values back to raw bytes
pub fn encodeVector(allocator: std.mem.Allocator, attr_type: AttributeType, values: []const Value) TypeEncodeError![]u8 {
    const is_float = switch (attr_type) {
        .Vec2, .Vec3, .Vec4 => true,
        else => false,
    };

    const buf = allocator.alloc(u8, values.len * 4) catch return TypeEncodeError.OutOfMemory;
    for (values, 0..) |v, i| {
        const s = switch (v) {
            .string => |str| str,
            else => "0",
        };
        if (is_float) {
            const f = std.fmt.parseFloat(f32, s) catch 0.0;
            const bits: u32 = @bitCast(f);
            std.mem.writeInt(u32, buf[i * 4 ..][0..4], bits, .little);
        } else {
            const n = std.fmt.parseInt(i32, s, 10) catch 0;
            std.mem.writeInt(i32, buf[i * 4 ..][0..4], n, .little);
        }
    }
    return buf;
}

// ============================================================================
// Tests
// ============================================================================

test "decode/encode byte round-trip" {
    const allocator = std.testing.allocator;
    const data = [_]u8{42};
    const decoded = try decodeScalar(allocator, .Byte, &data);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("42", decoded);

    const encoded = try encodeScalar(allocator, .Byte, decoded);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &data, encoded);
}

test "decode/encode int round-trip" {
    const allocator = std.testing.allocator;
    var data: [4]u8 = undefined;
    std.mem.writeInt(i32, &data, -12345, .little);

    const decoded = try decodeScalar(allocator, .Int, &data);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("-12345", decoded);

    const encoded = try encodeScalar(allocator, .Int, decoded);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &data, encoded);
}

test "decode/encode float round-trip" {
    const allocator = std.testing.allocator;
    const f: f32 = 3.14;
    const bits: u32 = @bitCast(f);
    var data: [4]u8 = undefined;
    std.mem.writeInt(u32, &data, bits, .little);

    const decoded = try decodeScalar(allocator, .Float, &data);
    defer allocator.free(decoded);

    const encoded = try encodeScalar(allocator, .Float, decoded);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &data, encoded);
}

test "decode/encode bool round-trip" {
    const allocator = std.testing.allocator;
    const data_true = [_]u8{1};
    const data_false = [_]u8{0};

    const decoded_true = try decodeScalar(allocator, .Bool, &data_true);
    defer allocator.free(decoded_true);
    try std.testing.expectEqualStrings("true", decoded_true);

    const decoded_false = try decodeScalar(allocator, .Bool, &data_false);
    defer allocator.free(decoded_false);
    try std.testing.expectEqualStrings("false", decoded_false);

    const encoded_true = try encodeScalar(allocator, .Bool, "true");
    defer allocator.free(encoded_true);
    try std.testing.expectEqualSlices(u8, &data_true, encoded_true);

    const encoded_false = try encodeScalar(allocator, .Bool, "false");
    defer allocator.free(encoded_false);
    try std.testing.expectEqualSlices(u8, &data_false, encoded_false);
}

test "decode UUID" {
    const allocator = std.testing.allocator;

    // Example UUID bytes (mixed endian as BG3 stores them)
    const uuid_bytes = [16]u8{
        0x00, 0x84, 0x0e, 0x55, // time_low LE -> 550e8400
        0x9b, 0xe2, // time_mid LE -> e29b
        0xd4, 0x41, // time_hi LE -> 41d4
        0xa7, 0x16, // clock_seq BE
        0x44, 0x66, 0x55, 0x44, 0x00, 0x00, // node BE
    };

    const decoded = try decodeScalar(allocator, .UUID, &uuid_bytes);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", decoded);

    const encoded = try encodeScalar(allocator, .UUID, decoded);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &uuid_bytes, encoded);
}

test "decode IVec3" {
    const allocator = std.testing.allocator;
    var data: [12]u8 = undefined;
    std.mem.writeInt(i32, data[0..4], 100, .little);
    std.mem.writeInt(i32, data[4..8], -200, .little);
    std.mem.writeInt(i32, data[8..12], 300, .little);

    const value = try decodeVector(allocator, .IVec3, &data);
    try std.testing.expectEqual(@as(usize, 3), value.array.len);
    try std.testing.expectEqualStrings("100", value.array[0].string);
    try std.testing.expectEqualStrings("-200", value.array[1].string);
    try std.testing.expectEqualStrings("300", value.array[2].string);

    // Free
    for (value.array) |v| allocator.free(v.string);
    allocator.free(value.array);
}

test "attribute type names" {
    try std.testing.expectEqualStrings("int", AttributeType.Int.name());
    try std.testing.expectEqualStrings("float", AttributeType.Float.name());
    try std.testing.expectEqualStrings("uuid", AttributeType.UUID.name());
    try std.testing.expectEqualStrings("translated_string", AttributeType.TranslatedString.name());
    try std.testing.expectEqualStrings("fixed_string", AttributeType.FixedString.name());
}
