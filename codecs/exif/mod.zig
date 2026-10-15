//! EXIF Codec Module
//!
//! Provides JPEG and TIFF codecs with full EXIF metadata parsing.
//! Both codecs share the core IFD parser in ifd.zig.

const std = @import("std");
const core = @import("c0_core");
const codec = @import("../mod.zig");

pub const tags = @import("tags.zig");
pub const ifd = @import("ifd.zig");
pub const tiff_format = @import("tiff_format.zig");
pub const jpeg = @import("jpeg.zig");

const Value = core.Value;
const CodecInfo = codec.CodecInfo;
const CodecOptions = codec.CodecOptions;
const CodecError = codec.CodecError;
const MagicPattern = codec.MagicPattern;

// ============================================================================
// JPEG Codec
// ============================================================================

pub const JpegCodec = struct {
    pub fn getInfo(_: *JpegCodec) CodecInfo {
        return .{
            .name = "jpeg",
            .description = "JPEG image format with EXIF metadata parsing",
            .extensions = &.{ ".jpg", ".jpeg", ".jpe", ".jfif" },
            .magic = &.{.{ .offset = 0, .bytes = "\xFF\xD8" }},
            .format_names = &.{"jpeg"},
            .supports_faithful = true,
            .supports_editable = true,
        };
    }

    pub fn expandImpl(_: *JpegCodec, allocator: std.mem.Allocator, data: []const u8, options: CodecOptions) CodecError!Value {
        return jpeg.expandJpeg(allocator, data, options);
    }

    pub fn collapseImpl(_: *JpegCodec, allocator: std.mem.Allocator, value: Value, options: CodecOptions) CodecError![]u8 {
        return jpeg.collapseJpeg(allocator, value, options);
    }
};

// ============================================================================
// TIFF Codec
// ============================================================================

pub const TiffCodec = struct {
    pub fn getInfo(_: *TiffCodec) CodecInfo {
        return .{
            .name = "tiff",
            .description = "TIFF image format with IFD metadata parsing",
            .extensions = &.{ ".tif", ".tiff" },
            .magic = &.{
                .{ .offset = 0, .bytes = "II\x2a\x00" }, // Little-endian TIFF
                .{ .offset = 0, .bytes = "MM\x00\x2a" }, // Big-endian TIFF
            },
            .format_names = &.{"tiff"},
            .supports_faithful = true,
            .supports_editable = true,
        };
    }

    pub fn expandImpl(_: *TiffCodec, allocator: std.mem.Allocator, data: []const u8, options: CodecOptions) CodecError!Value {
        return tiff_format.expandTiff(allocator, data, options);
    }

    pub fn collapseImpl(_: *TiffCodec, allocator: std.mem.Allocator, value: Value, options: CodecOptions) CodecError![]u8 {
        return tiff_format.collapseTiff(allocator, value, options);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "JPEG codec info" {
    var jpeg_codec = JpegCodec{};
    const c = codec.Codec.init(&jpeg_codec);
    const info = c.info();

    try std.testing.expectEqualStrings("jpeg", info.name);
    try std.testing.expect(info.supports_faithful);
    try std.testing.expect(info.supports_editable);
    try std.testing.expectEqual(@as(usize, 4), info.extensions.len);
    try std.testing.expectEqualStrings(".jpg", info.extensions[0]);
}

test "TIFF codec info" {
    var tiff_codec = TiffCodec{};
    const c = codec.Codec.init(&tiff_codec);
    const info = c.info();

    try std.testing.expectEqualStrings("tiff", info.name);
    try std.testing.expect(info.supports_faithful);
    try std.testing.expect(info.supports_editable);
    try std.testing.expectEqual(@as(usize, 2), info.extensions.len);
    try std.testing.expectEqualStrings(".tif", info.extensions[0]);
}

test "JPEG codec via interface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var jpeg_codec = JpegCodec{};
    const c = codec.Codec.init(&jpeg_codec);

    const jpeg_data = try jpeg.buildTestJpeg(allocator);
    const value = try c.expand(allocator, jpeg_data, .{ .faithful = true });
    const collapsed = try c.collapse(allocator, value, .{ .faithful = true });

    try std.testing.expectEqualSlices(u8, jpeg_data, collapsed);
}

test "TIFF codec via interface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tiff_codec = TiffCodec{};
    const c = codec.Codec.init(&tiff_codec);

    const tiff_data = try ifd.buildTestTiff(allocator);
    const value = try c.expand(allocator, tiff_data, .{ .faithful = true });
    const collapsed = try c.collapse(allocator, value, .{ .faithful = true });

    try std.testing.expectEqualSlices(u8, tiff_data, collapsed);
}

test {
    _ = tags;
    _ = ifd;
    _ = tiff_format;
    _ = jpeg;
}
