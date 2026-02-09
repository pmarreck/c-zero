//! PNG Destructuring Demo
//!
//! Demonstrates C0 as a lossless binary container for real-world file formats.
//! Reads a PNG file, destructures it into its chunk regions as a C0 structure
//! (with binary data pb-encoded), outputs the human-readable C0 text, then
//! decodes it back and reconstructs the identical PNG — proving lossless round-trip.
//!
//! Run with: zig build run-png-demo -- path/to/file.png

const std = @import("std");
const core = @import("c0_core");

const Value = core.Value;
const Entry = core.Entry;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Set up stdout writer (Zig 0.15 API)
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    // Get PNG file path from CLI args
    var args = std.process.args();
    _ = args.next(); // skip program name
    const png_path = args.next() orelse {
        try stdout.print("Usage: png_demo <path-to-png-file>\n", .{});
        try stdout.print("Example: zig build run-png-demo -- ~/Desktop/image.png\n", .{});
        return;
    };

    // Read the PNG file
    const png_data = std.fs.cwd().openFile(png_path, .{}) catch |err| {
        try stdout.print("Error opening file '{s}': {}\n", .{ png_path, err });
        return;
    };
    defer png_data.close();

    const original = png_data.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
        try stdout.print("Error reading file: {}\n", .{err});
        return;
    };
    defer allocator.free(original);

    // Validate PNG signature
    const png_signature = "\x89PNG\r\n\x1a\n";
    if (original.len < 8 or !std.mem.eql(u8, original[0..8], png_signature)) {
        try stdout.print("Error: not a valid PNG file (bad signature)\n", .{});
        return;
    }

    try stdout.print("=== C0 PNG Destructuring Demo ===\n\n", .{});

    // Parse PNG chunks
    var chunks: std.ArrayListUnmanaged(PngChunk) = .{};
    defer chunks.deinit(allocator);

    var pos: usize = 8; // skip signature
    while (pos + 12 <= original.len) { // minimum chunk: 4 len + 4 type + 4 crc
        const data_len = std.mem.readInt(u32, original[pos..][0..4], .big);
        const chunk_type = original[pos + 4 .. pos + 8];
        const data_start = pos + 8;
        const data_end = data_start + data_len;
        const crc_end = data_end + 4;

        if (crc_end > original.len) break;

        try chunks.append(allocator, .{
            .chunk_type = chunk_type,
            .data = original[data_start..data_end],
            .crc = original[data_end..crc_end],
        });

        pos = crc_end;

        // Stop after IEND
        if (std.mem.eql(u8, chunk_type, "IEND")) break;
    }

    // Print file info
    try stdout.print("File: {s}\n", .{png_path});
    try stdout.print("Size: {d} bytes\n", .{original.len});
    try stdout.print("Chunks: {d}\n", .{chunks.items.len});

    // Print chunk summary
    try stdout.print("\nChunk layout:\n", .{});
    for (chunks.items) |chunk| {
        try stdout.print("  {s}  {d:>6} bytes\n", .{ chunk.chunk_type, chunk.data.len });
    }

    // Print IHDR details if present
    if (chunks.items.len > 0 and std.mem.eql(u8, chunks.items[0].chunk_type, "IHDR") and chunks.items[0].data.len >= 13) {
        const ihdr = chunks.items[0].data;
        const width = std.mem.readInt(u32, ihdr[0..4], .big);
        const height = std.mem.readInt(u32, ihdr[4..8], .big);
        const bit_depth = ihdr[8];
        const color_type = ihdr[9];
        const color_type_name: []const u8 = switch (color_type) {
            0 => "grayscale",
            2 => "RGB",
            3 => "indexed",
            4 => "grayscale+alpha",
            6 => "RGBA",
            else => "unknown",
        };
        try stdout.print("\nIHDR: {d}x{d}, {d}-bit {s}\n", .{ width, height, bit_depth, color_type_name });
    }

    // Build C0 structure with raw binary data
    // core.encode (smart mode) will pb-encode payloads automatically
    var chunk_values = try allocator.alloc(Value, chunks.items.len);
    defer allocator.free(chunk_values);

    var chunk_entries_list = try allocator.alloc([3]Entry, chunks.items.len);
    defer allocator.free(chunk_entries_list);

    for (chunks.items, 0..) |chunk, i| {
        chunk_entries_list[i] = .{
            .{ .key = "type", .value = .{ .string = chunk.chunk_type } },
            .{ .key = "data", .value = .{ .string = chunk.data } },
            .{ .key = "crc", .value = .{ .string = chunk.crc } },
        };
        chunk_values[i] = .{ .object = &chunk_entries_list[i] };
    }

    // Build top-level object: {signature: ..., chunks: [...]}
    var top_entries = [_]Entry{
        .{ .key = "signature", .value = .{ .string = png_signature } },
        .{ .key = "chunks", .value = .{ .array = chunk_values } },
    };
    const c0_value = Value{ .object = &top_entries };

    // Encode to C0 — smart encoding handles pb-encoding of binary payloads
    const c0_bytes = try core.encode(allocator, c0_value);
    defer allocator.free(c0_bytes);

    try stdout.print("\nC0 encoded size: {d} bytes\n", .{c0_bytes.len});

    // Show a snippet — chunk type names should be visible as ASCII
    try stdout.print("\nC0 snippet (first 200 bytes):\n", .{});
    const snippet_len = @min(c0_bytes.len, 200);
    try stdout.print("{s}...\n", .{c0_bytes[0..snippet_len]});

    // Decode back from C0
    const decoded = try core.decode(allocator, c0_bytes);
    defer core.deinit(allocator, decoded);

    // Reassemble PNG from decoded C0 structure
    var reassembled: std.ArrayListUnmanaged(u8) = .{};
    defer reassembled.deinit(allocator);

    // Write PNG signature (already decoded back to raw binary by core.decode)
    try reassembled.appendSlice(allocator, decoded.object[0].value.string);

    // Write chunks
    const decoded_chunks = decoded.object[1].value.array;
    for (decoded_chunks) |chunk_val| {
        const chunk_obj = chunk_val.object;

        // Get type (4 ASCII bytes — passes through pb unchanged)
        const chunk_type = chunk_obj[0].value.string;

        // Data and CRC are already decoded back to raw binary by core.decode
        const chunk_data = chunk_obj[1].value.string;
        const chunk_crc = chunk_obj[2].value.string;

        // Write length (4 bytes BE, derived from decoded data length)
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(chunk_data.len), .big);
        try reassembled.appendSlice(allocator, &len_buf);

        // Write type
        try reassembled.appendSlice(allocator, chunk_type);

        // Write data
        try reassembled.appendSlice(allocator, chunk_data);

        // Write CRC
        try reassembled.appendSlice(allocator, chunk_crc);
    }

    // Verify byte-for-byte match
    const match = std.mem.eql(u8, original, reassembled.items);

    try stdout.print("\n=== Round-Trip Verification ===\n", .{});
    try stdout.print("Original:    {d} bytes\n", .{original.len});
    try stdout.print("Reassembled: {d} bytes\n", .{reassembled.items.len});
    try stdout.print("Byte-for-byte match: {}\n", .{match});

    try stdout.print("\n=== Pipeline ===\n", .{});
    try stdout.print("PNG file ({d} bytes)\n", .{original.len});
    try stdout.print("  -> destructure into {d} chunks\n", .{chunks.items.len});
    try stdout.print("  -> C0 text ({d} bytes, human-readable UTF-8)\n", .{c0_bytes.len});
    try stdout.print("  -> decode C0 back to structured data\n", .{});
    try stdout.print("  -> reassemble PNG ({d} bytes)\n", .{reassembled.items.len});
    try stdout.print("  -> identical: {}\n", .{match});

    if (!match) {
        try stdout.print("\nERROR: Round-trip failed! Files differ.\n", .{});
        // Find first difference for debugging
        const min_len = @min(original.len, reassembled.items.len);
        for (0..min_len) |idx| {
            if (original[idx] != reassembled.items[idx]) {
                try stdout.print("First difference at byte {d}: original=0x{x:0>2} reassembled=0x{x:0>2}\n", .{ idx, original[idx], reassembled.items[idx] });
                break;
            }
        }
    }
}

const PngChunk = struct {
    chunk_type: []const u8, // 4 bytes
    data: []const u8,
    crc: []const u8, // 4 bytes
};

// ============================================================================
// Tests
// ============================================================================

test "PNG chunk parsing round-trip with synthetic PNG" {
    const allocator = std.testing.allocator;

    // Build a minimal synthetic PNG:
    // signature + IHDR chunk + IEND chunk
    const png_sig = "\x89PNG\r\n\x1a\n";

    // IHDR: 13 bytes of data
    const ihdr_data = [13]u8{
        0, 0, 0, 1, // width=1
        0, 0, 0, 1, // height=1
        8,          // bit depth
        2,          // color type (RGB)
        0,          // compression
        0,          // filter
        0,          // interlace
    };
    const ihdr_crc = [4]u8{ 0x1A, 0x2B, 0x3C, 0x4D }; // fake CRC for test

    // IEND: 0 bytes of data
    const iend_crc = [4]u8{ 0xAE, 0x42, 0x60, 0x82 }; // real IEND CRC

    // Assemble the PNG
    var png_buf: [8 + 12 + 13 + 12]u8 = undefined; // sig + IHDR(4+4+13+4) + IEND(4+4+0+4)
    var write_pos: usize = 0;

    // Signature
    @memcpy(png_buf[write_pos..][0..8], png_sig);
    write_pos += 8;

    // IHDR length (13)
    std.mem.writeInt(u32, png_buf[write_pos..][0..4], 13, .big);
    write_pos += 4;
    // IHDR type
    @memcpy(png_buf[write_pos..][0..4], "IHDR");
    write_pos += 4;
    // IHDR data
    @memcpy(png_buf[write_pos..][0..13], &ihdr_data);
    write_pos += 13;
    // IHDR CRC
    @memcpy(png_buf[write_pos..][0..4], &ihdr_crc);
    write_pos += 4;

    // IEND length (0)
    std.mem.writeInt(u32, png_buf[write_pos..][0..4], 0, .big);
    write_pos += 4;
    // IEND type
    @memcpy(png_buf[write_pos..][0..4], "IEND");
    write_pos += 4;
    // IEND CRC
    @memcpy(png_buf[write_pos..][0..4], &iend_crc);
    write_pos += 4;

    const original = png_buf[0..write_pos];

    // Parse chunks
    const sig = original[0..8];
    var chunks: std.ArrayListUnmanaged(PngChunk) = .{};
    defer chunks.deinit(allocator);

    var pos: usize = 8;
    while (pos + 12 <= original.len) {
        const data_len = std.mem.readInt(u32, original[pos..][0..4], .big);
        const chunk_type = original[pos + 4 .. pos + 8];
        const data_start = pos + 8;
        const data_end = data_start + data_len;
        const crc_end = data_end + 4;
        if (crc_end > original.len) break;
        try chunks.append(allocator, .{
            .chunk_type = chunk_type,
            .data = original[data_start..data_end],
            .crc = original[data_end..crc_end],
        });
        pos = crc_end;
        if (std.mem.eql(u8, chunk_type, "IEND")) break;
    }

    try std.testing.expectEqual(@as(usize, 2), chunks.items.len);
    try std.testing.expectEqualStrings("IHDR", chunks.items[0].chunk_type);
    try std.testing.expectEqualStrings("IEND", chunks.items[1].chunk_type);

    // Build chunk values with raw binary data
    var chunk_values = try allocator.alloc(Value, chunks.items.len);
    defer allocator.free(chunk_values);

    var chunk_entries_list = try allocator.alloc([3]Entry, chunks.items.len);
    defer allocator.free(chunk_entries_list);

    for (chunks.items, 0..) |chunk, i| {
        chunk_entries_list[i] = .{
            .{ .key = "type", .value = .{ .string = chunk.chunk_type } },
            .{ .key = "data", .value = .{ .string = chunk.data } },
            .{ .key = "crc", .value = .{ .string = chunk.crc } },
        };
        chunk_values[i] = .{ .object = &chunk_entries_list[i] };
    }

    var top_entries = [_]Entry{
        .{ .key = "signature", .value = .{ .string = sig } },
        .{ .key = "chunks", .value = .{ .array = chunk_values } },
    };
    const c0_value = Value{ .object = &top_entries };

    // Encode to C0 (smart mode pb-encodes binary payloads)
    const c0_bytes = try core.encode(allocator, c0_value);
    defer allocator.free(c0_bytes);

    // Decode from C0 (smart decode recovers raw binary)
    const decoded = try core.decode(allocator, c0_bytes);
    defer core.deinit(allocator, decoded);

    // Reassemble
    var reassembled: std.ArrayListUnmanaged(u8) = .{};
    defer reassembled.deinit(allocator);

    try reassembled.appendSlice(allocator, decoded.object[0].value.string);

    const decoded_chunks = decoded.object[1].value.array;
    for (decoded_chunks) |chunk_val| {
        const chunk_obj = chunk_val.object;
        const chunk_type = chunk_obj[0].value.string;
        const chunk_data = chunk_obj[1].value.string;
        const chunk_crc = chunk_obj[2].value.string;

        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(chunk_data.len), .big);
        try reassembled.appendSlice(allocator, &len_buf);
        try reassembled.appendSlice(allocator, chunk_type);
        try reassembled.appendSlice(allocator, chunk_data);
        try reassembled.appendSlice(allocator, chunk_crc);
    }

    // Verify byte-for-byte match
    try std.testing.expectEqualSlices(u8, original, reassembled.items);
}
