//! LZ4 compression wrapper for vendored C library
//!
//! Wraps LZ4_decompress_safe and LZ4_compress_default for use by BG3 codec.
//! BG3 uses both block mode (strings section) and chunked frame mode
//! (64KB chunks for other sections).

const std = @import("std");
const c = @cImport({
    @cInclude("lz4.h");
    @cInclude("lz4frame.h");
});

pub const LZ4Error = error{
    DecompressionFailed,
    CompressionFailed,
    OutOfMemory,
    InvalidChunkHeader,
    TruncatedInput,
};

/// Decompress a single LZ4 block
pub fn decompressBlock(allocator: std.mem.Allocator, src: []const u8, original_size: usize) LZ4Error![]u8 {
    const dest = allocator.alloc(u8, original_size) catch return LZ4Error.OutOfMemory;
    errdefer allocator.free(dest);

    const result = c.LZ4_decompress_safe(
        @ptrCast(src.ptr),
        @ptrCast(dest.ptr),
        @intCast(src.len),
        @intCast(original_size),
    );

    if (result < 0) return LZ4Error.DecompressionFailed;
    if (@as(usize, @intCast(result)) != original_size) return LZ4Error.DecompressionFailed;

    return dest;
}

/// Compress a single LZ4 block
pub fn compressBlock(allocator: std.mem.Allocator, src: []const u8) LZ4Error![]u8 {
    const max_dst = c.LZ4_compressBound(@intCast(src.len));
    const dest = allocator.alloc(u8, @intCast(max_dst)) catch return LZ4Error.OutOfMemory;
    errdefer allocator.free(dest);

    const result = c.LZ4_compress_default(
        @ptrCast(src.ptr),
        @ptrCast(dest.ptr),
        @intCast(src.len),
        max_dst,
    );

    if (result <= 0) return LZ4Error.CompressionFailed;

    // Shrink to actual size
    const actual = allocator.realloc(dest, @intCast(result)) catch return dest[0..@intCast(result)];
    return actual;
}

/// Decompress LZ4 chunked data (64KB frame mode used by BG3 LSF)
/// Format: repeated [compressed_size: u32 LE][compressed_data: compressed_size bytes]
/// Each chunk decompresses to at most chunk_size bytes (default 64KB)
pub fn decompressChunked(allocator: std.mem.Allocator, src: []const u8, total_uncompressed: usize, chunk_size: usize) LZ4Error![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    var remaining = total_uncompressed;

    while (remaining > 0 and pos < src.len) {
        if (pos + 4 > src.len) return LZ4Error.TruncatedInput;

        const compressed_size = std.mem.readInt(u32, src[pos..][0..4], .little);
        pos += 4;

        if (pos + compressed_size > src.len) return LZ4Error.TruncatedInput;

        const this_chunk = @min(remaining, chunk_size);
        const chunk_data = try decompressBlock(allocator, src[pos..][0..compressed_size], this_chunk);
        defer allocator.free(chunk_data);

        result.appendSlice(allocator, chunk_data) catch return LZ4Error.OutOfMemory;
        pos += compressed_size;
        remaining -= this_chunk;
    }

    return result.toOwnedSlice(allocator) catch return LZ4Error.OutOfMemory;
}

/// Compress data in chunked LZ4 format (64KB frames)
pub fn compressChunked(allocator: std.mem.Allocator, src: []const u8, chunk_size: usize) LZ4Error![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    while (pos < src.len) {
        const this_chunk = @min(src.len - pos, chunk_size);
        const compressed = try compressBlock(allocator, src[pos..][0..this_chunk]);
        defer allocator.free(compressed);

        // Write compressed size as u32 LE
        var size_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &size_buf, @intCast(compressed.len), .little);
        result.appendSlice(allocator, &size_buf) catch return LZ4Error.OutOfMemory;
        result.appendSlice(allocator, compressed) catch return LZ4Error.OutOfMemory;

        pos += this_chunk;
    }

    return result.toOwnedSlice(allocator) catch return LZ4Error.OutOfMemory;
}

/// Decompress an LZ4 frame (standard LZ4 frame format with magic 0x04224D18).
/// Used by BG3 LSF for non-string sections (nodes, attributes, values, keys).
pub fn decompressFrame(allocator: std.mem.Allocator, src: []const u8, expected_size: usize) LZ4Error![]u8 {
    var dctx: ?*c.LZ4F_dctx = null;
    const create_result = c.LZ4F_createDecompressionContext(&dctx, c.LZ4F_VERSION);
    if (c.LZ4F_isError(create_result) != 0) return LZ4Error.DecompressionFailed;
    defer _ = c.LZ4F_freeDecompressionContext(dctx);

    const dest = allocator.alloc(u8, expected_size) catch return LZ4Error.OutOfMemory;
    errdefer allocator.free(dest);

    var src_pos: usize = 0;
    var dst_pos: usize = 0;

    while (src_pos < src.len and dst_pos < expected_size) {
        var src_size: usize = src.len - src_pos;
        var dst_size: usize = expected_size - dst_pos;

        const result = c.LZ4F_decompress(
            dctx,
            @ptrCast(dest.ptr + dst_pos),
            &dst_size,
            @ptrCast(src.ptr + src_pos),
            &src_size,
            null,
        );

        if (c.LZ4F_isError(result) != 0) return LZ4Error.DecompressionFailed;

        src_pos += src_size;
        dst_pos += dst_size;

        // result == 0 means frame is complete
        if (result == 0) break;
    }

    if (dst_pos != expected_size) {
        // Resize to actual decompressed size
        const shrunk = allocator.realloc(dest, dst_pos) catch return dest[0..dst_pos];
        return shrunk;
    }

    return dest;
}

// ============================================================================
// Tests
// ============================================================================

test "LZ4 block round-trip" {
    const allocator = std.testing.allocator;

    const original = "Hello, LZ4 compression! This is a test of the BG3 codec LZ4 wrapper.";

    const compressed = try compressBlock(allocator, original);
    defer allocator.free(compressed);

    const decompressed = try decompressBlock(allocator, compressed, original.len);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}

test "LZ4 chunked round-trip" {
    const allocator = std.testing.allocator;

    // Create data larger than one chunk (use small chunk size for testing)
    const chunk_size: usize = 16;
    var original: [100]u8 = undefined;
    for (&original, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const compressed = try compressChunked(allocator, &original, chunk_size);
    defer allocator.free(compressed);

    const decompressed = try decompressChunked(allocator, compressed, original.len, chunk_size);
    defer allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, &original, decompressed);
}

test "LZ4 empty input" {
    const allocator = std.testing.allocator;

    const compressed = try compressBlock(allocator, "");
    defer allocator.free(compressed);

    const decompressed = try decompressBlock(allocator, compressed, 0);
    defer allocator.free(decompressed);

    try std.testing.expectEqual(@as(usize, 0), decompressed.len);
}
