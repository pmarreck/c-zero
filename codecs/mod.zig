//! C0 Codec System - shared codec interface and metadata helpers
//!
//! Each codec ships as a separate c0-codec-<name> plugin executable (protocol c0-codec/1,
//! docs/plan_context/codec_plugins.md); codecs/plugin.zig adapts a codec type to the plugin ABI.
//!
//! Codecs transform binary file formats to/from C0 structured text.
//! "expand" converts native binary to C0 (human-readable, editable).
//! "collapse" converts C0 back to native binary (lossless round-trip).

const std = @import("std");
const core = @import("c0_core");
const Value = core.Value;

pub const png = @import("png.zig");
pub const bg3 = @import("bg3/mod.zig");
pub const json = @import("json.zig");
pub const exif = @import("exif/mod.zig");
pub const pdf = @import("pdf/mod.zig");

/// Error type for codec operations
pub const CodecError = error{
    InvalidMagic,
    TruncatedInput,
    InvalidChunk,
    InvalidFormat,
    UnsupportedVersion,
    CompressionError,
    DecompressionError,
    MissingFormatField,
    UnknownCodec,
    CoreEncodeError,
    CoreDecodeError,
    OutOfMemory,
};

/// Magic byte pattern for auto-detection
pub const MagicPattern = struct {
    offset: usize,
    bytes: []const u8,
};

/// Declared custom argument for a codec
pub const CodecArg = struct {
    name: []const u8, // "pages"
    description: []const u8, // "Page range to expand (e.g., 1-5, 3)"
    value_name: []const u8, // "RANGE" (shown as --pages RANGE in help)
};

/// Runtime key-value pair for a codec-specific argument
pub const CodecArgValue = struct {
    key: []const u8,
    value: []const u8,
};

/// Codec metadata
pub const CodecInfo = struct {
    name: []const u8,
    description: []const u8,
    extensions: []const []const u8,
    magic: []const MagicPattern,
    format_names: []const []const u8, // format field values this codec handles on collapse
    supports_faithful: bool,
    supports_editable: bool,
    help: []const u8 = "", // detailed help text
    custom_args: []const CodecArg = &.{}, // declared custom arguments
};

/// Options controlling codec behavior
pub const CodecOptions = struct {
    /// true = bit-perfect round-trip (preserve all derived fields like CRC)
    /// false = editable mode (omit derived fields, recalculate on collapse)
    faithful: bool = true,
    /// codec-specific arguments passed from CLI
    codec_args: []const CodecArgValue = &.{},

    /// Look up a codec-specific arg by name
    pub fn getArg(self: CodecOptions, name: []const u8) ?[]const u8 {
        for (self.codec_args) |kv| {
            if (std.mem.eql(u8, kv.key, name)) return kv.value;
        }
        return null;
    }
};

/// Runtime-polymorphic codec interface using Zig vtable pattern
pub const Codec = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        info: *const fn (ctx: *anyopaque) CodecInfo,
        expand: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, data: []const u8, options: CodecOptions) CodecError!Value,
        collapse: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, value: Value, options: CodecOptions) CodecError![]u8,
    };

    pub fn info(self: Codec) CodecInfo {
        return self.vtable.info(self.ptr);
    }

    pub fn expand(self: Codec, allocator: std.mem.Allocator, data: []const u8, options: CodecOptions) CodecError!Value {
        return self.vtable.expand(self.ptr, allocator, data, options);
    }

    pub fn collapse(self: Codec, allocator: std.mem.Allocator, value: Value, options: CodecOptions) CodecError![]u8 {
        return self.vtable.collapse(self.ptr, allocator, value, options);
    }

    /// Create a Codec from any type that implements the required interface.
    /// The type T must have: info(*T) CodecInfo, expand(*T, ...) ..., collapse(*T, ...) ...
    pub fn init(pointer: anytype) Codec {
        const Ptr = @TypeOf(pointer);
        const ptr_info = @typeInfo(Ptr);

        comptime {
            if (ptr_info != .pointer) @compileError("expected pointer, got " ++ @typeName(Ptr));
            if (ptr_info.pointer.size != .one) @compileError("expected single pointer");
        }

        const T = ptr_info.pointer.child;

        const gen = struct {
            fn infoFn(ctx: *anyopaque) CodecInfo {
                const self: *T = @ptrCast(@alignCast(ctx));
                return self.getInfo();
            }
            fn expandFn(ctx: *anyopaque, allocator: std.mem.Allocator, data: []const u8, options: CodecOptions) CodecError!Value {
                const self: *T = @ptrCast(@alignCast(ctx));
                return self.expandImpl(allocator, data, options);
            }
            fn collapseFn(ctx: *anyopaque, allocator: std.mem.Allocator, value: Value, options: CodecOptions) CodecError![]u8 {
                const self: *T = @ptrCast(@alignCast(ctx));
                return self.collapseImpl(allocator, value, options);
            }
        };

        return .{
            .ptr = pointer,
            .vtable = &.{
                .info = gen.infoFn,
                .expand = gen.expandFn,
                .collapse = gen.collapseFn,
            },
        };
    }
};

/// True when `data` carries one of the codec's magic byte patterns at its offset.
pub fn magicMatches(info: CodecInfo, data: []const u8) bool {
    for (info.magic) |m| {
        if (data.len >= m.offset + m.bytes.len and std.mem.eql(u8, data[m.offset..][0..m.bytes.len], m.bytes)) return true;
    }
    return false;
}

/// True when the codec claims the file extension (with dot), compared case-insensitively.
pub fn claimsExtension(info: CodecInfo, ext: []const u8) bool {
    for (info.extensions) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    return false;
}

// ============================================================================
// Tests
// ============================================================================
//
// Codec selection now happens in the c0 CLI's plugin host (cli/codec_host.c, covered by
// tests/cli/test_codecs.sh). These tests check that each codec's metadata makes the claims the
// host relies on.

fn infoOf(comptime T: type) CodecInfo {
    var instance = T{};
    return instance.getInfo();
}

test "png metadata claims the PNG signature and .png" {
    const info = infoOf(png.PngCodec);
    try std.testing.expectEqualStrings("png", info.name);
    try std.testing.expect(magicMatches(info, "\x89PNG\r\n\x1a\n" ++ "extra data"));
    try std.testing.expect(claimsExtension(info, ".PNG"));
}

test "jpeg metadata claims the SOI marker and .jpg" {
    const info = infoOf(exif.JpegCodec);
    try std.testing.expectEqualStrings("jpeg", info.name);
    try std.testing.expect(magicMatches(info, "\xFF\xD8\xFF\xE0extra"));
    try std.testing.expect(claimsExtension(info, ".jpg"));
}

test "tiff metadata claims both byte orders" {
    const info = infoOf(exif.TiffCodec);
    try std.testing.expectEqualStrings("tiff", info.name);
    try std.testing.expect(magicMatches(info, "II\x2a\x00extra"));
    try std.testing.expect(magicMatches(info, "MM\x00\x2aextra"));
}

test "no codec claims unrecognized data, and short input never matches" {
    inline for (.{ png.PngCodec, bg3.Bg3Codec, json.JsonCodec, exif.JpegCodec, exif.TiffCodec, pdf.PdfCodec }) |T| {
        const info = infoOf(T);
        try std.testing.expect(!magicMatches(info, "random data"));
        try std.testing.expect(!magicMatches(info, ""));
        try std.testing.expect(!claimsExtension(info, ".xyz"));
    }
}

test "codec names are unique and safe as plugin executable names" {
    const infos = [_]CodecInfo{ infoOf(png.PngCodec), infoOf(bg3.Bg3Codec), infoOf(json.JsonCodec), infoOf(exif.JpegCodec), infoOf(exif.TiffCodec), infoOf(pdf.PdfCodec) };
    for (infos, 0..) |a, i| {
        for (a.name) |c| try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
        for (infos[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
    }
}

test {
    _ = png;
    _ = bg3;
    _ = json;
    _ = exif;
    _ = pdf;
}
