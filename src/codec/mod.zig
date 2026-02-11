//! C0 Codec System - Runtime-polymorphic codec interface
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

/// Codec metadata
pub const CodecInfo = struct {
    name: []const u8,
    description: []const u8,
    extensions: []const []const u8,
    magic: []const MagicPattern,
    format_names: []const []const u8, // format field values this codec handles on collapse
    supports_faithful: bool,
    supports_editable: bool,
};

/// Options controlling codec behavior
pub const CodecOptions = struct {
    /// true = bit-perfect round-trip (preserve all derived fields like CRC)
    /// false = editable mode (omit derived fields, recalculate on collapse)
    faithful: bool = true,
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

/// Registry of available codecs
pub const Registry = struct {
    codecs: []const Codec,

    /// Find a codec by name
    pub fn findByName(self: Registry, name: []const u8) ?Codec {
        for (self.codecs) |codec| {
            if (std.mem.eql(u8, codec.info().name, name)) return codec;
        }
        return null;
    }

    /// Find a codec by file extension (including the dot)
    pub fn findByExtension(self: Registry, ext: []const u8) ?Codec {
        for (self.codecs) |codec| {
            for (codec.info().extensions) |supported_ext| {
                if (std.ascii.eqlIgnoreCase(ext, supported_ext)) return codec;
            }
        }
        return null;
    }

    /// Auto-detect codec from file content and optional filename
    pub fn detect(self: Registry, filename: ?[]const u8, data: []const u8) ?Codec {
        // First try magic bytes (most reliable)
        for (self.codecs) |codec| {
            for (codec.info().magic) |magic| {
                if (data.len >= magic.offset + magic.bytes.len) {
                    if (std.mem.eql(u8, data[magic.offset..][0..magic.bytes.len], magic.bytes)) {
                        return codec;
                    }
                }
            }
        }

        // Fall back to extension matching
        if (filename) |name| {
            const ext = std.fs.path.extension(name);
            if (ext.len > 0) {
                return self.findByExtension(ext);
            }
        }

        return null;
    }

    /// Infer codec from a C0 Value's "format" field
    pub fn findByFormatField(self: Registry, value: Value) ?Codec {
        switch (value) {
            .object => |entries| {
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, "format")) {
                        switch (entry.value) {
                            .string => |format_name| {
                                // Check format_names first, then fall back to codec name
                                for (self.codecs) |codec| {
                                    const info = codec.info();
                                    for (info.format_names) |fn_name| {
                                        if (std.mem.eql(u8, fn_name, format_name)) return codec;
                                    }
                                    if (std.mem.eql(u8, info.name, format_name)) return codec;
                                }
                                return null;
                            },
                            else => return null,
                        }
                    }
                }
            },
            else => {},
        }
        return null;
    }
};

/// Built-in codec registry
var png_instance = png.PngCodec{};
var bg3_instance = bg3.Bg3Codec{};
var json_instance = json.JsonCodec{};

pub const builtin_codecs = [_]Codec{
    Codec.init(&png_instance),
    Codec.init(&bg3_instance),
    Codec.init(&json_instance),
};

pub const builtin_registry = Registry{
    .codecs = &builtin_codecs,
};

// ============================================================================
// Tests
// ============================================================================

test "registry finds PNG codec by name" {
    const codec = builtin_registry.findByName("png");
    try std.testing.expect(codec != null);
    try std.testing.expectEqualStrings("png", codec.?.info().name);
}

test "registry finds PNG codec by extension" {
    const codec = builtin_registry.findByExtension(".png");
    try std.testing.expect(codec != null);
    try std.testing.expectEqualStrings("png", codec.?.info().name);
}

test "registry returns null for unknown codec" {
    try std.testing.expect(builtin_registry.findByName("nonexistent") == null);
    try std.testing.expect(builtin_registry.findByExtension(".xyz") == null);
}

test "registry detects PNG from magic bytes" {
    const png_sig = "\x89PNG\r\n\x1a\n" ++ "extra data";
    const codec = builtin_registry.detect(null, png_sig);
    try std.testing.expect(codec != null);
    try std.testing.expectEqualStrings("png", codec.?.info().name);
}

test "registry detects PNG from filename extension" {
    const codec = builtin_registry.detect("image.png", "not png data");
    try std.testing.expect(codec != null);
    try std.testing.expectEqualStrings("png", codec.?.info().name);
}

test "registry returns null for unrecognized data" {
    const codec = builtin_registry.detect(null, "random data");
    try std.testing.expect(codec == null);
}

test {
    _ = png;
    _ = bg3;
    _ = json;
}
