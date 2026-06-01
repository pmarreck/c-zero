//! PDF cross-reference table and stream parser.
//!
//! Handles traditional xref tables and compressed xref streams (PDF 1.5+).
//! Follows /Prev chain for incremental updates.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("c0_core");
const Value = core.Value;
const Entry = core.Entry;
const parser = @import("parser.zig");
const filters = @import("filters.zig");
const util = @import("util.zig");

pub const XrefError = error{
    NotFound,
    InvalidFormat,
    OutOfMemory,
    DecompressionError,
};

pub const XrefEntry = struct {
    obj_num: u32,
    gen_num: u16,
    offset: u64,
    in_use: bool,
    // For type 2 entries (objects in object streams)
    in_object_stream: bool = false,
    stream_obj: u32 = 0, // containing object stream's number
    stream_index: u32 = 0, // index within object stream
};

pub const XrefTable = struct {
    entries: std.AutoHashMapUnmanaged(u32, XrefEntry),
    trailer_dict: Value, // full trailer as C0 Value
    size: u32,

    pub fn getOffset(self: XrefTable, obj_num: u32) ?u64 {
        if (self.entries.get(obj_num)) |entry| {
            if (entry.in_use and !entry.in_object_stream) return entry.offset;
        }
        return null;
    }

    pub fn deinit(self: *XrefTable, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }
};

/// Find "startxref" near EOF and return the xref offset.
pub fn findStartxref(data: []const u8) ?u64 {
    // Search backwards from EOF, within last 1KB
    const search_start = if (data.len > 1024) data.len - 1024 else 0;
    const search_data = data[search_start..];

    // Find "startxref"
    var i: usize = 0;
    var found: ?usize = null;
    while (i + 9 <= search_data.len) {
        if (std.mem.eql(u8, search_data[i .. i + 9], "startxref")) {
            found = i;
        }
        i += 1;
    }

    const pos = (found orelse return null) + 9;

    // Skip whitespace, parse the offset number
    var j = pos;
    while (j < search_data.len and isWhitespace(search_data[j])) : (j += 1) {}

    var offset: u64 = 0;
    var has_digit = false;
    while (j < search_data.len and search_data[j] >= '0' and search_data[j] <= '9') {
        offset = offset * 10 + (search_data[j] - '0');
        has_digit = true;
        j += 1;
    }

    if (!has_digit) return null;
    return offset;
}

/// Parse the full xref table, following /Prev chain for incremental updates.
pub fn parseXrefTable(allocator: Allocator, data: []const u8) ?XrefTable {
    const start_offset = findStartxref(data) orelse return null;

    var table = XrefTable{
        .entries = .{},
        .trailer_dict = .{ .string = "" },
        .size = 0,
    };

    var offset: ?u64 = start_offset;
    var first = true;

    while (offset) |off| {
        if (off >= data.len) break;

        const pos = @as(usize, @intCast(off));
        const ws_pos = parser.skipWhitespace(data, pos);

        if (ws_pos + 4 <= data.len and std.mem.eql(u8, data[ws_pos .. ws_pos + 4], "xref")) {
            // Traditional xref table
            const trailer_info = parseTraditionalXref(allocator, data, ws_pos, &table) orelse break;
            if (first) {
                table.trailer_dict = trailer_info.trailer_value;
                table.size = trailer_info.size;
                first = false;
            }
            offset = trailer_info.prev_offset;
        } else {
            // Possibly a cross-reference stream
            const stream_info = parseXrefStream(allocator, data, ws_pos, &table) orelse break;
            if (first) {
                table.trailer_dict = stream_info.trailer_value;
                table.size = stream_info.size;
                first = false;
            }
            offset = stream_info.prev_offset;
        }
    }

    if (table.entries.count() == 0) return null;
    return table;
}

const TrailerParseInfo = struct {
    size: u32,
    prev_offset: ?u64,
    trailer_value: Value,
};

/// Parse a traditional xref table section.
fn parseTraditionalXref(allocator: Allocator, data: []const u8, start: usize, table: *XrefTable) ?TrailerParseInfo {
    var i = start;

    // Skip "xref"
    if (i + 4 > data.len or !std.mem.eql(u8, data[i .. i + 4], "xref")) return null;
    i += 4;
    i = skipWsNoComment(data, i);

    // Parse subsections
    while (i < data.len) {
        // Check for "trailer"
        if (i + 7 <= data.len and std.mem.eql(u8, data[i .. i + 7], "trailer")) {
            i += 7;
            break;
        }

        // Parse subsection header: first_obj count
        const first_obj = parseUint(data, i) orelse break;
        i = skipWsNoComment(data, first_obj.end);
        const count = parseUint(data, i) orelse break;
        i = skipWsNoComment(data, count.end);

        // Parse 20-byte entries
        for (0..@as(usize, @intCast(count.value))) |idx| {
            if (i + 18 > data.len) break;

            const entry_offset = parseUint(data, i) orelse break;
            i = skipWsNoComment(data, entry_offset.end);
            const entry_gen = parseUint(data, i) orelse break;
            i = skipWsNoComment(data, entry_gen.end);

            if (i >= data.len) break;
            const status = data[i];
            i += 1;
            i = skipWsNoComment(data, i);

            const obj_num: u32 = @intCast(first_obj.value + idx);

            // Only add if not already present (most recent xref takes precedence)
            if (!table.entries.contains(obj_num)) {
                table.entries.put(allocator, obj_num, .{
                    .obj_num = obj_num,
                    .gen_num = @intCast(entry_gen.value),
                    .offset = entry_offset.value,
                    .in_use = (status == 'n'),
                }) catch return null;
            }
        }
    }

    // Parse trailer dictionary
    i = parser.skipWhitespace(data, i);
    if (i + 2 <= data.len and data[i] == '<' and data[i + 1] == '<') {
        const dict_result = parser.parseValue(allocator, data, i) catch return null;
        const size = parser.getDictInt(dict_result.value, "Size") orelse 0;
        const prev = parser.getDictInt(dict_result.value, "Prev");

        return .{
            .size = @intCast(size),
            .prev_offset = if (prev) |p| @intCast(p) else null,
            .trailer_value = dict_result.value,
        };
    }

    return null;
}

/// Parse a cross-reference stream object.
fn parseXrefStream(allocator: Allocator, data: []const u8, start: usize, table: *XrefTable) ?TrailerParseInfo {
    // Parse as indirect object
    const obj = parser.parseIndirectObject(allocator, data, start) catch return null;

    // Must have a stream
    if (obj.stream_start == null or obj.stream_end == null) return null;

    // Get /W field widths
    const w_val = parser.getDictValue(obj.dict, "W") orelse return null;
    const w_arr = switch (w_val) {
        .array => |a| a,
        else => return null,
    };
    if (w_arr.len != 3) return null;

    const w1 = std.fmt.parseInt(usize, w_arr[0].string, 10) catch return null;
    const w2 = std.fmt.parseInt(usize, w_arr[1].string, 10) catch return null;
    const w3 = std.fmt.parseInt(usize, w_arr[2].string, 10) catch return null;
    const entry_size = w1 + w2 + w3;
    if (entry_size == 0) return null;

    // Get /Index (subsection ranges), default to [0 Size]
    const size_val = parser.getDictInt(obj.dict, "Size") orelse return null;

    // Decompress stream
    const raw_stream = data[obj.stream_start.?..obj.stream_end.?];
    const filter_name = parser.getDictString(obj.dict, "Filter");

    const stream_data = if (filter_name) |f| blk: {
        const ft = filters.detectFilter(f);
        break :blk filters.decodeFilter(allocator, raw_stream, ft) catch return null;
    } else allocator.dupe(u8, raw_stream) catch return null;
    defer allocator.free(stream_data);

    // Parse /Index array
    var subsections: std.ArrayListUnmanaged([2]u64) = .empty;
    defer subsections.deinit(allocator);

    if (parser.getDictValue(obj.dict, "Index")) |idx_val| {
        switch (idx_val) {
            .array => |idx_arr| {
                var k: usize = 0;
                while (k + 1 < idx_arr.len) : (k += 2) {
                    const first = std.fmt.parseInt(u64, idx_arr[k].string, 10) catch continue;
                    const count = std.fmt.parseInt(u64, idx_arr[k + 1].string, 10) catch continue;
                    subsections.append(allocator, .{ first, count }) catch return null;
                }
            },
            else => {},
        }
    }

    if (subsections.items.len == 0) {
        subsections.append(allocator, .{ 0, size_val }) catch return null;
    }

    // Parse binary entries
    var pos: usize = 0;
    for (subsections.items) |sub| {
        const first_obj = sub[0];
        const count = sub[1];

        for (0..@as(usize, @intCast(count))) |idx| {
            if (pos + entry_size > stream_data.len) break;

            const type_val = readFieldValue(stream_data, pos, w1, 1); // default type=1
            const field2 = readFieldValue(stream_data, pos + w1, w2, 0);
            const field3 = readFieldValue(stream_data, pos + w1 + w2, w3, 0);
            pos += entry_size;

            const obj_num: u32 = @intCast(first_obj + idx);

            if (!table.entries.contains(obj_num)) {
                switch (type_val) {
                    0 => {
                        // Free object
                        table.entries.put(allocator, obj_num, .{
                            .obj_num = obj_num,
                            .gen_num = @intCast(field3),
                            .offset = field2,
                            .in_use = false,
                        }) catch return null;
                    },
                    1 => {
                        // Regular object at offset
                        table.entries.put(allocator, obj_num, .{
                            .obj_num = obj_num,
                            .gen_num = @intCast(field3),
                            .offset = field2,
                            .in_use = true,
                        }) catch return null;
                    },
                    2 => {
                        // Object in object stream
                        table.entries.put(allocator, obj_num, .{
                            .obj_num = obj_num,
                            .gen_num = 0,
                            .offset = 0,
                            .in_use = true,
                            .in_object_stream = true,
                            .stream_obj = @intCast(field2),
                            .stream_index = @intCast(field3),
                        }) catch return null;
                    },
                    else => {},
                }
            }
        }
    }

    const size = parser.getDictInt(obj.dict, "Size") orelse 0;
    const prev = parser.getDictInt(obj.dict, "Prev");

    // Build trailer value from xref stream dict (it serves as both)
    return .{
        .size = @intCast(size),
        .prev_offset = if (prev) |p| @intCast(p) else null,
        .trailer_value = obj.dict,
    };
}

/// Read a variable-width integer from binary data.
fn readFieldValue(data: []const u8, pos: usize, width: usize, default: u64) u64 {
    if (width == 0) return default;
    if (pos + width > data.len) return default;

    var value: u64 = 0;
    for (0..width) |i| {
        value = (value << 8) | data[pos + i];
    }
    return value;
}

fn parseUint(data: []const u8, start: usize) ?struct { value: u64, end: usize } {
    var i = start;
    if (i >= data.len or data[i] < '0' or data[i] > '9') return null;
    var value: u64 = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') {
        value = value * 10 + (data[i] - '0');
        i += 1;
    }
    return .{ .value = value, .end = i };
}

const isWhitespace = util.isWhitespace;

fn skipWsNoComment(data: []const u8, start: usize) usize {
    var i = start;
    while (i < data.len and isWhitespace(data[i])) : (i += 1) {}
    return i;
}

// ============================================================================
// Tests
// ============================================================================

test "findStartxref" {
    const data = "some pdf data\nstartxref\n12345\n%%EOF\n";
    const offset = findStartxref(data);
    try std.testing.expectEqual(@as(?u64, 12345), offset);
}

test "findStartxref not found" {
    const data = "no xref here";
    try std.testing.expectEqual(@as(?u64, null), findStartxref(data));
}

test "readFieldValue" {
    const data = [_]u8{ 0x00, 0x01, 0x00, 0x42 };
    try std.testing.expectEqual(@as(u64, 1), readFieldValue(&data, 0, 2, 0));
    try std.testing.expectEqual(@as(u64, 0x0042), readFieldValue(&data, 2, 2, 0));
    try std.testing.expectEqual(@as(u64, 99), readFieldValue(&data, 0, 0, 99)); // width=0 returns default
}

test "parse simple xref table" {
    // Use arena since parseXrefTable allocates trailer dict entries
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const pdf = "%PDF-1.4\n" ++
        "1 0 obj\n<< /Type /Catalog >>\nendobj\n" ++
        "xref\n0 2\n" ++
        "0000000000 65535 f \n" ++
        "0000000009 00000 n \n" ++
        "trailer\n<< /Size 2 /Root 1 0 R >>\n" ++
        "startxref\n44\n%%EOF\n";

    const table = parseXrefTable(allocator, pdf) orelse {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expectEqual(@as(u32, 2), table.size);
    try std.testing.expect(table.entries.contains(1));

    const entry = table.entries.get(1).?;
    try std.testing.expect(entry.in_use);
    try std.testing.expectEqual(@as(u64, 9), entry.offset);
}
