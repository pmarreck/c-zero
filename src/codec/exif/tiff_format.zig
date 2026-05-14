//! TIFF Format Codec
//!
//! Thin wrapper around ifd.zig for standalone TIFF files.
//! Adds the {format:tiff, ...} envelope for the codec system.

const std = @import("std");
const core = @import("c0_core");
const codec = @import("../mod.zig");
const ifd = @import("ifd.zig");

const Value = core.Value;
const Entry = core.Entry;
const CodecOptions = codec.CodecOptions;
const CodecError = codec.CodecError;

/// Expand a TIFF file into C0 Value.
/// Output: {format:tiff, byte_order:II/MM, ifd0:{...}, ifd1:{...}, _raw:<pb>}
pub fn expandTiff(allocator: std.mem.Allocator, data: []const u8, options: CodecOptions) CodecError!Value {
    // Parse the TIFF IFD structure
    const tiff_value = try ifd.expandTiffData(allocator, data);
    const tiff_entries = tiff_value.object;

    // Build output: prepend format field, optionally add _raw
    var entry_count: usize = 1 + tiff_entries.len; // +1 for format
    if (options.faithful) entry_count += 1; // +1 for _raw

    const result = allocator.alloc(Entry, entry_count) catch return CodecError.OutOfMemory;
    var idx: usize = 0;

    result[idx] = .{ .key = "format", .value = .{ .string = "tiff" } };
    idx += 1;

    // Copy all TIFF entries (byte_order, ifd0, ifd1, ...)
    for (tiff_entries) |entry| {
        result[idx] = entry;
        idx += 1;
    }

    // In faithful mode, store raw bytes for bit-perfect round-trip
    if (options.faithful) {
        result[idx] = .{ .key = "_raw", .value = .{ .string = data } };
        idx += 1;
    }

    return Value{ .object = result };
}

/// Collapse a C0 Value back to TIFF binary.
pub fn collapseTiff(allocator: std.mem.Allocator, value: Value, options: CodecOptions) CodecError![]u8 {
    const entries = switch (value) {
        .object => |e| e,
        else => return CodecError.InvalidFormat,
    };

    // In faithful mode, use _raw if available
    if (options.faithful) {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.key, "_raw")) {
                const raw = switch (entry.value) {
                    .string => |s| s,
                    else => return CodecError.InvalidFormat,
                };
                return allocator.dupe(u8, raw) catch return CodecError.OutOfMemory;
            }
        }
    }

    // Editable mode: rebuild from parsed structure
    // Strip the "format" and "_raw" fields, pass the rest to collapseTiffData
    var tiff_entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer tiff_entries.deinit(allocator);

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, "format")) continue;
        if (std.mem.eql(u8, entry.key, "_raw")) continue;
        tiff_entries.append(allocator, entry) catch return CodecError.OutOfMemory;
    }

    const tiff_value = Value{ .object = tiff_entries.toOwnedSlice(allocator) catch return CodecError.OutOfMemory };
    return ifd.collapseTiffData(allocator, tiff_value);
}

// ============================================================================
// Tests
// ============================================================================

test "TIFF expand adds format field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tiff_data = try ifd.buildTestTiff(allocator);
    const value = try expandTiff(allocator, tiff_data, .{ .faithful = false });

    try std.testing.expectEqualStrings("format", value.object[0].key);
    try std.testing.expectEqualStrings("tiff", value.object[0].value.string);
    try std.testing.expectEqualStrings("byte_order", value.object[1].key);
}

test "TIFF faithful includes _raw" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tiff_data = try ifd.buildTestTiff(allocator);
    const value = try expandTiff(allocator, tiff_data, .{ .faithful = true });

    // Last entry should be _raw
    const last = value.object[value.object.len - 1];
    try std.testing.expectEqualStrings("_raw", last.key);
}

test "TIFF faithful round-trip is bit-perfect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const original = try ifd.buildTestTiff(allocator);
    const value = try expandTiff(allocator, original, .{ .faithful = true });
    const collapsed = try collapseTiff(allocator, value, .{ .faithful = true });

    try std.testing.expectEqualSlices(u8, original, collapsed);
}

test "TIFF editable round-trip preserves data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const original = try ifd.buildTestTiff(allocator);
    const value = try expandTiff(allocator, original, .{ .faithful = false });
    const collapsed = try collapseTiff(allocator, value, .{ .faithful = false });

    // Re-expand to verify semantic equivalence
    const value2 = try expandTiff(allocator, collapsed, .{ .faithful = false });
    const ifd0 = value2.object[2].value; // format, byte_order, ifd0
    try std.testing.expectEqualStrings("Make", ifd0.object[0].key);
    try std.testing.expectEqualStrings("Canon", ifd0.object[0].value.string);
}
