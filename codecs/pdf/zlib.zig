//! Thin zlib C wrapper for PDF FlateDecode support.
//!
//! Uses vendored zlib in lib/zlib/ (madler/zlib 1.3.1).
//! Provides inflate (decompress) and deflate (compress) for PDF stream filters.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("zlib.h");
});

pub const ZlibError = error{
    InitFailed,
    DataError,
    BufferError,
    ZlibInternalError,
    OutOfMemory,
    UnexpectedEof,
};

const max_default: usize = 256 * 1024 * 1024; // 256 MB

fn initStream(compressed: []const u8) c.z_stream {
    return .{
        .next_in = @constCast(compressed.ptr),
        .avail_in = @intCast(compressed.len),
        .next_out = undefined,
        .avail_out = 0,
        .zalloc = null,
        .zfree = null,
        .@"opaque" = null,
        .total_in = 0,
        .total_out = 0,
        .msg = null,
        .state = null,
        .data_type = 0,
        .adler = 0,
        .reserved = 0,
    };
}

fn inflateAllocInternal(allocator: Allocator, compressed: []const u8, max_output_size: usize, window_bits: c_int) (Allocator.Error || ZlibError)![]u8 {
    var stream = initStream(compressed);

    const init_ret = c.inflateInit2(&stream, window_bits);
    if (init_ret != c.Z_OK) return ZlibError.InitFailed;
    defer _ = c.inflateEnd(&stream);

    var output_size: usize = @min(compressed.len * 4, max_output_size);
    if (output_size < 4096) output_size = 4096;

    var output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);

    stream.next_out = output.ptr;
    stream.avail_out = @intCast(output.len);

    while (true) {
        const ret = c.inflate(&stream, c.Z_NO_FLUSH);

        switch (ret) {
            c.Z_STREAM_END => {
                const final_size = stream.total_out;
                if (final_size < output.len) {
                    output = allocator.realloc(output, final_size) catch output;
                }
                return output[0..final_size];
            },
            c.Z_OK, c.Z_BUF_ERROR => {
                if (stream.avail_out == 0) {
                    const new_size = output.len * 2;
                    if (new_size > max_output_size) return ZlibError.BufferError;
                    output = try allocator.realloc(output, new_size);
                    stream.next_out = output.ptr + stream.total_out;
                    stream.avail_out = @intCast(output.len - stream.total_out);
                } else if (stream.avail_in == 0) {
                    return ZlibError.UnexpectedEof;
                }
            },
            c.Z_DATA_ERROR => return ZlibError.DataError,
            c.Z_MEM_ERROR => return ZlibError.OutOfMemory,
            else => return ZlibError.ZlibInternalError,
        }
    }
}

/// Decompress zlib-format data (with zlib header). PDF's FlateDecode uses this.
pub fn inflateAlloc(allocator: Allocator, compressed: []const u8, max_output_size: usize) (Allocator.Error || ZlibError)![]u8 {
    return inflateAllocInternal(allocator, compressed, max_output_size, 15);
}

/// Decompress raw deflate data (no zlib header).
pub fn inflateRawAlloc(allocator: Allocator, compressed: []const u8, max_output_size: usize) (Allocator.Error || ZlibError)![]u8 {
    return inflateAllocInternal(allocator, compressed, max_output_size, -15);
}

/// Compress data with zlib format (for re-encoding FlateDecode streams).
pub fn deflateAlloc(allocator: Allocator, data: []const u8) (Allocator.Error || ZlibError)![]u8 {
    var stream: c.z_stream = .{
        .next_in = @constCast(data.ptr),
        .avail_in = @intCast(data.len),
        .next_out = undefined,
        .avail_out = 0,
        .zalloc = null,
        .zfree = null,
        .@"opaque" = null,
        .total_in = 0,
        .total_out = 0,
        .msg = null,
        .state = null,
        .data_type = 0,
        .adler = 0,
        .reserved = 0,
    };

    const init_ret = c.deflateInit(&stream, c.Z_DEFAULT_COMPRESSION);
    if (init_ret != c.Z_OK) return ZlibError.InitFailed;
    defer _ = c.deflateEnd(&stream);

    // Compressed output is at most slightly larger than input + overhead
    var output_size: usize = data.len + data.len / 100 + 256;
    if (output_size < 256) output_size = 256;

    var output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);

    stream.next_out = output.ptr;
    stream.avail_out = @intCast(output.len);

    const ret = c.deflate(&stream, c.Z_FINISH);
    if (ret != c.Z_STREAM_END) {
        // Should always finish in one call for reasonable inputs
        return ZlibError.ZlibInternalError;
    }

    const final_size = stream.total_out;
    if (final_size < output.len) {
        output = allocator.realloc(output, final_size) catch output;
    }
    return output[0..final_size];
}

// ============================================================================
// Tests
// ============================================================================

test "deflate then inflate round-trip" {
    const allocator = std.testing.allocator;
    const original = "Hello, PDF world! This is a test of zlib compression.";

    const compressed = try deflateAlloc(allocator, original);
    defer allocator.free(compressed);

    const decompressed = try inflateAlloc(allocator, compressed, max_default);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}

test "inflate raw deflate" {
    const allocator = std.testing.allocator;
    // "hello" compressed with raw deflate
    const compressed = [_]u8{ 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00 };

    const result = try inflateRawAlloc(allocator, &compressed, max_default);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello", result);
}

test "inflate invalid data returns error" {
    const allocator = std.testing.allocator;
    const invalid = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };

    const result = inflateAlloc(allocator, &invalid, max_default);
    try std.testing.expectError(ZlibError.DataError, result);
}

test "deflate empty data" {
    const allocator = std.testing.allocator;
    const empty = "";

    const compressed = try deflateAlloc(allocator, empty);
    defer allocator.free(compressed);

    const decompressed = try inflateAlloc(allocator, compressed, max_default);
    defer allocator.free(decompressed);

    try std.testing.expectEqual(@as(usize, 0), decompressed.len);
}
