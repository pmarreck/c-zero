//! Zstandard compression wrapper for vendored C library
//!
//! Wraps ZSTD_decompress and ZSTD_compress for use by BG3 codec.
//! BG3 V18 full release saves use zstd for per-file compression within LSPK packages.

const std = @import("std");
const c = @cImport({
    @cInclude("zstd.h");
});

pub const ZstdError = error{
    DecompressionFailed,
    CompressionFailed,
    OutOfMemory,
    ContentSizeUnknown,
};

/// Decompress a zstd frame. `max_size` is the expected decompressed size.
pub fn decompress(allocator: std.mem.Allocator, src: []const u8, max_size: usize) ZstdError![]u8 {
    const dest = allocator.alloc(u8, max_size) catch return ZstdError.OutOfMemory;
    errdefer allocator.free(dest);

    const result = c.ZSTD_decompress(
        @ptrCast(dest.ptr),
        max_size,
        @ptrCast(src.ptr),
        src.len,
    );

    if (c.ZSTD_isError(result) != 0) return ZstdError.DecompressionFailed;

    // Shrink to actual decompressed size if smaller than max_size. If the
    // shrink realloc fails, fall back to a fresh exact-size allocation + copy:
    // returning dest[0..result] would hand the caller a slice whose length
    // under-reports the real allocation, corrupting the allocator on free.
    if (result < max_size) {
        if (allocator.realloc(dest, result)) |shrunk| {
            return shrunk;
        } else |_| {
            const exact = allocator.alloc(u8, result) catch return ZstdError.OutOfMemory;
            @memcpy(exact, dest[0..result]);
            allocator.free(dest);
            return exact;
        }
    }
    return dest;
}

/// Compress data using zstd at the given compression level (1 = fast, default).
pub fn compress(allocator: std.mem.Allocator, src: []const u8, level: c_int) ZstdError![]u8 {
    const max_dst = c.ZSTD_compressBound(src.len);
    if (c.ZSTD_isError(max_dst) != 0) return ZstdError.CompressionFailed;

    const dest = allocator.alloc(u8, max_dst) catch return ZstdError.OutOfMemory;
    errdefer allocator.free(dest);

    const result = c.ZSTD_compress(
        @ptrCast(dest.ptr),
        max_dst,
        @ptrCast(src.ptr),
        src.len,
        level,
    );

    if (c.ZSTD_isError(result) != 0) return ZstdError.CompressionFailed;

    // Shrink to actual size. If the shrink realloc fails, fall back to a fresh
    // exact-size allocation + copy (see decompress) so the returned slice can be
    // freed correctly by the caller.
    if (allocator.realloc(dest, result)) |shrunk| {
        return shrunk;
    } else |_| {
        const exact = allocator.alloc(u8, result) catch return ZstdError.OutOfMemory;
        @memcpy(exact, dest[0..result]);
        allocator.free(dest);
        return exact;
    }
}

// These constants can't come from cImport due to Zig integer overflow issues
// In C: ZSTD_CONTENTSIZE_UNKNOWN = (0ULL - 1), ZSTD_CONTENTSIZE_ERROR = (0ULL - 2)
const ZSTD_CONTENTSIZE_UNKNOWN: c_ulonglong = std.math.maxInt(c_ulonglong);
const ZSTD_CONTENTSIZE_ERROR: c_ulonglong = std.math.maxInt(c_ulonglong) - 1;

/// Get the decompressed content size from a zstd frame header.
/// Returns null if the size is unknown or there's an error.
pub fn getFrameContentSize(src: []const u8) ?u64 {
    const result = c.ZSTD_getFrameContentSize(@ptrCast(src.ptr), src.len);
    if (result == ZSTD_CONTENTSIZE_UNKNOWN or result == ZSTD_CONTENTSIZE_ERROR) {
        return null;
    }
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "zstd round-trip" {
    const allocator = std.testing.allocator;

    const original = "Hello, zstd compression! This is a test of the BG3 codec zstd wrapper. Let's make it long enough to actually compress.";

    const compressed = try compress(allocator, original, 1);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, compressed, original.len);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}

test "zstd frame content size" {
    const allocator = std.testing.allocator;

    const original = "Test data for frame content size check";
    const compressed = try compress(allocator, original, 1);
    defer allocator.free(compressed);

    const size = getFrameContentSize(compressed);
    try std.testing.expect(size != null);
    try std.testing.expectEqual(@as(u64, original.len), size.?);
}

test "zstd empty input" {
    const allocator = std.testing.allocator;

    const compressed = try compress(allocator, "", 1);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, compressed, 0);
    defer allocator.free(decompressed);

    try std.testing.expectEqual(@as(usize, 0), decompressed.len);
}
