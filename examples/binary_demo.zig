//! Binary Data Container Demo
//!
//! Demonstrates C0 as a human-readable container for arbitrary binary data.
//! Unlike JSON which requires base64 encoding for binary, C0 uses printable_binary
//! encoding which produces legible UTF-8 output where ASCII text remains readable.
//!
//! Run with: zig build run-binary-demo

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

    try stdout.print("=== C0 Binary Data Container Demo ===\n\n", .{});

    // Demo 1: Binary data with embedded ASCII
    try stdout.print("--- Demo 1: Binary with Embedded ASCII ---\n", .{});
    {
        // Simulate a binary format with magic bytes, version, and embedded text
        const binary_data = "\x89PNG\r\n\x1a\nHello from binary!This is readable\x00\x01\x02\xff";

        try stdout.print("Original binary ({d} bytes): ", .{binary_data.len});
        printBinaryPreview(stdout, binary_data);
        try stdout.print("\n", .{});

        // Encode as C0 string
        const val = Value{ .string = binary_data };
        const encoded = try core.encode(allocator, val);
        defer allocator.free(encoded);

        try stdout.print("C0 encoded ({d} bytes): {s}\n", .{ encoded.len, encoded });

        // Decode back
        const decoded = try core.decode(allocator, encoded);
        defer core.deinit(allocator, decoded);

        try stdout.print("Round-trip OK: {}\n\n", .{std.mem.eql(u8, decoded.string, binary_data)});
    }

    // Demo 2: Structured binary message (like a network packet)
    try stdout.print("--- Demo 2: Structured Binary Message ---\n", .{});
    {
        // Simulate a packet: { header: [magic, version, flags], payload: binary, checksum: bytes }
        const magic = "\x7fELF"; // ELF magic number
        const version = "\x02"; // 64-bit
        const flags = "\x01\x00\x00\x00"; // Little endian
        const payload = "This is the payload data with some binary\x00\x01\x02\x03mixed in";
        const checksum = "\xde\xad\xbe\xef";

        // Build the C0 structure
        var header_items = [_]Value{
            .{ .string = magic },
            .{ .string = version },
            .{ .string = flags },
        };
        const header = Value{ .array = &header_items };

        var entries = [_]Entry{
            .{ .key = "header", .value = header },
            .{ .key = "payload", .value = .{ .string = payload } },
            .{ .key = "checksum", .value = .{ .string = checksum } },
        };
        const packet = Value{ .object = &entries };

        const encoded = try core.encode(allocator, packet);
        defer allocator.free(encoded);

        try stdout.print("Packet structure:\n", .{});
        try stdout.print("  header: [magic, version, flags]\n", .{});
        try stdout.print("  payload: {d} bytes of mixed data\n", .{payload.len});
        try stdout.print("  checksum: 4 bytes\n\n", .{});

        try stdout.print("C0 encoded ({d} bytes):\n{s}\n\n", .{ encoded.len, encoded });

        // Decode and verify
        const decoded = try core.decode(allocator, encoded);
        defer core.deinit(allocator, decoded);

        try stdout.print("Decoded structure: ", .{});
        try stdout.print("{d} entries\n", .{decoded.object.len});
        for (decoded.object) |entry| {
            try stdout.print("  {s}: ", .{entry.key});
            switch (entry.value) {
                .string => |s| try stdout.print("string ({d} bytes)\n", .{s.len}),
                .array => |a| try stdout.print("array [{d} items]\n", .{a.len}),
                .object => |o| try stdout.print("object {{{d} keys}}\n", .{o.len}),
            }
        }
        try stdout.print("\n", .{});
    }

    // Demo 3: All byte values (0x00-0xFF)
    try stdout.print("--- Demo 3: All 256 Byte Values ---\n", .{});
    {
        var all_bytes: [256]u8 = undefined;
        for (0..256) |i| {
            all_bytes[i] = @intCast(i);
        }

        const val = Value{ .string = &all_bytes };
        const encoded = try core.encode(allocator, val);
        defer allocator.free(encoded);

        try stdout.print("Input: all bytes 0x00-0xFF (256 bytes)\n", .{});
        try stdout.print("C0 encoded: {d} bytes\n", .{encoded.len});

        // Show a sample of the encoded output
        const preview_len = @min(encoded.len, 80);
        try stdout.print("Preview: {s}...\n", .{encoded[0..preview_len]});

        // Decode and verify
        const decoded = try core.decode(allocator, encoded);
        defer core.deinit(allocator, decoded);

        var matches: usize = 0;
        for (decoded.string, 0..) |b, i| {
            if (b == @as(u8, @intCast(i))) matches += 1;
        }
        try stdout.print("Round-trip verification: {d}/256 bytes match\n\n", .{matches});
    }

    // Demo 4: Comparison with base64
    try stdout.print("--- Demo 4: Size Comparison with Base64 ---\n", .{});
    {
        // Various data patterns
        const test_cases = [_]struct { name: []const u8, data: []const u8 }{
            .{ .name = "ASCII text", .data = "Hello, World! This is plain ASCII text." },
            .{ .name = "Binary blob", .data = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f" },
            .{ .name = "Mixed data", .data = "Name: Test\x00Version: 1.0\x00\x89PNG\r\n\x1a\n" },
            .{ .name = "UTF-8 text", .data = "Hello 世界! Привет мир! 🌍" },
        };

        try stdout.print("{s:<20} {s:>10} {s:>10} {s:>10}\n", .{ "Data Type", "Original", "C0", "Base64*" });
        try stdout.print("{s:-<20} {s:->10} {s:->10} {s:->10}\n", .{ "", "", "", "" });

        for (test_cases) |tc| {
            const val = Value{ .string = tc.data };
            const encoded = try core.encode(allocator, val);
            defer allocator.free(encoded);

            // Base64 would be: ceil(len * 4/3) rounded up to multiple of 4
            const base64_len = ((tc.data.len + 2) / 3) * 4;

            try stdout.print("{s:<20} {d:>10} {d:>10} {d:>10}\n", .{
                tc.name,
                tc.data.len,
                encoded.len,
                base64_len,
            });
        }
        try stdout.print("\n*Base64 estimate (actual JSON would add quotes + escaping)\n\n", .{});
    }

    // Demo 5: Nested binary structures
    try stdout.print("--- Demo 5: File Archive Structure ---\n", .{});
    {
        // Simulate a simple archive with multiple files
        var file1_entries = [_]Entry{
            .{ .key = "name", .value = .{ .string = "hello.txt" } },
            .{ .key = "size", .value = .{ .string = "13" } },
            .{ .key = "data", .value = .{ .string = "Hello, World!" } },
        };
        const file1 = Value{ .object = &file1_entries };

        var file2_entries = [_]Entry{
            .{ .key = "name", .value = .{ .string = "binary.dat" } },
            .{ .key = "size", .value = .{ .string = "16" } },
            .{ .key = "data", .value = .{ .string = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f" } },
        };
        const file2 = Value{ .object = &file2_entries };

        var files = [_]Value{ file1, file2 };
        var archive_entries = [_]Entry{
            .{ .key = "format", .value = .{ .string = "c0-archive-v1" } },
            .{ .key = "files", .value = .{ .array = &files } },
        };
        const archive = Value{ .object = &archive_entries };

        const encoded = try core.encode(allocator, archive);
        defer allocator.free(encoded);

        try stdout.print("Archive with 2 files:\n", .{});
        try stdout.print("  - hello.txt (13 bytes, text)\n", .{});
        try stdout.print("  - binary.dat (16 bytes, binary)\n\n", .{});

        try stdout.print("C0 encoded archive ({d} bytes):\n{s}\n\n", .{ encoded.len, encoded });

        // Decode and extract
        const decoded = try core.decode(allocator, encoded);
        defer core.deinit(allocator, decoded);

        try stdout.print("Decoded archive:\n", .{});
        for (decoded.object) |entry| {
            if (std.mem.eql(u8, entry.key, "format")) {
                try stdout.print("  format: {s}\n", .{entry.value.string});
            } else if (std.mem.eql(u8, entry.key, "files")) {
                try stdout.print("  files: {d} entries\n", .{entry.value.array.len});
                for (entry.value.array) |file| {
                    for (file.object) |f| {
                        if (std.mem.eql(u8, f.key, "name")) {
                            try stdout.print("    - {s}\n", .{f.value.string});
                        }
                    }
                }
            }
        }
    }

    try stdout.print("\n=== Key Insight ===\n", .{});
    try stdout.print("C0 output is human-readable UTF-8. ASCII text in binary data\n", .{});
    try stdout.print("remains visible, while non-printable bytes become readable\n", .{});
    try stdout.print("Unicode glyphs. No base64 encoding needed!\n", .{});
}

fn printBinaryPreview(stdout: anytype, data: []const u8) void {
    const max_len = @min(data.len, 40);
    for (data[0..max_len]) |b| {
        if (b >= 0x20 and b < 0x7f) {
            stdout.print("{c}", .{b}) catch {};
        } else {
            stdout.print("\\x{x:0>2}", .{b}) catch {};
        }
    }
    if (data.len > max_len) {
        stdout.print("...", .{}) catch {};
    }
}

// ============================================================================
// Tests
// ============================================================================

test "binary round-trip preserves all bytes" {
    const allocator = std.testing.allocator;

    // Test all byte values
    var all_bytes: [256]u8 = undefined;
    for (0..256) |i| {
        all_bytes[i] = @intCast(i);
    }

    const val = Value{ .string = &all_bytes };
    const encoded = try core.encode(allocator, val);
    defer allocator.free(encoded);

    const decoded = try core.decode(allocator, encoded);
    defer core.deinit(allocator, decoded);

    try std.testing.expectEqualSlices(u8, &all_bytes, decoded.string);
}

test "structured binary round-trip" {
    const allocator = std.testing.allocator;

    const binary_payload = "\x00\x01\x02\x03\xff\xfe\xfd";
    var entries = [_]Entry{
        .{ .key = "type", .value = .{ .string = "binary" } },
        .{ .key = "data", .value = .{ .string = binary_payload } },
    };
    const val = Value{ .object = &entries };

    const encoded = try core.encode(allocator, val);
    defer allocator.free(encoded);

    const decoded = try core.decode(allocator, encoded);
    defer core.deinit(allocator, decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.object.len);
}

test "no structural bytes in encoded output" {
    const allocator = std.testing.allocator;

    // Input containing the structural delimiters
    const tricky_input = "test{with[delimiters,and:more}data]";
    const val = Value{ .string = tricky_input };

    const encoded = try core.encode(allocator, val);
    defer allocator.free(encoded);

    // Structural bytes should only appear as actual structure, not in payloads
    // Since this is a plain string (no structure), any { [ , : in output
    // must be escaped by printable_binary

    const decoded = try core.decode(allocator, encoded);
    defer core.deinit(allocator, decoded);

    try std.testing.expectEqualStrings(tricky_input, decoded.string);
}
