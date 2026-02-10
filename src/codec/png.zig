//! PNG Codec - Lossless destructuring of PNG files into C0 text
//!
//! Faithful mode: preserves CRC bytes for bit-perfect round-trip
//! Editable mode: omits CRC, recalculates CRC-32 on collapse
//!
//! C0 output structure:
//!   {format:png, signature:<8B pb>, chunks:[{type:IHDR, data:<13B pb>, crc:<4B pb>}, ...]}

const std = @import("std");
const core = @import("c0_core");
const codec = @import("mod.zig");

const Value = core.Value;
const Entry = core.Entry;
const CodecInfo = codec.CodecInfo;
const CodecOptions = codec.CodecOptions;
const CodecError = codec.CodecError;
const MagicPattern = codec.MagicPattern;

const png_signature = "\x89PNG\r\n\x1a\n";

pub const PngCodec = struct {
    pub fn getInfo(_: *PngCodec) CodecInfo {
        return .{
            .name = "png",
            .description = "PNG image format (lossless chunk destructuring)",
            .extensions = &.{".png"},
            .magic = &.{.{ .offset = 0, .bytes = png_signature }},
            .format_names = &.{"png"},
            .supports_faithful = true,
            .supports_editable = true,
        };
    }

    pub fn expandImpl(_: *PngCodec, allocator: std.mem.Allocator, data: []const u8, options: CodecOptions) CodecError!Value {
        return expandPng(allocator, data, options);
    }

    pub fn collapseImpl(_: *PngCodec, allocator: std.mem.Allocator, value: Value, options: CodecOptions) CodecError![]u8 {
        return collapsePng(allocator, value, options);
    }
};

/// Parse PNG data into a C0 Value
fn expandPng(allocator: std.mem.Allocator, data: []const u8, options: CodecOptions) CodecError!Value {
    // Validate signature
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], png_signature)) {
        return CodecError.InvalidMagic;
    }

    // Parse chunks
    var chunk_list: std.ArrayListUnmanaged(Value) = .{};
    defer chunk_list.deinit(allocator);

    var pos: usize = 8;
    while (pos + 12 <= data.len) {
        const data_len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const chunk_type = data[pos + 4 .. pos + 8];
        const data_start = pos + 8;
        const data_end = data_start + data_len;
        const crc_end = data_end + 4;

        if (crc_end > data.len) return CodecError.TruncatedInput;

        const chunk_data = data[data_start..data_end];
        const chunk_crc = data[data_end..crc_end];

        // Build chunk object entries
        if (options.faithful) {
            // Faithful mode: include CRC
            const entries = allocator.alloc(Entry, 3) catch return CodecError.OutOfMemory;
            entries[0] = .{ .key = "type", .value = .{ .string = chunk_type } };
            entries[1] = .{ .key = "data", .value = .{ .string = chunk_data } };
            entries[2] = .{ .key = "crc", .value = .{ .string = chunk_crc } };
            chunk_list.append(allocator, .{ .object = entries }) catch return CodecError.OutOfMemory;
        } else {
            // Editable mode: omit CRC (will be recalculated on collapse)
            const entries = allocator.alloc(Entry, 2) catch return CodecError.OutOfMemory;
            entries[0] = .{ .key = "type", .value = .{ .string = chunk_type } };
            entries[1] = .{ .key = "data", .value = .{ .string = chunk_data } };
            chunk_list.append(allocator, .{ .object = entries }) catch return CodecError.OutOfMemory;
        }

        pos = crc_end;
        if (std.mem.eql(u8, chunk_type, "IEND")) break;
    }

    // Build top-level object: {format:png, signature:<8B>, chunks:[...]}
    const chunks_owned = chunk_list.toOwnedSlice(allocator) catch return CodecError.OutOfMemory;

    const top_entries = allocator.alloc(Entry, 3) catch return CodecError.OutOfMemory;
    top_entries[0] = .{ .key = "format", .value = .{ .string = "png" } };
    top_entries[1] = .{ .key = "signature", .value = .{ .string = data[0..8] } };
    top_entries[2] = .{ .key = "chunks", .value = .{ .array = chunks_owned } };

    return Value{ .object = top_entries };
}

/// Reconstruct PNG binary from a C0 Value
fn collapsePng(allocator: std.mem.Allocator, value: Value, options: CodecOptions) CodecError![]u8 {
    const entries = switch (value) {
        .object => |obj| obj,
        else => return CodecError.InvalidFormat,
    };

    // Find signature and chunks fields
    var signature: ?[]const u8 = null;
    var chunks: ?[]const Value = null;

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, "signature")) {
            signature = switch (entry.value) {
                .string => |s| s,
                else => return CodecError.InvalidFormat,
            };
        } else if (std.mem.eql(u8, entry.key, "chunks")) {
            chunks = switch (entry.value) {
                .array => |a| a,
                else => return CodecError.InvalidFormat,
            };
        }
    }

    const sig = signature orelse return CodecError.InvalidFormat;
    const chunk_array = chunks orelse return CodecError.InvalidFormat;

    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    // Write signature
    result.appendSlice(allocator, sig) catch return CodecError.OutOfMemory;

    // Write chunks
    for (chunk_array) |chunk_val| {
        const chunk_entries = switch (chunk_val) {
            .object => |obj| obj,
            else => return CodecError.InvalidFormat,
        };

        var chunk_type: ?[]const u8 = null;
        var chunk_data: ?[]const u8 = null;
        var chunk_crc: ?[]const u8 = null;

        for (chunk_entries) |entry| {
            if (std.mem.eql(u8, entry.key, "type")) {
                chunk_type = switch (entry.value) {
                    .string => |s| s,
                    else => return CodecError.InvalidFormat,
                };
            } else if (std.mem.eql(u8, entry.key, "data")) {
                chunk_data = switch (entry.value) {
                    .string => |s| s,
                    else => return CodecError.InvalidFormat,
                };
            } else if (std.mem.eql(u8, entry.key, "crc")) {
                chunk_crc = switch (entry.value) {
                    .string => |s| s,
                    else => return CodecError.InvalidFormat,
                };
            }
        }

        const ct = chunk_type orelse return CodecError.InvalidFormat;
        const cd = chunk_data orelse return CodecError.InvalidFormat;

        // Write length (4 bytes BE)
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(cd.len), .big);
        result.appendSlice(allocator, &len_buf) catch return CodecError.OutOfMemory;

        // Write type
        result.appendSlice(allocator, ct) catch return CodecError.OutOfMemory;

        // Write data
        result.appendSlice(allocator, cd) catch return CodecError.OutOfMemory;

        // Write CRC
        if (options.faithful) {
            // Faithful mode: use stored CRC
            const crc = chunk_crc orelse return CodecError.InvalidFormat;
            result.appendSlice(allocator, crc) catch return CodecError.OutOfMemory;
        } else {
            // Editable mode: recalculate CRC-32 over type+data
            const crc_input = allocator.alloc(u8, ct.len + cd.len) catch return CodecError.OutOfMemory;
            defer allocator.free(crc_input);
            @memcpy(crc_input[0..ct.len], ct);
            @memcpy(crc_input[ct.len..], cd);

            const crc32 = std.hash.crc.Crc32IsoHdlc.hash(crc_input);
            var crc_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &crc_buf, crc32, .big);
            result.appendSlice(allocator, &crc_buf) catch return CodecError.OutOfMemory;
        }
    }

    return result.toOwnedSlice(allocator) catch return CodecError.OutOfMemory;
}

// ============================================================================
// Tests
// ============================================================================

/// Build a minimal synthetic PNG for testing
fn buildSyntheticPng(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);

    // Signature
    try buf.appendSlice(allocator, png_signature);

    // IHDR chunk: 13 bytes
    const ihdr_data = [13]u8{
        0, 0, 0, 1, // width=1
        0, 0, 0, 1, // height=1
        8, // bit depth
        2, // color type (RGB)
        0, // compression
        0, // filter
        0, // interlace
    };

    // CRC for IHDR (over "IHDR" + data)
    var ihdr_crc_input: [4 + 13]u8 = undefined;
    @memcpy(ihdr_crc_input[0..4], "IHDR");
    @memcpy(ihdr_crc_input[4..], &ihdr_data);
    const ihdr_crc = std.hash.crc.Crc32IsoHdlc.hash(&ihdr_crc_input);

    // Write IHDR
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, 13, .big);
    try buf.appendSlice(allocator, &len_buf);
    try buf.appendSlice(allocator, "IHDR");
    try buf.appendSlice(allocator, &ihdr_data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, ihdr_crc, .big);
    try buf.appendSlice(allocator, &crc_buf);

    // IEND chunk: 0 bytes
    std.mem.writeInt(u32, &len_buf, 0, .big);
    try buf.appendSlice(allocator, &len_buf);
    try buf.appendSlice(allocator, "IEND");
    const iend_crc = std.hash.crc.Crc32IsoHdlc.hash("IEND");
    std.mem.writeInt(u32, &crc_buf, iend_crc, .big);
    try buf.appendSlice(allocator, &crc_buf);

    return buf.toOwnedSlice(allocator);
}

test "PNG codec faithful round-trip" {
    const allocator = std.testing.allocator;

    const original = try buildSyntheticPng(allocator);
    defer allocator.free(original);

    var png_codec = PngCodec{};
    const c = codec.Codec.init(&png_codec);

    // Expand
    const value = try c.expand(allocator, original, .{ .faithful = true });

    // Verify format field
    try std.testing.expectEqualStrings("format", value.object[0].key);
    try std.testing.expectEqualStrings("png", value.object[0].value.string);

    // Verify chunks
    const chunks = value.object[2].value.array;
    try std.testing.expectEqual(@as(usize, 2), chunks.len);

    // Collapse
    const collapsed = try c.collapse(allocator, value, .{ .faithful = true });
    defer allocator.free(collapsed);

    // Free the expanded value (allocated entries)
    for (value.object[2].value.array) |chunk_val| {
        allocator.free(chunk_val.object);
    }
    allocator.free(value.object[2].value.array);
    allocator.free(value.object);

    // Byte-for-byte match
    try std.testing.expectEqualSlices(u8, original, collapsed);
}

test "PNG codec editable round-trip" {
    const allocator = std.testing.allocator;

    const original = try buildSyntheticPng(allocator);
    defer allocator.free(original);

    var png_codec = PngCodec{};
    const c = codec.Codec.init(&png_codec);

    // Expand in editable mode (no CRC fields)
    const value = try c.expand(allocator, original, .{ .faithful = false });

    // Verify no CRC in chunk entries
    const chunks = value.object[2].value.array;
    for (chunks) |chunk_val| {
        for (chunk_val.object) |entry| {
            try std.testing.expect(!std.mem.eql(u8, entry.key, "crc"));
        }
    }

    // Collapse in editable mode (CRC recalculated)
    const collapsed = try c.collapse(allocator, value, .{ .faithful = false });
    defer allocator.free(collapsed);

    // Free the expanded value
    for (value.object[2].value.array) |chunk_val| {
        allocator.free(chunk_val.object);
    }
    allocator.free(value.object[2].value.array);
    allocator.free(value.object);

    // Should still produce a valid PNG that matches original
    // (since we used correct CRCs in the synthetic PNG)
    try std.testing.expectEqualSlices(u8, original, collapsed);
}

test "PNG codec full C0 encode/decode round-trip" {
    const allocator = std.testing.allocator;

    const original = try buildSyntheticPng(allocator);
    defer allocator.free(original);

    var png_codec = PngCodec{};
    const c = codec.Codec.init(&png_codec);

    // Expand to Value
    const value = try c.expand(allocator, original, .{ .faithful = true });

    // Encode Value to C0 text
    const c0_bytes = core.encode(allocator, value) catch return CodecError.CoreEncodeError;
    defer allocator.free(c0_bytes);

    // Decode C0 text back to Value
    const decoded_value = core.decode(allocator, c0_bytes) catch return CodecError.CoreDecodeError;
    defer core.deinit(allocator, decoded_value);

    // Collapse back to PNG
    const collapsed = try c.collapse(allocator, decoded_value, .{ .faithful = true });
    defer allocator.free(collapsed);

    // Free expanded value
    for (value.object[2].value.array) |chunk_val| {
        allocator.free(chunk_val.object);
    }
    allocator.free(value.object[2].value.array);
    allocator.free(value.object);

    // Byte-for-byte match through the full pipeline
    try std.testing.expectEqualSlices(u8, original, collapsed);
}

test "PNG codec rejects non-PNG data" {
    var png_codec = PngCodec{};
    const c = codec.Codec.init(&png_codec);

    const result = c.expand(std.testing.allocator, "not a png file", .{});
    try std.testing.expectError(CodecError.InvalidMagic, result);
}

test "PNG codec info" {
    var png_codec = PngCodec{};
    const c = codec.Codec.init(&png_codec);
    const info = c.info();

    try std.testing.expectEqualStrings("png", info.name);
    try std.testing.expect(info.supports_faithful);
    try std.testing.expect(info.supports_editable);
    try std.testing.expectEqual(@as(usize, 1), info.extensions.len);
    try std.testing.expectEqualStrings(".png", info.extensions[0]);
}
