//! TIFF IFD Parser and Serializer
//!
//! Parses TIFF Image File Directory structures into C0 Values and back.
//! Handles byte-order-aware reading/writing, sub-IFD recursion, and
//! type conversion (ASCII, SHORT, LONG, RATIONAL, UNDEFINED, etc.).

const std = @import("std");
const core = @import("c0_core");
const codec = @import("../mod.zig");
const tags = @import("tags.zig");

const Value = core.Value;
const Entry = core.Entry;
const CodecError = codec.CodecError;
const TiffType = tags.TiffType;
const IfdContext = tags.IfdContext;

/// TIFF byte order
pub const ByteOrder = enum {
    little, // "II" (Intel)
    big, // "MM" (Motorola)
};

// ============================================================================
// Byte-order-aware read/write helpers
// ============================================================================

fn readU16(data: []const u8, offset: usize, order: ByteOrder) CodecError!u16 {
    if (offset + 2 > data.len) return CodecError.TruncatedInput;
    return std.mem.readInt(u16, data[offset..][0..2], if (order == .little) .little else .big);
}

fn readU32(data: []const u8, offset: usize, order: ByteOrder) CodecError!u32 {
    if (offset + 4 > data.len) return CodecError.TruncatedInput;
    return std.mem.readInt(u32, data[offset..][0..4], if (order == .little) .little else .big);
}

fn readI32(data: []const u8, offset: usize, order: ByteOrder) CodecError!i32 {
    if (offset + 4 > data.len) return CodecError.TruncatedInput;
    return std.mem.readInt(i32, data[offset..][0..4], if (order == .little) .little else .big);
}

fn endian(order: ByteOrder) std.builtin.Endian {
    return if (order == .little) .little else .big;
}

fn appendU16(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, order: ByteOrder, val: u16) CodecError!void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, val, endian(order));
    buf.appendSlice(allocator, &bytes) catch return CodecError.OutOfMemory;
}

fn appendU32(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, order: ByteOrder, val: u32) CodecError!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, val, endian(order));
    buf.appendSlice(allocator, &bytes) catch return CodecError.OutOfMemory;
}

fn patchU32(buf: *std.ArrayListUnmanaged(u8), pos: usize, order: ByteOrder, val: u32) void {
    std.mem.writeInt(u32, buf.items[pos..][0..4], val, endian(order));
}

// ============================================================================
// Expand: TIFF binary -> C0 Value
// ============================================================================

/// Parse TIFF data into a C0 Value representing the IFD structure.
/// Returns: {byte_order:II/MM, ifd0:{...}, ifd1:{...}}
pub fn expandTiffData(allocator: std.mem.Allocator, data: []const u8) CodecError!Value {
    if (data.len < 8) return CodecError.TruncatedInput;

    // Read byte order
    const order: ByteOrder = if (std.mem.eql(u8, data[0..2], "II"))
        .little
    else if (std.mem.eql(u8, data[0..2], "MM"))
        .big
    else
        return CodecError.InvalidMagic;

    // Validate magic number 42
    const magic = try readU16(data, 2, order);
    if (magic != 42) return CodecError.InvalidMagic;

    // Read offset to first IFD
    const ifd0_offset = try readU32(data, 4, order);
    if (ifd0_offset == 0) return CodecError.InvalidFormat;

    // Build result entries
    var result_entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer result_entries.deinit(allocator);

    // byte_order field
    const bo_str = if (order == .little) "II" else "MM";
    result_entries.append(allocator, .{
        .key = "byte_order",
        .value = .{ .string = bo_str },
    }) catch return CodecError.OutOfMemory;

    // Parse IFD0
    const ifd0_result = try expandIfd(allocator, data, ifd0_offset, .ifd0, order);
    result_entries.append(allocator, .{
        .key = "ifd0",
        .value = ifd0_result.value,
    }) catch return CodecError.OutOfMemory;

    // Parse IFD1 if present
    if (ifd0_result.next_ifd_offset != 0 and ifd0_result.next_ifd_offset < data.len) {
        const ifd1_result = try expandIfd(allocator, data, ifd0_result.next_ifd_offset, .ifd0, order);
        result_entries.append(allocator, .{
            .key = "ifd1",
            .value = ifd1_result.value,
        }) catch return CodecError.OutOfMemory;
    }

    const entries_owned = result_entries.toOwnedSlice(allocator) catch return CodecError.OutOfMemory;
    return Value{ .object = entries_owned };
}

const IfdResult = struct {
    value: Value,
    next_ifd_offset: u32,
};

/// Parse a single IFD at the given offset.
fn expandIfd(
    allocator: std.mem.Allocator,
    data: []const u8,
    ifd_offset: u32,
    context: IfdContext,
    order: ByteOrder,
) CodecError!IfdResult {
    const offset: usize = ifd_offset;
    if (offset + 2 > data.len) return CodecError.TruncatedInput;

    const entry_count = try readU16(data, offset, order);
    const entries_end = offset + 2 + @as(usize, entry_count) * 12;
    if (entries_end + 4 > data.len) return CodecError.TruncatedInput;

    var result_entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer result_entries.deinit(allocator);

    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        const entry_offset = offset + 2 + i * 12;
        const tag_id = try readU16(data, entry_offset, order);
        const type_id = try readU16(data, entry_offset + 2, order);
        const count = try readU32(data, entry_offset + 4, order);
        const value_offset_bytes = data[entry_offset + 8 .. entry_offset + 12];

        const tiff_type = TiffType.fromInt(type_id);

        // Check for sub-IFD pointer
        if (tags.isSubIfdTag(tag_id)) {
            const sub_offset = try readU32(data, entry_offset + 8, order);
            const sub_context = tags.subIfdContext(tag_id) orelse .ifd0;
            const sub_name = tags.subIfdTagName(tag_id) orelse "unknown_sub_ifd";

            if (sub_offset > 0 and sub_offset < data.len) {
                const sub_result = try expandIfd(allocator, data, sub_offset, sub_context, order);
                result_entries.append(allocator, .{
                    .key = sub_name,
                    .value = sub_result.value,
                }) catch return CodecError.OutOfMemory;
            }
            continue;
        }

        // Determine tag name
        const key_name = blk: {
            if (tags.tagName(context, tag_id)) |name| {
                break :blk name;
            }
            // Format unknown tag
            var tag_buf: [8]u8 = undefined;
            const formatted = tags.formatUnknownTag(&tag_buf, tag_id);
            break :blk allocator.dupe(u8, formatted) catch return CodecError.OutOfMemory;
        };

        // Calculate value location
        const value_data = blk: {
            if (tiff_type) |tt| {
                const total_size: usize = @as(usize, count) * @as(usize, tt.size());
                if (total_size <= 4) {
                    // Inline value
                    break :blk value_offset_bytes[0..@min(total_size, 4)];
                } else {
                    // Offset to value data
                    const val_offset = try readU32(data, entry_offset + 8, order);
                    if (@as(usize, val_offset) + total_size > data.len) return CodecError.TruncatedInput;
                    break :blk data[val_offset .. val_offset + total_size];
                }
            } else {
                // Unknown type — treat as opaque bytes
                const val_offset = try readU32(data, entry_offset + 8, order);
                if (val_offset < data.len) {
                    const remaining = data.len - val_offset;
                    const size = @min(remaining, @as(usize, count));
                    break :blk data[val_offset .. val_offset + size];
                }
                break :blk value_offset_bytes[0..4];
            }
        };

        // Convert value based on type
        const c0_value = try convertToC0Value(allocator, tiff_type, count, value_data, order);

        result_entries.append(allocator, .{
            .key = key_name,
            .value = c0_value,
        }) catch return CodecError.OutOfMemory;
    }

    // Read next IFD offset
    const next_ifd_offset = try readU32(data, entries_end, order);

    const entries_owned = result_entries.toOwnedSlice(allocator) catch return CodecError.OutOfMemory;
    return .{
        .value = Value{ .object = entries_owned },
        .next_ifd_offset = next_ifd_offset,
    };
}

/// Convert raw TIFF value bytes to a C0 Value based on the TIFF type.
fn convertToC0Value(
    allocator: std.mem.Allocator,
    tiff_type: ?TiffType,
    count: u32,
    data: []const u8,
    order: ByteOrder,
) CodecError!Value {
    const tt = tiff_type orelse {
        // Unknown type: return as binary
        return Value{ .string = data };
    };

    switch (tt) {
        .ascii => {
            // Strip trailing null terminators
            var len = data.len;
            while (len > 0 and data[len - 1] == 0) len -= 1;
            return Value{ .string = data[0..len] };
        },
        .byte => {
            if (count == 1) {
                return Value{ .string = try formatUint(allocator, data[0]) };
            }
            return try formatUintArray(allocator, u8, data, count);
        },
        .short => {
            if (count == 1) {
                const val = std.mem.readInt(u16, data[0..2], endian(order));
                return Value{ .string = try formatUint(allocator, val) };
            }
            return try formatShortArray(allocator, data, count, order);
        },
        .long => {
            if (count == 1) {
                const val = std.mem.readInt(u32, data[0..4], endian(order));
                return Value{ .string = try formatUint(allocator, val) };
            }
            return try formatLongArray(allocator, data, count, order);
        },
        .rational => {
            if (count == 1) {
                return try makeRational(allocator, data, order, false);
            }
            return try formatRationalArray(allocator, data, count, order, false);
        },
        .srational => {
            if (count == 1) {
                return try makeRational(allocator, data, order, true);
            }
            return try formatRationalArray(allocator, data, count, order, true);
        },
        .sbyte => {
            if (count == 1) {
                const val: i8 = @bitCast(data[0]);
                return Value{ .string = try formatInt(allocator, val) };
            }
            // Array of signed bytes
            var items: std.ArrayListUnmanaged(Value) = .empty;
            defer items.deinit(allocator);
            var idx: usize = 0;
            while (idx < count) : (idx += 1) {
                const val: i8 = @bitCast(data[idx]);
                items.append(allocator, .{ .string = try formatInt(allocator, val) }) catch return CodecError.OutOfMemory;
            }
            return Value{ .array = items.toOwnedSlice(allocator) catch return CodecError.OutOfMemory };
        },
        .sshort => {
            if (count == 1) {
                const val = std.mem.readInt(i16, data[0..2], endian(order));
                return Value{ .string = try formatInt(allocator, val) };
            }
            var items: std.ArrayListUnmanaged(Value) = .empty;
            defer items.deinit(allocator);
            var idx: usize = 0;
            while (idx < count) : (idx += 1) {
                const val = std.mem.readInt(i16, data[idx * 2 ..][0..2], endian(order));
                items.append(allocator, .{ .string = try formatInt(allocator, val) }) catch return CodecError.OutOfMemory;
            }
            return Value{ .array = items.toOwnedSlice(allocator) catch return CodecError.OutOfMemory };
        },
        .slong => {
            if (count == 1) {
                const val = std.mem.readInt(i32, data[0..4], endian(order));
                return Value{ .string = try formatInt(allocator, val) };
            }
            var items: std.ArrayListUnmanaged(Value) = .empty;
            defer items.deinit(allocator);
            var idx: usize = 0;
            while (idx < count) : (idx += 1) {
                const val = std.mem.readInt(i32, data[idx * 4 ..][0..4], endian(order));
                items.append(allocator, .{ .string = try formatInt(allocator, val) }) catch return CodecError.OutOfMemory;
            }
            return Value{ .array = items.toOwnedSlice(allocator) catch return CodecError.OutOfMemory };
        },
        .undefined => {
            // Return as binary data (will be pb-encoded by C0 layer)
            return Value{ .string = data };
        },
        .float, .double => {
            // Rare in EXIF; preserve as binary
            return Value{ .string = data };
        },
    }
}

// ============================================================================
// Value formatting helpers
// ============================================================================

fn formatUint(allocator: std.mem.Allocator, val: anytype) CodecError![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{val}) catch return CodecError.OutOfMemory;
}

fn formatInt(allocator: std.mem.Allocator, val: anytype) CodecError![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{val}) catch return CodecError.OutOfMemory;
}

fn formatUintArray(allocator: std.mem.Allocator, comptime T: type, data: []const u8, count: u32) CodecError!Value {
    var items: std.ArrayListUnmanaged(Value) = .empty;
    defer items.deinit(allocator);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const val: T = data[idx];
        items.append(allocator, .{
            .string = try formatUint(allocator, val),
        }) catch return CodecError.OutOfMemory;
    }
    return Value{ .array = items.toOwnedSlice(allocator) catch return CodecError.OutOfMemory };
}

fn formatShortArray(allocator: std.mem.Allocator, data: []const u8, count: u32, order: ByteOrder) CodecError!Value {
    var items: std.ArrayListUnmanaged(Value) = .empty;
    defer items.deinit(allocator);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const val = std.mem.readInt(u16, data[idx * 2 ..][0..2], endian(order));
        items.append(allocator, .{
            .string = try formatUint(allocator, val),
        }) catch return CodecError.OutOfMemory;
    }
    return Value{ .array = items.toOwnedSlice(allocator) catch return CodecError.OutOfMemory };
}

fn formatLongArray(allocator: std.mem.Allocator, data: []const u8, count: u32, order: ByteOrder) CodecError!Value {
    var items: std.ArrayListUnmanaged(Value) = .empty;
    defer items.deinit(allocator);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const val = std.mem.readInt(u32, data[idx * 4 ..][0..4], endian(order));
        items.append(allocator, .{
            .string = try formatUint(allocator, val),
        }) catch return CodecError.OutOfMemory;
    }
    return Value{ .array = items.toOwnedSlice(allocator) catch return CodecError.OutOfMemory };
}

fn makeRational(allocator: std.mem.Allocator, data: []const u8, order: ByteOrder, signed: bool) CodecError!Value {
    const entries = allocator.alloc(Entry, 2) catch return CodecError.OutOfMemory;
    if (signed) {
        const n = std.mem.readInt(i32, data[0..4], endian(order));
        const d = std.mem.readInt(i32, data[4..8], endian(order));
        entries[0] = .{ .key = "n", .value = .{ .string = try formatInt(allocator, n) } };
        entries[1] = .{ .key = "d", .value = .{ .string = try formatInt(allocator, d) } };
    } else {
        const n = std.mem.readInt(u32, data[0..4], endian(order));
        const d = std.mem.readInt(u32, data[4..8], endian(order));
        entries[0] = .{ .key = "n", .value = .{ .string = try formatUint(allocator, n) } };
        entries[1] = .{ .key = "d", .value = .{ .string = try formatUint(allocator, d) } };
    }
    return Value{ .object = entries };
}

fn formatRationalArray(allocator: std.mem.Allocator, data: []const u8, count: u32, order: ByteOrder, signed: bool) CodecError!Value {
    var items: std.ArrayListUnmanaged(Value) = .empty;
    defer items.deinit(allocator);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        items.append(allocator, try makeRational(allocator, data[idx * 8 ..], order, signed)) catch return CodecError.OutOfMemory;
    }
    return Value{ .array = items.toOwnedSlice(allocator) catch return CodecError.OutOfMemory };
}

// ============================================================================
// Collapse: C0 Value -> TIFF binary
// ============================================================================

/// Serialize a C0 Value back to TIFF binary data.
/// Input: {byte_order:II/MM, ifd0:{...}, ifd1:{...}}
pub fn collapseTiffData(allocator: std.mem.Allocator, value: Value) CodecError![]u8 {
    const entries = switch (value) {
        .object => |e| e,
        else => return CodecError.InvalidFormat,
    };

    // Extract fields
    var order: ByteOrder = .little;
    var ifd0_val: ?Value = null;
    var ifd1_val: ?Value = null;

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, "byte_order")) {
            const bo = switch (entry.value) {
                .string => |s| s,
                else => return CodecError.InvalidFormat,
            };
            if (std.mem.eql(u8, bo, "MM")) {
                order = .big;
            }
        } else if (std.mem.eql(u8, entry.key, "ifd0")) {
            ifd0_val = entry.value;
        } else if (std.mem.eql(u8, entry.key, "ifd1")) {
            ifd1_val = entry.value;
        }
    }

    const ifd0 = ifd0_val orelse return CodecError.InvalidFormat;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Write TIFF header
    if (order == .little) {
        buf.appendSlice(allocator, "II") catch return CodecError.OutOfMemory;
    } else {
        buf.appendSlice(allocator, "MM") catch return CodecError.OutOfMemory;
    }
    try appendU16(&buf, allocator, order, 42);
    try appendU32(&buf, allocator, order, 8); // IFD0 starts right after header

    // Write IFD0
    const next_ifd_pos = try collapseIfd(&buf, allocator, order, ifd0, .ifd0);

    // Write IFD1 if present
    if (ifd1_val) |v| {
        patchU32(&buf, next_ifd_pos, order, @intCast(buf.items.len));
        _ = try collapseIfd(&buf, allocator, order, v, .ifd0);
    }

    return buf.toOwnedSlice(allocator) catch return CodecError.OutOfMemory;
}

/// Prepared entry for serialization
const PreparedEntry = struct {
    tag: u16,
    tiff_type: TiffType,
    count: u32,
    data: []const u8,
};

/// Write a single IFD to the output buffer.
/// Returns the position of the next-IFD offset field (for patching).
fn collapseIfd(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    order: ByteOrder,
    ifd_value: Value,
    context: IfdContext,
) CodecError!usize {
    const ifd_entries = switch (ifd_value) {
        .object => |e| e,
        else => return CodecError.InvalidFormat,
    };

    // Separate regular entries from sub-IFD entries
    var regular: std.ArrayListUnmanaged(PreparedEntry) = .empty;
    defer regular.deinit(allocator);

    const SubIfdInfo = struct { tag: u16, value: Value, context: IfdContext };
    var sub_ifds: std.ArrayListUnmanaged(SubIfdInfo) = .empty;
    defer sub_ifds.deinit(allocator);

    for (ifd_entries) |entry| {
        // Check if this is a sub-IFD
        if (tags.subIfdTagId(entry.key)) |tag_id| {
            const sub_ctx = tags.subIfdContextForName(entry.key) orelse .ifd0;
            sub_ifds.append(allocator, .{
                .tag = tag_id,
                .value = entry.value,
                .context = sub_ctx,
            }) catch return CodecError.OutOfMemory;
            continue;
        }

        // Regular entry: resolve tag ID and type
        const tag_id = tags.tagId(context, entry.key) orelse continue;
        const tiff_type = tags.tagType(context, tag_id) orelse inferType(entry.value);
        const encoded = try encodeEntryValue(allocator, order, tiff_type, entry.value);

        regular.append(allocator, .{
            .tag = tag_id,
            .tiff_type = tiff_type,
            .count = encoded.count,
            .data = encoded.data,
        }) catch return CodecError.OutOfMemory;
    }

    // Sort regular entries by tag ID (TIFF spec requirement)
    std.mem.sort(PreparedEntry, regular.items, {}, struct {
        fn lessThan(_: void, a: PreparedEntry, b: PreparedEntry) bool {
            return a.tag < b.tag;
        }
    }.lessThan);

    const total_entries = regular.items.len + sub_ifds.items.len;

    // Write entry count
    try appendU16(buf, allocator, order, @intCast(total_entries));

    // Calculate where overflow data will start
    const entries_start = buf.items.len;
    const entries_size = total_entries * 12;
    const next_ifd_field = entries_start + entries_size;
    const overflow_start: u32 = @intCast(next_ifd_field + 4);

    // Calculate overflow offsets for regular entries
    var overflow_offset = overflow_start;
    for (regular.items) |entry| {
        if (entry.data.len > 4) {
            overflow_offset += @intCast(entry.data.len);
            // Word-align
            if (entry.data.len % 2 != 0) overflow_offset += 1;
        }
    }

    // Write regular entries
    var current_overflow: u32 = overflow_start;
    for (regular.items) |entry| {
        try appendU16(buf, allocator, order, entry.tag);
        try appendU16(buf, allocator, order, @intFromEnum(entry.tiff_type));
        try appendU32(buf, allocator, order, entry.count);

        if (entry.data.len <= 4) {
            // Inline value (pad to 4 bytes)
            var padded: [4]u8 = .{ 0, 0, 0, 0 };
            if (entry.data.len > 0) {
                @memcpy(padded[0..entry.data.len], entry.data);
            }
            buf.appendSlice(allocator, &padded) catch return CodecError.OutOfMemory;
        } else {
            try appendU32(buf, allocator, order, current_overflow);
            current_overflow += @intCast(entry.data.len);
            if (entry.data.len % 2 != 0) current_overflow += 1;
        }
    }

    // Write sub-IFD pointer entries with placeholder offsets
    var sub_ifd_patch_positions: std.ArrayListUnmanaged(usize) = .empty;
    defer sub_ifd_patch_positions.deinit(allocator);

    for (sub_ifds.items) |sub| {
        try appendU16(buf, allocator, order, sub.tag);
        try appendU16(buf, allocator, order, @intFromEnum(TiffType.long));
        try appendU32(buf, allocator, order, 1); // count = 1
        sub_ifd_patch_positions.append(allocator, buf.items.len) catch return CodecError.OutOfMemory;
        try appendU32(buf, allocator, order, 0); // placeholder offset
    }

    // Write next IFD offset (0 = no next IFD, caller patches if needed)
    const next_ifd_pos = buf.items.len;
    try appendU32(buf, allocator, order, 0);

    // Write overflow data for regular entries
    for (regular.items) |entry| {
        if (entry.data.len > 4) {
            buf.appendSlice(allocator, entry.data) catch return CodecError.OutOfMemory;
            // Word-align
            if (entry.data.len % 2 != 0) {
                buf.append(allocator, 0) catch return CodecError.OutOfMemory;
            }
        }
    }

    // Write sub-IFDs and patch their offset pointers
    for (sub_ifds.items, 0..) |sub, idx| {
        const sub_offset: u32 = @intCast(buf.items.len);
        patchU32(buf, sub_ifd_patch_positions.items[idx], order, sub_offset);
        _ = try collapseIfd(buf, allocator, order, sub.value, sub.context);
    }

    return next_ifd_pos;
}

/// Encode a C0 Value as raw TIFF bytes for a given type.
const EncodedValue = struct {
    data: []const u8,
    count: u32,
};

fn encodeEntryValue(
    allocator: std.mem.Allocator,
    order: ByteOrder,
    tiff_type: TiffType,
    value: Value,
) CodecError!EncodedValue {
    switch (tiff_type) {
        .ascii => {
            const str = switch (value) {
                .string => |s| s,
                else => return CodecError.InvalidFormat,
            };
            // Add null terminator
            const data = allocator.alloc(u8, str.len + 1) catch return CodecError.OutOfMemory;
            @memcpy(data[0..str.len], str);
            data[str.len] = 0;
            return .{ .data = data, .count = @intCast(data.len) };
        },
        .byte => {
            if (value == .array) {
                const arr = value.array;
                const data = allocator.alloc(u8, arr.len) catch return CodecError.OutOfMemory;
                for (arr, 0..) |item, idx| {
                    const s = switch (item) {
                        .string => |s| s,
                        else => return CodecError.InvalidFormat,
                    };
                    data[idx] = std.fmt.parseInt(u8, s, 10) catch return CodecError.InvalidFormat;
                }
                return .{ .data = data, .count = @intCast(arr.len) };
            }
            const s = switch (value) {
                .string => |s| s,
                else => return CodecError.InvalidFormat,
            };
            const val = std.fmt.parseInt(u8, s, 10) catch return CodecError.InvalidFormat;
            const data = allocator.alloc(u8, 1) catch return CodecError.OutOfMemory;
            data[0] = val;
            return .{ .data = data, .count = 1 };
        },
        .short => {
            if (value == .array) {
                const arr = value.array;
                const data = allocator.alloc(u8, arr.len * 2) catch return CodecError.OutOfMemory;
                for (arr, 0..) |item, idx| {
                    const s = switch (item) {
                        .string => |s| s,
                        else => return CodecError.InvalidFormat,
                    };
                    const val = std.fmt.parseInt(u16, s, 10) catch return CodecError.InvalidFormat;
                    std.mem.writeInt(u16, data[idx * 2 ..][0..2], val, endian(order));
                }
                return .{ .data = data, .count = @intCast(arr.len) };
            }
            const s = switch (value) {
                .string => |s| s,
                else => return CodecError.InvalidFormat,
            };
            const val = std.fmt.parseInt(u16, s, 10) catch return CodecError.InvalidFormat;
            const data = allocator.alloc(u8, 2) catch return CodecError.OutOfMemory;
            std.mem.writeInt(u16, data[0..2], val, endian(order));
            return .{ .data = data, .count = 1 };
        },
        .long => {
            if (value == .array) {
                const arr = value.array;
                const data = allocator.alloc(u8, arr.len * 4) catch return CodecError.OutOfMemory;
                for (arr, 0..) |item, idx| {
                    const s = switch (item) {
                        .string => |s| s,
                        else => return CodecError.InvalidFormat,
                    };
                    const val = std.fmt.parseInt(u32, s, 10) catch return CodecError.InvalidFormat;
                    std.mem.writeInt(u32, data[idx * 4 ..][0..4], val, endian(order));
                }
                return .{ .data = data, .count = @intCast(arr.len) };
            }
            const s = switch (value) {
                .string => |s| s,
                else => return CodecError.InvalidFormat,
            };
            const val = std.fmt.parseInt(u32, s, 10) catch return CodecError.InvalidFormat;
            const data = allocator.alloc(u8, 4) catch return CodecError.OutOfMemory;
            std.mem.writeInt(u32, data[0..4], val, endian(order));
            return .{ .data = data, .count = 1 };
        },
        .rational => {
            if (value == .array) {
                const arr = value.array;
                const data = allocator.alloc(u8, arr.len * 8) catch return CodecError.OutOfMemory;
                for (arr, 0..) |item, idx| {
                    try encodeRational(data[idx * 8 ..][0..8], item, order, false);
                }
                return .{ .data = data, .count = @intCast(arr.len) };
            }
            const data = allocator.alloc(u8, 8) catch return CodecError.OutOfMemory;
            try encodeRational(data[0..8], value, order, false);
            return .{ .data = data, .count = 1 };
        },
        .srational => {
            if (value == .array) {
                const arr = value.array;
                const data = allocator.alloc(u8, arr.len * 8) catch return CodecError.OutOfMemory;
                for (arr, 0..) |item, idx| {
                    try encodeRational(data[idx * 8 ..][0..8], item, order, true);
                }
                return .{ .data = data, .count = @intCast(arr.len) };
            }
            const data = allocator.alloc(u8, 8) catch return CodecError.OutOfMemory;
            try encodeRational(data[0..8], value, order, true);
            return .{ .data = data, .count = 1 };
        },
        .undefined => {
            // Binary data — pass through
            const s = switch (value) {
                .string => |s| s,
                else => return CodecError.InvalidFormat,
            };
            return .{ .data = s, .count = @intCast(s.len) };
        },
        .sbyte, .sshort, .slong, .float, .double => {
            // For these rare types, pass through as binary
            const s = switch (value) {
                .string => |s| s,
                else => return CodecError.InvalidFormat,
            };
            return .{ .data = s, .count = @intCast(s.len / @as(u32, tiff_type.size())) };
        },
    }
}

fn encodeRational(dest: *[8]u8, value: Value, order: ByteOrder, signed: bool) CodecError!void {
    const obj = switch (value) {
        .object => |e| e,
        else => return CodecError.InvalidFormat,
    };

    var n_str: ?[]const u8 = null;
    var d_str: ?[]const u8 = null;

    for (obj) |entry| {
        if (std.mem.eql(u8, entry.key, "n")) {
            n_str = switch (entry.value) {
                .string => |s| s,
                else => return CodecError.InvalidFormat,
            };
        } else if (std.mem.eql(u8, entry.key, "d")) {
            d_str = switch (entry.value) {
                .string => |s| s,
                else => return CodecError.InvalidFormat,
            };
        }
    }

    const n = n_str orelse return CodecError.InvalidFormat;
    const d = d_str orelse return CodecError.InvalidFormat;

    if (signed) {
        const nv = std.fmt.parseInt(i32, n, 10) catch return CodecError.InvalidFormat;
        const dv = std.fmt.parseInt(i32, d, 10) catch return CodecError.InvalidFormat;
        std.mem.writeInt(i32, dest[0..4], nv, endian(order));
        std.mem.writeInt(i32, dest[4..8], dv, endian(order));
    } else {
        const nv = std.fmt.parseInt(u32, n, 10) catch return CodecError.InvalidFormat;
        const dv = std.fmt.parseInt(u32, d, 10) catch return CodecError.InvalidFormat;
        std.mem.writeInt(u32, dest[0..4], nv, endian(order));
        std.mem.writeInt(u32, dest[4..8], dv, endian(order));
    }
}

/// Infer TIFF type from C0 value when tag type is unknown.
fn inferType(value: Value) TiffType {
    switch (value) {
        .object => return .rational, // {n:X,d:Y} → RATIONAL
        .array => |arr| {
            if (arr.len > 0) return inferType(arr[0]);
            return .undefined;
        },
        .string => |s| {
            // Try to parse as integer
            if (s.len > 0) {
                _ = std.fmt.parseInt(u32, s, 10) catch {
                    // Not a number — treat as ASCII
                    return .ascii;
                };
                return .short; // Default to SHORT for numeric values
            }
            return .ascii;
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

/// Build a minimal TIFF binary for testing:
/// Little-endian, IFD0 with Make="Canon" and Orientation=1
pub fn buildTestTiff(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Header: "II" + 42 + offset to IFD0 (8)
    try buf.appendSlice(allocator, "II");
    var tmp2: [2]u8 = undefined;
    std.mem.writeInt(u16, &tmp2, 42, .little);
    try buf.appendSlice(allocator, &tmp2);
    var tmp4: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp4, 8, .little);
    try buf.appendSlice(allocator, &tmp4);

    // IFD0: 2 entries
    // Entry count
    std.mem.writeInt(u16, &tmp2, 2, .little);
    try buf.appendSlice(allocator, &tmp2);

    // Entry 1: Make (0x010F), ASCII, count=6, offset=38
    std.mem.writeInt(u16, &tmp2, 0x010F, .little);
    try buf.appendSlice(allocator, &tmp2);
    std.mem.writeInt(u16, &tmp2, 2, .little); // ASCII
    try buf.appendSlice(allocator, &tmp2);
    std.mem.writeInt(u32, &tmp4, 6, .little); // count (includes null)
    try buf.appendSlice(allocator, &tmp4);
    std.mem.writeInt(u32, &tmp4, 38, .little); // offset to "Canon\0"
    try buf.appendSlice(allocator, &tmp4);

    // Entry 2: Orientation (0x0112), SHORT, count=1, value=1 (inline)
    std.mem.writeInt(u16, &tmp2, 0x0112, .little);
    try buf.appendSlice(allocator, &tmp2);
    std.mem.writeInt(u16, &tmp2, 3, .little); // SHORT
    try buf.appendSlice(allocator, &tmp2);
    std.mem.writeInt(u32, &tmp4, 1, .little); // count
    try buf.appendSlice(allocator, &tmp4);
    // Inline value: 1 as u16 LE, padded to 4 bytes
    std.mem.writeInt(u16, &tmp2, 1, .little);
    try buf.appendSlice(allocator, &tmp2);
    try buf.appendSlice(allocator, &.{ 0, 0 }); // padding

    // Next IFD offset: 0 (no more IFDs)
    std.mem.writeInt(u32, &tmp4, 0, .little);
    try buf.appendSlice(allocator, &tmp4);

    // Overflow data at offset 38: "Canon\0"
    try buf.appendSlice(allocator, "Canon\x00");

    return buf.toOwnedSlice(allocator);
}

test "expand minimal TIFF" {
    const allocator = std.testing.allocator;
    const tiff_data = try buildTestTiff(allocator);
    defer allocator.free(tiff_data);

    const value = try expandTiffData(allocator, tiff_data);
    // Free at end — use arena-like approach
    defer {
        // Free ifd0 entries
        const ifd0 = value.object[1].value;
        for (ifd0.object) |entry| {
            if (std.mem.eql(u8, entry.key, "Orientation")) {
                allocator.free(entry.value.string);
            }
        }
        allocator.free(ifd0.object);
        allocator.free(value.object);
    }

    // Check byte_order
    try std.testing.expectEqualStrings("byte_order", value.object[0].key);
    try std.testing.expectEqualStrings("II", value.object[0].value.string);

    // Check ifd0
    try std.testing.expectEqualStrings("ifd0", value.object[1].key);
    const ifd0 = value.object[1].value;
    try std.testing.expect(ifd0 == .object);

    // Check Make
    try std.testing.expectEqualStrings("Make", ifd0.object[0].key);
    try std.testing.expectEqualStrings("Canon", ifd0.object[0].value.string);

    // Check Orientation
    try std.testing.expectEqualStrings("Orientation", ifd0.object[1].key);
    try std.testing.expectEqualStrings("1", ifd0.object[1].value.string);
}

test "expand TIFF with RATIONAL value" {
    const allocator = std.testing.allocator;

    // Build a TIFF with XResolution = 72/1
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    // Header
    try buf.appendSlice(allocator, "II");
    var tmp2: [2]u8 = undefined;
    std.mem.writeInt(u16, &tmp2, 42, .little);
    try buf.appendSlice(allocator, &tmp2);
    var tmp4: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp4, 8, .little);
    try buf.appendSlice(allocator, &tmp4);

    // IFD: 1 entry
    std.mem.writeInt(u16, &tmp2, 1, .little);
    try buf.appendSlice(allocator, &tmp2);

    // XResolution (0x011A), RATIONAL, count=1, offset=26
    std.mem.writeInt(u16, &tmp2, 0x011A, .little);
    try buf.appendSlice(allocator, &tmp2);
    std.mem.writeInt(u16, &tmp2, 5, .little); // RATIONAL
    try buf.appendSlice(allocator, &tmp2);
    std.mem.writeInt(u32, &tmp4, 1, .little);
    try buf.appendSlice(allocator, &tmp4);
    std.mem.writeInt(u32, &tmp4, 26, .little); // offset
    try buf.appendSlice(allocator, &tmp4);

    // Next IFD: 0
    std.mem.writeInt(u32, &tmp4, 0, .little);
    try buf.appendSlice(allocator, &tmp4);

    // RATIONAL value at offset 26: 72/1
    std.mem.writeInt(u32, &tmp4, 72, .little);
    try buf.appendSlice(allocator, &tmp4);
    std.mem.writeInt(u32, &tmp4, 1, .little);
    try buf.appendSlice(allocator, &tmp4);

    const data = try buf.toOwnedSlice(allocator);
    defer allocator.free(data);

    const value = try expandTiffData(allocator, data);
    defer {
        const ifd0 = value.object[1].value;
        const rational = ifd0.object[0].value;
        allocator.free(rational.object[0].value.string);
        allocator.free(rational.object[1].value.string);
        allocator.free(rational.object);
        allocator.free(ifd0.object);
        allocator.free(value.object);
    }

    const ifd0 = value.object[1].value;
    try std.testing.expectEqualStrings("XResolution", ifd0.object[0].key);

    const rational = ifd0.object[0].value;
    try std.testing.expect(rational == .object);
    try std.testing.expectEqualStrings("n", rational.object[0].key);
    try std.testing.expectEqualStrings("72", rational.object[0].value.string);
    try std.testing.expectEqualStrings("d", rational.object[1].key);
    try std.testing.expectEqualStrings("1", rational.object[1].value.string);
}

test "collapse and re-expand round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tiff_data = try buildTestTiff(allocator);

    // Expand
    const value = try expandTiffData(allocator, tiff_data);

    // Collapse back to binary
    const collapsed = try collapseTiffData(allocator, value);

    // Re-expand
    const value2 = try expandTiffData(allocator, collapsed);

    // Verify same structure
    try std.testing.expectEqualStrings("II", value2.object[0].value.string);
    const ifd0 = value2.object[1].value;
    try std.testing.expectEqualStrings("Make", ifd0.object[0].key);
    try std.testing.expectEqualStrings("Canon", ifd0.object[0].value.string);
    try std.testing.expectEqualStrings("Orientation", ifd0.object[1].key);
    try std.testing.expectEqualStrings("1", ifd0.object[1].value.string);
}

test "collapse with RATIONAL values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build a C0 value with a RATIONAL field
    const rational_entries = try allocator.alloc(Entry, 2);
    rational_entries[0] = .{ .key = "n", .value = .{ .string = "72" } };
    rational_entries[1] = .{ .key = "d", .value = .{ .string = "1" } };

    const ifd0_entries = try allocator.alloc(Entry, 1);
    ifd0_entries[0] = .{
        .key = "XResolution",
        .value = .{ .object = rational_entries },
    };

    const top_entries = try allocator.alloc(Entry, 2);
    top_entries[0] = .{ .key = "byte_order", .value = .{ .string = "II" } };
    top_entries[1] = .{ .key = "ifd0", .value = .{ .object = ifd0_entries } };

    const collapsed = try collapseTiffData(allocator, .{ .object = top_entries });

    // Re-expand and verify
    const value = try expandTiffData(allocator, collapsed);
    const ifd0 = value.object[1].value;
    try std.testing.expectEqualStrings("XResolution", ifd0.object[0].key);

    const rat = ifd0.object[0].value;
    try std.testing.expectEqualStrings("72", rat.object[0].value.string);
    try std.testing.expectEqualStrings("1", rat.object[1].value.string);
}

test "big-endian TIFF round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build a big-endian C0 value
    const ifd0_entries = try allocator.alloc(Entry, 1);
    ifd0_entries[0] = .{
        .key = "Orientation",
        .value = .{ .string = "6" },
    };

    const top_entries = try allocator.alloc(Entry, 2);
    top_entries[0] = .{ .key = "byte_order", .value = .{ .string = "MM" } };
    top_entries[1] = .{ .key = "ifd0", .value = .{ .object = ifd0_entries } };

    const collapsed = try collapseTiffData(allocator, .{ .object = top_entries });

    // Verify header
    try std.testing.expectEqualStrings("MM", collapsed[0..2]);

    // Re-expand
    const value = try expandTiffData(allocator, collapsed);
    try std.testing.expectEqualStrings("MM", value.object[0].value.string);
    const ifd0 = value.object[1].value;
    try std.testing.expectEqualStrings("6", ifd0.object[0].value.string);
}
