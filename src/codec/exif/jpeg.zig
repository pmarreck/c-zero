//! JPEG Codec - Destructures JPEG files with EXIF metadata parsing
//!
//! Segments are parsed individually. APP1 segments with "Exif\0\0" prefix
//! get their TIFF IFD structure fully parsed. SOS (Start of Scan) segments
//! capture the entropy-coded data as a binary blob.
//!
//! C0 output structure:
//!   {format:jpeg, segments:[{marker:SOI}, {marker:APP1, type:exif, exif:{...}}, ...]}

const std = @import("std");
const core = @import("c0_core");
const codec = @import("../mod.zig");
const ifd = @import("ifd.zig");

const Value = core.Value;
const Entry = core.Entry;
const CodecOptions = codec.CodecOptions;
const CodecError = codec.CodecError;

// ============================================================================
// JPEG Marker Names
// ============================================================================

fn markerName(byte: u8) []const u8 {
    return switch (byte) {
        0xC0 => "SOF0",
        0xC1 => "SOF1",
        0xC2 => "SOF2",
        0xC3 => "SOF3",
        0xC4 => "DHT",
        0xC5 => "SOF5",
        0xC6 => "SOF6",
        0xC7 => "SOF7",
        0xC8 => "JPG",
        0xC9 => "SOF9",
        0xCA => "SOF10",
        0xCB => "SOF11",
        0xCC => "DAC",
        0xCD => "SOF13",
        0xCE => "SOF14",
        0xCF => "SOF15",
        0xD0 => "RST0",
        0xD1 => "RST1",
        0xD2 => "RST2",
        0xD3 => "RST3",
        0xD4 => "RST4",
        0xD5 => "RST5",
        0xD6 => "RST6",
        0xD7 => "RST7",
        0xD8 => "SOI",
        0xD9 => "EOI",
        0xDA => "SOS",
        0xDB => "DQT",
        0xDC => "DNL",
        0xDD => "DRI",
        0xDE => "DHP",
        0xDF => "EXP",
        0xE0 => "APP0",
        0xE1 => "APP1",
        0xE2 => "APP2",
        0xE3 => "APP3",
        0xE4 => "APP4",
        0xE5 => "APP5",
        0xE6 => "APP6",
        0xE7 => "APP7",
        0xE8 => "APP8",
        0xE9 => "APP9",
        0xEA => "APP10",
        0xEB => "APP11",
        0xEC => "APP12",
        0xED => "APP13",
        0xEE => "APP14",
        0xEF => "APP15",
        0xFE => "COM",
        else => "unknown",
    };
}

fn markerByte(name: []const u8) ?u8 {
    const pairs = .{
        .{ "SOF0", 0xC0 },  .{ "SOF1", 0xC1 },  .{ "SOF2", 0xC2 },
        .{ "SOF3", 0xC3 },  .{ "DHT", 0xC4 },   .{ "SOF5", 0xC5 },
        .{ "SOF6", 0xC6 },  .{ "SOF7", 0xC7 },   .{ "JPG", 0xC8 },
        .{ "SOF9", 0xC9 },  .{ "SOF10", 0xCA },  .{ "SOF11", 0xCB },
        .{ "DAC", 0xCC },   .{ "SOF13", 0xCD },  .{ "SOF14", 0xCE },
        .{ "SOF15", 0xCF }, .{ "RST0", 0xD0 },   .{ "RST1", 0xD1 },
        .{ "RST2", 0xD2 },  .{ "RST3", 0xD3 },   .{ "RST4", 0xD4 },
        .{ "RST5", 0xD5 },  .{ "RST6", 0xD6 },   .{ "RST7", 0xD7 },
        .{ "SOI", 0xD8 },   .{ "EOI", 0xD9 },    .{ "SOS", 0xDA },
        .{ "DQT", 0xDB },   .{ "DNL", 0xDC },    .{ "DRI", 0xDD },
        .{ "DHP", 0xDE },   .{ "EXP", 0xDF },     .{ "APP0", 0xE0 },
        .{ "APP1", 0xE1 },  .{ "APP2", 0xE2 },   .{ "APP3", 0xE3 },
        .{ "APP4", 0xE4 },  .{ "APP5", 0xE5 },   .{ "APP6", 0xE6 },
        .{ "APP7", 0xE7 },  .{ "APP8", 0xE8 },   .{ "APP9", 0xE9 },
        .{ "APP10", 0xEA }, .{ "APP11", 0xEB },   .{ "APP12", 0xEC },
        .{ "APP13", 0xED }, .{ "APP14", 0xEE },   .{ "APP15", 0xEF },
        .{ "COM", 0xFE },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return null;
}

/// Returns true for standalone markers (no length field).
fn isStandaloneMarker(marker: u8) bool {
    return marker == 0xD8 or marker == 0xD9 or // SOI, EOI
        (marker >= 0xD0 and marker <= 0xD7); // RST0-RST7
}

// ============================================================================
// Expand: JPEG binary -> C0 Value
// ============================================================================

pub fn expandJpeg(allocator: std.mem.Allocator, data: []const u8, options: CodecOptions) CodecError!Value {
    if (data.len < 2 or data[0] != 0xFF or data[1] != 0xD8) return CodecError.InvalidMagic;

    var segments: std.ArrayListUnmanaged(Value) = .{};
    defer segments.deinit(allocator);

    // SOI
    segments.append(allocator, try makeMarkerOnly(allocator, "SOI")) catch return CodecError.OutOfMemory;

    var pos: usize = 2;

    while (pos + 1 < data.len) {
        // Expect 0xFF
        if (data[pos] != 0xFF) return CodecError.InvalidFormat;
        pos += 1;

        // Skip fill bytes (consecutive 0xFF)
        while (pos < data.len and data[pos] == 0xFF) pos += 1;
        if (pos >= data.len) return CodecError.TruncatedInput;

        const marker = data[pos];
        pos += 1;

        // EOI
        if (marker == 0xD9) {
            segments.append(allocator, try makeMarkerOnly(allocator, "EOI")) catch return CodecError.OutOfMemory;
            break;
        }

        // RST markers (standalone, no length)
        if (marker >= 0xD0 and marker <= 0xD7) {
            segments.append(allocator, try makeMarkerOnly(allocator, markerName(marker))) catch return CodecError.OutOfMemory;
            continue;
        }

        // All other markers have a 2-byte length field
        if (pos + 2 > data.len) return CodecError.TruncatedInput;
        const length = std.mem.readInt(u16, data[pos..][0..2], .big);
        if (length < 2) return CodecError.InvalidFormat;
        if (pos + length > data.len) return CodecError.TruncatedInput;

        const payload = data[pos + 2 .. pos + length]; // length includes the 2 length bytes

        // SOS: header + entropy-coded scan data
        if (marker == 0xDA) {
            pos += length; // advance past SOS header

            // Scan for end of entropy-coded data
            const scan_start = pos;
            while (pos < data.len) {
                if (data[pos] != 0xFF) {
                    pos += 1;
                    continue;
                }
                // Found 0xFF
                if (pos + 1 >= data.len) {
                    pos += 1;
                    break;
                }
                const next = data[pos + 1];
                if (next == 0x00) {
                    // Byte stuffing — skip
                    pos += 2;
                } else if (next >= 0xD0 and next <= 0xD7) {
                    // RST marker within scan data — skip
                    pos += 2;
                } else if (next == 0xFF) {
                    // Fill byte
                    pos += 1;
                } else {
                    // Found next marker — stop here
                    break;
                }
            }

            const scan_data = data[scan_start..pos];
            segments.append(allocator, try makeSosSegment(allocator, payload, scan_data)) catch return CodecError.OutOfMemory;
            continue;
        }

        // APP1 with EXIF detection
        if (marker == 0xE1 and payload.len >= 6 and std.mem.eql(u8, payload[0..6], "Exif\x00\x00")) {
            const tiff_data = payload[6..];
            segments.append(
                allocator,
                try makeExifSegment(allocator, tiff_data, options),
            ) catch return CodecError.OutOfMemory;
            pos += length;
            continue;
        }

        // Regular segment
        segments.append(
            allocator,
            try makeDataSegment(allocator, markerName(marker), payload),
        ) catch return CodecError.OutOfMemory;
        pos += length;
    }

    // Build top-level: {format:jpeg, segments:[...]}
    const top = allocator.alloc(Entry, 2) catch return CodecError.OutOfMemory;
    top[0] = .{ .key = "format", .value = .{ .string = "jpeg" } };
    top[1] = .{ .key = "segments", .value = .{
        .array = segments.toOwnedSlice(allocator) catch return CodecError.OutOfMemory,
    } };
    return Value{ .object = top };
}

// ============================================================================
// Segment builders
// ============================================================================

fn makeMarkerOnly(allocator: std.mem.Allocator, name: []const u8) CodecError!Value {
    const entries = allocator.alloc(Entry, 1) catch return CodecError.OutOfMemory;
    entries[0] = .{ .key = "marker", .value = .{ .string = name } };
    return Value{ .object = entries };
}

fn makeDataSegment(allocator: std.mem.Allocator, name: []const u8, data: []const u8) CodecError!Value {
    const entries = allocator.alloc(Entry, 2) catch return CodecError.OutOfMemory;
    entries[0] = .{ .key = "marker", .value = .{ .string = name } };
    entries[1] = .{ .key = "data", .value = .{ .string = data } };
    return Value{ .object = entries };
}

fn makeSosSegment(allocator: std.mem.Allocator, header: []const u8, scan_data: []const u8) CodecError!Value {
    const entries = allocator.alloc(Entry, 3) catch return CodecError.OutOfMemory;
    entries[0] = .{ .key = "marker", .value = .{ .string = "SOS" } };
    entries[1] = .{ .key = "header", .value = .{ .string = header } };
    entries[2] = .{ .key = "data", .value = .{ .string = scan_data } };
    return Value{ .object = entries };
}

fn makeExifSegment(allocator: std.mem.Allocator, tiff_data: []const u8, options: CodecOptions) CodecError!Value {
    // Try to parse the TIFF/EXIF data
    const exif_value = ifd.expandTiffData(allocator, tiff_data) catch {
        // Parse failed — fall back to raw data
        const entries = allocator.alloc(Entry, 2) catch return CodecError.OutOfMemory;
        entries[0] = .{ .key = "marker", .value = .{ .string = "APP1" } };
        entries[1] = .{ .key = "data", .value = .{ .string = tiff_data } };
        return Value{ .object = entries };
    };

    var entry_count: usize = 3; // marker, type, exif
    if (options.faithful) entry_count += 1; // _raw

    const entries = allocator.alloc(Entry, entry_count) catch return CodecError.OutOfMemory;
    var idx: usize = 0;

    entries[idx] = .{ .key = "marker", .value = .{ .string = "APP1" } };
    idx += 1;
    entries[idx] = .{ .key = "type", .value = .{ .string = "exif" } };
    idx += 1;
    entries[idx] = .{ .key = "exif", .value = exif_value };
    idx += 1;

    if (options.faithful) {
        entries[idx] = .{ .key = "_raw", .value = .{ .string = tiff_data } };
        idx += 1;
    }

    return Value{ .object = entries };
}

// ============================================================================
// Collapse: C0 Value -> JPEG binary
// ============================================================================

pub fn collapseJpeg(allocator: std.mem.Allocator, value: Value, options: CodecOptions) CodecError![]u8 {
    const top_entries = switch (value) {
        .object => |e| e,
        else => return CodecError.InvalidFormat,
    };

    var segments: ?[]const Value = null;
    for (top_entries) |entry| {
        if (std.mem.eql(u8, entry.key, "segments")) {
            segments = switch (entry.value) {
                .array => |a| a,
                else => return CodecError.InvalidFormat,
            };
        }
    }
    const segs = segments orelse return CodecError.InvalidFormat;

    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);

    for (segs) |seg_val| {
        const seg = switch (seg_val) {
            .object => |e| e,
            else => return CodecError.InvalidFormat,
        };

        var marker_name: ?[]const u8 = null;
        var seg_data: ?[]const u8 = null;
        var header: ?[]const u8 = null;
        var seg_type: ?[]const u8 = null;
        var exif_val: ?Value = null;
        var raw: ?[]const u8 = null;

        for (seg) |entry| {
            if (std.mem.eql(u8, entry.key, "marker")) {
                marker_name = switch (entry.value) {
                    .string => |s| s,
                    else => return CodecError.InvalidFormat,
                };
            } else if (std.mem.eql(u8, entry.key, "data")) {
                seg_data = switch (entry.value) {
                    .string => |s| s,
                    else => return CodecError.InvalidFormat,
                };
            } else if (std.mem.eql(u8, entry.key, "header")) {
                header = switch (entry.value) {
                    .string => |s| s,
                    else => return CodecError.InvalidFormat,
                };
            } else if (std.mem.eql(u8, entry.key, "type")) {
                seg_type = switch (entry.value) {
                    .string => |s| s,
                    else => return CodecError.InvalidFormat,
                };
            } else if (std.mem.eql(u8, entry.key, "exif")) {
                exif_val = entry.value;
            } else if (std.mem.eql(u8, entry.key, "_raw")) {
                raw = switch (entry.value) {
                    .string => |s| s,
                    else => return CodecError.InvalidFormat,
                };
            }
        }

        const name = marker_name orelse return CodecError.InvalidFormat;
        const marker_byte_val = markerByte(name) orelse return CodecError.InvalidFormat;

        // Standalone markers (SOI, EOI, RST0-RST7)
        if (isStandaloneMarker(marker_byte_val)) {
            buf.appendSlice(allocator, &.{ 0xFF, marker_byte_val }) catch return CodecError.OutOfMemory;
            continue;
        }

        // SOS: header + scan data
        if (marker_byte_val == 0xDA) {
            const hdr = header orelse return CodecError.InvalidFormat;
            const scan = seg_data orelse return CodecError.InvalidFormat;

            buf.appendSlice(allocator, &.{ 0xFF, 0xDA }) catch return CodecError.OutOfMemory;

            // Write length (header + 2 for the length field itself)
            var len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_buf, @intCast(hdr.len + 2), .big);
            buf.appendSlice(allocator, &len_buf) catch return CodecError.OutOfMemory;

            buf.appendSlice(allocator, hdr) catch return CodecError.OutOfMemory;
            buf.appendSlice(allocator, scan) catch return CodecError.OutOfMemory;
            continue;
        }

        // APP1 EXIF
        if (marker_byte_val == 0xE1 and seg_type != null and std.mem.eql(u8, seg_type.?, "exif")) {
            const tiff_bytes: []const u8 = blk: {
                if (options.faithful) {
                    if (raw) |r| {
                        break :blk r;
                    }
                }
                if (exif_val) |ev| {
                    break :blk try ifd.collapseTiffData(allocator, ev);
                }
                return CodecError.InvalidFormat;
            };

            buf.appendSlice(allocator, &.{ 0xFF, 0xE1 }) catch return CodecError.OutOfMemory;

            // Length = 2 (length field) + 6 (Exif\0\0) + TIFF data
            const total_len: u16 = @intCast(2 + 6 + tiff_bytes.len);
            var len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_buf, total_len, .big);
            buf.appendSlice(allocator, &len_buf) catch return CodecError.OutOfMemory;

            buf.appendSlice(allocator, "Exif\x00\x00") catch return CodecError.OutOfMemory;
            buf.appendSlice(allocator, tiff_bytes) catch return CodecError.OutOfMemory;
            continue;
        }

        // Regular segment with data
        const d = seg_data orelse return CodecError.InvalidFormat;
        buf.appendSlice(allocator, &.{ 0xFF, marker_byte_val }) catch return CodecError.OutOfMemory;

        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(d.len + 2), .big);
        buf.appendSlice(allocator, &len_buf) catch return CodecError.OutOfMemory;

        buf.appendSlice(allocator, d) catch return CodecError.OutOfMemory;
    }

    return buf.toOwnedSlice(allocator) catch return CodecError.OutOfMemory;
}

// ============================================================================
// Tests
// ============================================================================

/// Build a minimal JPEG with EXIF APP1 segment for testing.
pub fn buildTestJpeg(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);

    // SOI
    try buf.appendSlice(allocator, &.{ 0xFF, 0xD8 });

    // APP1 with EXIF
    const tiff_data = try ifd.buildTestTiff(allocator);
    const app1_len: u16 = @intCast(2 + 6 + tiff_data.len);

    try buf.appendSlice(allocator, &.{ 0xFF, 0xE1 });
    var len_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &len_buf, app1_len, .big);
    try buf.appendSlice(allocator, &len_buf);
    try buf.appendSlice(allocator, "Exif\x00\x00");
    try buf.appendSlice(allocator, tiff_data);

    // DQT segment with some data
    try buf.appendSlice(allocator, &.{ 0xFF, 0xDB });
    std.mem.writeInt(u16, &len_buf, 5, .big); // length = 2 + 3 bytes of data
    try buf.appendSlice(allocator, &len_buf);
    try buf.appendSlice(allocator, &.{ 0x00, 0x01, 0x02 });

    // EOI
    try buf.appendSlice(allocator, &.{ 0xFF, 0xD9 });

    return buf.toOwnedSlice(allocator);
}

test "JPEG expand parses segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const jpeg_data = try buildTestJpeg(allocator);
    const value = try expandJpeg(allocator, jpeg_data, .{ .faithful = false });

    // Check format
    try std.testing.expectEqualStrings("format", value.object[0].key);
    try std.testing.expectEqualStrings("jpeg", value.object[0].value.string);

    // Check segments
    const segments = value.object[1].value.array;
    try std.testing.expect(segments.len >= 4); // SOI, APP1, DQT, EOI

    // SOI
    try std.testing.expectEqualStrings("SOI", segments[0].object[0].value.string);

    // APP1 EXIF
    try std.testing.expectEqualStrings("APP1", segments[1].object[0].value.string);
    try std.testing.expectEqualStrings("exif", segments[1].object[1].value.string);

    // DQT
    try std.testing.expectEqualStrings("DQT", segments[2].object[0].value.string);

    // EOI
    try std.testing.expectEqualStrings("EOI", segments[3].object[0].value.string);
}

test "JPEG expand parses EXIF data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const jpeg_data = try buildTestJpeg(allocator);
    const value = try expandJpeg(allocator, jpeg_data, .{ .faithful = false });

    const segments = value.object[1].value.array;
    const app1 = segments[1];

    // Find exif field
    var exif_val: ?Value = null;
    for (app1.object) |entry| {
        if (std.mem.eql(u8, entry.key, "exif")) {
            exif_val = entry.value;
        }
    }
    const exif = exif_val orelse return error.InvalidFormat;

    // Check EXIF structure
    const ifd0 = blk: {
        for (exif.object) |entry| {
            if (std.mem.eql(u8, entry.key, "ifd0")) break :blk entry.value;
        }
        return error.InvalidFormat;
    };

    try std.testing.expectEqualStrings("Make", ifd0.object[0].key);
    try std.testing.expectEqualStrings("Canon", ifd0.object[0].value.string);
}

test "JPEG faithful round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const original = try buildTestJpeg(allocator);
    const value = try expandJpeg(allocator, original, .{ .faithful = true });
    const collapsed = try collapseJpeg(allocator, value, .{ .faithful = true });

    try std.testing.expectEqualSlices(u8, original, collapsed);
}

test "JPEG editable round-trip preserves data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const original = try buildTestJpeg(allocator);
    const value = try expandJpeg(allocator, original, .{ .faithful = false });
    const collapsed = try collapseJpeg(allocator, value, .{ .faithful = false });

    // Re-expand and verify EXIF data is preserved
    const value2 = try expandJpeg(allocator, collapsed, .{ .faithful = false });
    const segments = value2.object[1].value.array;

    // Find EXIF data
    var exif_found = false;
    for (segments) |seg| {
        for (seg.object) |entry| {
            if (std.mem.eql(u8, entry.key, "exif")) {
                const exif = entry.value;
                for (exif.object) |e| {
                    if (std.mem.eql(u8, e.key, "ifd0")) {
                        const ifd0 = e.value;
                        try std.testing.expectEqualStrings("Canon", ifd0.object[0].value.string);
                        exif_found = true;
                    }
                }
            }
        }
    }
    try std.testing.expect(exif_found);
}

test "JPEG rejects non-JPEG data" {
    const result = expandJpeg(std.testing.allocator, "not a jpeg", .{});
    try std.testing.expectError(CodecError.InvalidMagic, result);
}

test "JPEG with SOS segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buf: std.ArrayListUnmanaged(u8) = .{};

    // SOI
    try buf.appendSlice(allocator, &.{ 0xFF, 0xD8 });

    // SOS with minimal header and scan data
    try buf.appendSlice(allocator, &.{ 0xFF, 0xDA });
    var len_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &len_buf, 4, .big); // length = 2 + 2 bytes header
    try buf.appendSlice(allocator, &len_buf);
    try buf.appendSlice(allocator, &.{ 0x01, 0x00 }); // header payload

    // Scan data: some bytes with byte stuffing
    try buf.appendSlice(allocator, &.{ 0xAA, 0xBB, 0xFF, 0x00, 0xCC }); // FF 00 = stuffed FF

    // EOI (terminates scan data)
    try buf.appendSlice(allocator, &.{ 0xFF, 0xD9 });

    const jpeg_data = try buf.toOwnedSlice(allocator);
    const value = try expandJpeg(allocator, jpeg_data, .{ .faithful = true });
    const collapsed = try collapseJpeg(allocator, value, .{ .faithful = true });

    try std.testing.expectEqualSlices(u8, jpeg_data, collapsed);
}
