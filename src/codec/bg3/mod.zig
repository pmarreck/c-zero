//! BG3 Save Codec - Destructures Baldur's Gate 3 save files
//!
//! Supports two sub-formats:
//!   - LSPK: Package container (.lsv, .pak files) - magic at EOF
//!   - LSF: Structured data (.lsf files) - magic "LSOF" at byte 0
//!
//! The codec auto-detects which sub-format is present and dispatches
//! accordingly. LSPK packages recursively expand LSF files within them.

const std = @import("std");
const core = @import("c0_core");
const codec = @import("../mod.zig");
pub const lspk = @import("lspk.zig");
pub const lsf = @import("lsf.zig");
pub const types = @import("types.zig");
pub const lz4 = @import("lz4.zig");
pub const zstd_wrapper = @import("zstd.zig");

const Value = core.Value;
const CodecInfo = codec.CodecInfo;
const CodecOptions = codec.CodecOptions;
const CodecError = codec.CodecError;
const MagicPattern = codec.MagicPattern;

pub const Bg3Codec = struct {
    pub fn getInfo(_: *Bg3Codec) CodecInfo {
        return .{
            .name = "bg3",
            .description = "Baldur's Gate 3 save files (LSPK packages and LSF data)",
            .extensions = &.{ ".lsv", ".pak", ".lsf" },
            .magic = &.{
                .{ .offset = 0, .bytes = "LSOF" }, // LSF files
                .{ .offset = 0, .bytes = "LSPK" }, // LSPK packages
            },
            .format_names = &.{ "bg3-lspk", "bg3-lsf" },
            .supports_faithful = true,
            .supports_editable = false,
        };
    }

    pub fn expandImpl(_: *Bg3Codec, allocator: std.mem.Allocator, data: []const u8, _: CodecOptions) CodecError!Value {
        // Try LSF first (magic "LSOF" at offset 0)
        if (data.len >= 4 and std.mem.eql(u8, data[0..4], "LSOF")) {
            return lsf.expand(allocator, data) catch return CodecError.InvalidFormat;
        }

        // Try LSPK (magic "LSPK" at offset 0)
        if (data.len >= 4 and std.mem.eql(u8, data[0..4], "LSPK")) {
            return lspk.expand(allocator, data) catch |err| switch (err) {
                lspk.LspkError.UnsupportedVersion => return CodecError.UnsupportedVersion,
                else => return CodecError.InvalidFormat,
            };
        }

        return CodecError.InvalidMagic;
    }

    pub fn collapseImpl(_: *Bg3Codec, allocator: std.mem.Allocator, value: Value, _: CodecOptions) CodecError![]u8 {
        // Determine sub-format from the "format" field
        const entries = switch (value) {
            .object => |e| e,
            else => return CodecError.InvalidFormat,
        };

        for (entries) |entry| {
            if (std.mem.eql(u8, entry.key, "format")) {
                const format_name = switch (entry.value) {
                    .string => |s| s,
                    else => return CodecError.InvalidFormat,
                };
                if (std.mem.eql(u8, format_name, "bg3-lspk")) {
                    return lspk.collapse(allocator, value) catch return CodecError.InvalidFormat;
                } else if (std.mem.eql(u8, format_name, "bg3-lsf")) {
                    return lsf.collapse(allocator, value) catch return CodecError.InvalidFormat;
                }
                break;
            }
        }

        return CodecError.InvalidFormat;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BG3 codec info" {
    var bg3_codec = Bg3Codec{};
    const c = codec.Codec.init(&bg3_codec);
    const info = c.info();

    try std.testing.expectEqualStrings("bg3", info.name);
    try std.testing.expect(info.supports_faithful);
    try std.testing.expectEqual(@as(usize, 3), info.extensions.len);
}

test "BG3 codec rejects unknown data" {
    var bg3_codec = Bg3Codec{};
    const c = codec.Codec.init(&bg3_codec);

    const result = c.expand(std.testing.allocator, "random data that is definitely not a BG3 file format!", .{});
    try std.testing.expectError(CodecError.InvalidMagic, result);
}

test {
    _ = lsf;
    _ = lspk;
    _ = types;
    _ = lz4;
    _ = zstd_wrapper;
}
