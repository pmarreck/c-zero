//! PDF Codec for C0.
//!
//! Expands PDF files into C0 structured text and collapses back to valid PDF.
//! Supports both faithful mode (bit-perfect round-trip via _raw) and
//! editable mode (decoded streams, recomputed offsets/lengths on collapse).

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("c0_core");
const Value = core.Value;
const Entry = core.Entry;
const codec = @import("../mod.zig");
const CodecError = codec.CodecError;
const CodecOptions = codec.CodecOptions;

pub const parser = @import("parser.zig");
pub const xref = @import("xref.zig");
pub const filters = @import("filters.zig");
pub const serializer = @import("serializer.zig");
pub const zlib = @import("zlib.zig");

pub const PdfCodec = struct {
    pub fn getInfo(_: *PdfCodec) codec.CodecInfo {
        return .{
            .name = "pdf",
            .description = "Portable Document Format",
            .extensions = &.{".pdf"},
            .magic = &.{.{ .offset = 0, .bytes = "%PDF-" }},
            .format_names = &.{"pdf"},
            .supports_faithful = true,
            .supports_editable = true,
            .help =
                \\Expand: parses PDF structure including xref tables, object streams,
                \\and stream filters (FlateDecode, ASCII85, LZW, RunLength, ASCIIHex).
                \\
                \\Collapse: reassembles PDF with recomputed xref offsets.
                \\
                \\Faithful mode preserves raw bytes for bit-perfect round-trip.
                \\Editable mode decodes streams and recomputes offsets on collapse.
            ,
            .custom_args = &.{
                .{
                    .name = "pages",
                    .description = "Page range to expand (e.g., 1-5, 3)",
                    .value_name = "RANGE",
                },
            },
        };
    }

    pub fn expandImpl(_: *PdfCodec, allocator: Allocator, data: []const u8, options: CodecOptions) CodecError!Value {
        return expandPdf(allocator, data, options);
    }

    pub fn collapseImpl(_: *PdfCodec, allocator: Allocator, value: Value, options: CodecOptions) CodecError![]u8 {
        return serializer.collapsePdf(allocator, value, options);
    }
};

/// Expand a PDF file into C0 structured text.
pub fn expandPdf(allocator: Allocator, data: []const u8, options: CodecOptions) CodecError!Value {
    // Validate magic
    if (data.len < 5 or !std.mem.eql(u8, data[0..5], "%PDF-")) {
        return CodecError.InvalidMagic;
    }

    // Parse header line to get version
    var header_end: usize = 5;
    while (header_end < data.len and data[header_end] != '\n' and data[header_end] != '\r') {
        header_end += 1;
    }
    const header = data[0..header_end];
    const version = data[5..header_end];

    // Build xref table
    var xref_table = xref.parseXrefTable(allocator, data);
    defer if (xref_table != null) xref_table.?.deinit(allocator);

    // Collect objects
    var objects: std.ArrayListUnmanaged(Value) = .empty;
    errdefer objects.deinit(allocator);

    if (xref_table) |*xt| {
        // Use xref table to find objects
        var it = xt.entries.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            if (!entry.in_use) continue;
            if (entry.in_object_stream) continue; // Handle separately

            if (entry.offset >= data.len) continue;
            const obj_value = parseObjectToValue(allocator, data, @intCast(entry.offset), options) catch continue;
            objects.append(allocator, obj_value) catch return CodecError.OutOfMemory;
        }

        // Handle objects in object streams (type 2)
        var it2 = xt.entries.iterator();
        while (it2.next()) |kv| {
            const entry = kv.value_ptr.*;
            if (!entry.in_use or !entry.in_object_stream) continue;

            // Find the containing object stream
            if (xt.getOffset(entry.stream_obj)) |stream_offset| {
                const stream_objs = extractObjectStreamEntries(allocator, data, @intCast(stream_offset), options) catch continue;
                for (stream_objs) |sobj| {
                    objects.append(allocator, sobj) catch return CodecError.OutOfMemory;
                }
            }
        }
    } else {
        // Fallback: linear scan for objects
        const scanned = parser.scanForObjects(allocator, data) catch return CodecError.InvalidFormat;
        for (scanned) |obj| {
            const obj_value = objectResultToValue(allocator, data, obj, options) catch continue;
            objects.append(allocator, obj_value) catch return CodecError.OutOfMemory;
        }
    }

    // Sort objects by number
    std.mem.sort(Value, objects.items, {}, struct {
        fn lessThan(_: void, a: Value, b: Value) bool {
            const a_num = getObjNum(a) orelse return true;
            const b_num = getObjNum(b) orelse return false;
            return a_num < b_num;
        }
    }.lessThan);

    // Build top-level structure
    const trailer_val = if (xref_table) |xt| xt.trailer_dict else Value{ .object = &.{} };

    var top_count: usize = 4;
    if (options.faithful) top_count = 5; // +1 for _raw
    const top_entries = allocator.alloc(Entry, top_count) catch return CodecError.OutOfMemory;

    top_entries[0] = .{ .key = "format", .value = .{ .string = "pdf" } };
    top_entries[1] = .{ .key = "version", .value = .{ .string = version } };
    top_entries[2] = .{ .key = "header", .value = .{ .string = header } };
    top_entries[3] = .{
        .key = "objects",
        .value = .{ .array = objects.toOwnedSlice(allocator) catch return CodecError.OutOfMemory },
    };

    if (options.faithful) {
        top_entries[4] = .{ .key = "_raw", .value = .{ .string = data } };
    }

    // Add trailer if we have one
    if (xref_table != null) {
        // Append trailer to the entries
        const with_trailer = allocator.alloc(Entry, top_count + 1) catch return CodecError.OutOfMemory;
        @memcpy(with_trailer[0..top_count], top_entries);
        with_trailer[top_count] = .{ .key = "trailer", .value = trailer_val };
        allocator.free(top_entries);
        return Value{ .object = with_trailer };
    }

    return Value{ .object = top_entries };
}

/// Parse an object at the given offset and convert to C0 Value.
fn parseObjectToValue(allocator: Allocator, data: []const u8, offset: usize, options: CodecOptions) !Value {
    const obj = try parser.parseIndirectObject(allocator, data, offset);
    return objectResultToValue(allocator, data, obj, options);
}

/// Convert an ObjectResult to a C0 Value.
fn objectResultToValue(allocator: Allocator, data: []const u8, obj: parser.ObjectResult, options: CodecOptions) !Value {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer entries.deinit(allocator);

    // Object number
    const num_str = std.fmt.allocPrint(allocator, "{d}", .{obj.num}) catch return error.OutOfMemory;
    entries.append(allocator, .{ .key = "num", .value = .{ .string = num_str } }) catch return error.OutOfMemory;

    // Generation number
    const gen_str = std.fmt.allocPrint(allocator, "{d}", .{obj.gen}) catch return error.OutOfMemory;
    entries.append(allocator, .{ .key = "gen", .value = .{ .string = gen_str } }) catch return error.OutOfMemory;

    // Dictionary
    entries.append(allocator, .{ .key = "dict", .value = obj.dict }) catch return error.OutOfMemory;

    // Stream data
    if (obj.stream_start != null and obj.stream_end != null) {
        const stream_data = data[obj.stream_start.?..obj.stream_end.?];

        if (options.faithful) {
            // Faithful mode: store raw stream bytes
            entries.append(allocator, .{
                .key = "_stream_raw",
                .value = .{ .string = stream_data },
            }) catch return error.OutOfMemory;
        }

        // Try to decode stream
        const filter_chain = getFilterChain(allocator, obj.dict);
        if (filter_chain.len > 0) {
            if (filters.applyDecodeChain(allocator, stream_data, filter_chain)) |decoded| {
                entries.append(allocator, .{
                    .key = "stream",
                    .value = .{ .string = decoded },
                }) catch return error.OutOfMemory;
            } else |_| {
                // Decoding failed, store raw
                if (!options.faithful) {
                    entries.append(allocator, .{
                        .key = "stream",
                        .value = .{ .string = stream_data },
                    }) catch return error.OutOfMemory;
                }
            }
        } else {
            // No filter, stream is raw
            entries.append(allocator, .{
                .key = "stream",
                .value = .{ .string = stream_data },
            }) catch return error.OutOfMemory;
        }
    }

    const owned = entries.toOwnedSlice(allocator) catch return error.OutOfMemory;
    return Value{ .object = owned };
}

/// Extract objects from an object stream.
fn extractObjectStreamEntries(allocator: Allocator, data: []const u8, offset: usize, options: CodecOptions) ![]Value {
    const obj = try parser.parseIndirectObject(allocator, data, offset);

    if (obj.stream_start == null or obj.stream_end == null) return &.{};

    const stream_data = data[obj.stream_start.?..obj.stream_end.?];

    // Decode stream
    const filter_chain = getFilterChain(allocator, obj.dict);
    const decoded = if (filter_chain.len > 0)
        filters.applyDecodeChain(allocator, stream_data, filter_chain) catch return &.{}
    else
        allocator.dupe(u8, stream_data) catch return &.{};
    defer allocator.free(decoded);

    // Parse /N (number of objects) and /First (offset to first object data)
    const n = parser.getDictInt(obj.dict, "N") orelse return &.{};
    const first = parser.getDictInt(obj.dict, "First") orelse return &.{};

    var results: std.ArrayListUnmanaged(Value) = .empty;
    errdefer results.deinit(allocator);

    // Parse the object number + offset pairs
    var pos: usize = 0;
    for (0..n) |_| {
        pos = parser.skipWhitespace(decoded, pos);
        const num_result = parseUintSimple(decoded, pos) orelse break;
        pos = parser.skipWhitespace(decoded, num_result.end);
        const off_result = parseUintSimple(decoded, pos) orelse break;
        pos = off_result.end;

        // Parse the actual object data
        const obj_data_start = first + off_result.value;
        if (obj_data_start >= decoded.len) continue;

        const val_result = parser.parseValue(allocator, decoded, obj_data_start) catch continue;

        var sub_entries: std.ArrayListUnmanaged(Entry) = .empty;
        const num_str = std.fmt.allocPrint(allocator, "{d}", .{num_result.value}) catch continue;
        sub_entries.append(allocator, .{ .key = "num", .value = .{ .string = num_str } }) catch continue;
        sub_entries.append(allocator, .{ .key = "gen", .value = .{ .string = "0" } }) catch continue;
        sub_entries.append(allocator, .{ .key = "dict", .value = val_result.value }) catch continue;

        _ = options; // object stream entries don't have their own streams

        const owned = sub_entries.toOwnedSlice(allocator) catch continue;
        results.append(allocator, .{ .object = owned }) catch continue;
    }

    return results.toOwnedSlice(allocator) catch return &.{};
}

/// Get the filter chain for a stream from its dictionary.
fn getFilterChain(allocator: Allocator, dict: Value) []const filters.FilterType {
    const filter_val = parser.getDictValue(dict, "Filter") orelse return &.{};

    switch (filter_val) {
        .string => |name| {
            const ft = filters.detectFilter(name);
            if (ft == .unknown) return &.{};
            const chain = allocator.alloc(filters.FilterType, 1) catch return &.{};
            chain[0] = ft;
            return chain;
        },
        .array => |arr| {
            var chain: std.ArrayListUnmanaged(filters.FilterType) = .empty;
            for (arr) |item| {
                switch (item) {
                    .string => |name| {
                        const ft = filters.detectFilter(name);
                        chain.append(allocator, ft) catch return &.{};
                    },
                    else => {},
                }
            }
            return chain.toOwnedSlice(allocator) catch return &.{};
        },
        else => return &.{},
    }
}

/// Get object number from a C0 object value.
fn getObjNum(value: Value) ?u32 {
    switch (value) {
        .object => |entries| {
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, "num")) {
                    switch (entry.value) {
                        .string => |s| return std.fmt.parseInt(u32, s, 10) catch null,
                        else => return null,
                    }
                }
            }
        },
        else => {},
    }
    return null;
}

fn parseUintSimple(data: []const u8, start: usize) ?struct { value: usize, end: usize } {
    var i = start;
    if (i >= data.len or data[i] < '0' or data[i] > '9') return null;
    var value: usize = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') {
        value = value * 10 + (data[i] - '0');
        i += 1;
    }
    return .{ .value = value, .end = i };
}

// ============================================================================
// Tests
// ============================================================================

/// Build a minimal valid PDF for testing.
pub fn buildTestPdf(allocator: Allocator) ![]u8 {
    var pdf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer pdf.deinit(allocator);

    // Header
    try pdf.appendSlice(allocator, "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n");

    // Object 1: Catalog
    const obj1_offset = pdf.items.len;
    try pdf.appendSlice(allocator, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2: Pages
    const obj2_offset = pdf.items.len;
    try pdf.appendSlice(allocator, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");

    // Object 3: Page
    const obj3_offset = pdf.items.len;
    try pdf.appendSlice(allocator, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>\nendobj\n");

    // Object 4: Content stream (uncompressed for simplicity)
    const obj4_offset = pdf.items.len;
    const stream_content = "BT /F1 12 Tf 100 700 Td (Hello World) Tj ET";
    const len_str = try std.fmt.allocPrint(allocator, "{d}", .{stream_content.len});
    defer allocator.free(len_str);
    try pdf.appendSlice(allocator, "4 0 obj\n<< /Length ");
    try pdf.appendSlice(allocator, len_str);
    try pdf.appendSlice(allocator, " >>\nstream\n");
    try pdf.appendSlice(allocator, stream_content);
    try pdf.appendSlice(allocator, "\nendstream\nendobj\n");

    // Xref table
    const xref_offset = pdf.items.len;
    try pdf.appendSlice(allocator, "xref\n0 5\n");

    // Entry format: 10-digit offset, space, 5-digit gen, space, f/n, space, \n = 20 chars
    try pdf.appendSlice(allocator, "0000000000 65535 f \n");

    var buf: [21]u8 = undefined;
    for ([_]usize{ obj1_offset, obj2_offset, obj3_offset, obj4_offset }) |offset| {
        const entry = std.fmt.bufPrint(&buf, "{d:0>10} 00000 n \n", .{offset}) catch continue;
        try pdf.appendSlice(allocator, entry);
    }

    try pdf.appendSlice(allocator, "trailer\n<< /Size 5 /Root 1 0 R >>\n");
    const xref_str = try std.fmt.allocPrint(allocator, "startxref\n{d}\n%%EOF\n", .{xref_offset});
    defer allocator.free(xref_str);
    try pdf.appendSlice(allocator, xref_str);

    return pdf.toOwnedSlice(allocator);
}

test "PDF codec info" {
    var pdf_codec = PdfCodec{};
    const c = codec.Codec.init(&pdf_codec);
    const info = c.info();
    try std.testing.expectEqualStrings("pdf", info.name);
    try std.testing.expectEqualStrings(".pdf", info.extensions[0]);
    try std.testing.expect(info.supports_faithful);
    try std.testing.expect(info.supports_editable);
}

test "expand minimal PDF" {
    const allocator = std.testing.allocator;

    const pdf_data = try buildTestPdf(allocator);
    defer allocator.free(pdf_data);

    var pdf_codec = PdfCodec{};
    const c = codec.Codec.init(&pdf_codec);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const value = try c.expand(arena_alloc, pdf_data, .{ .faithful = false });

    // Verify structure
    const entries = value.object;
    var found_format = false;
    var found_version = false;
    var found_objects = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, "format")) {
            try std.testing.expectEqualStrings("pdf", entry.value.string);
            found_format = true;
        }
        if (std.mem.eql(u8, entry.key, "version")) {
            try std.testing.expectEqualStrings("1.4", entry.value.string);
            found_version = true;
        }
        if (std.mem.eql(u8, entry.key, "objects")) {
            found_objects = true;
            // Should have objects
            try std.testing.expect(entry.value.array.len > 0);
        }
    }
    try std.testing.expect(found_format);
    try std.testing.expect(found_version);
    try std.testing.expect(found_objects);
}

test "expand faithful mode includes _raw" {
    const allocator = std.testing.allocator;

    const pdf_data = try buildTestPdf(allocator);
    defer allocator.free(pdf_data);

    var pdf_codec = PdfCodec{};
    const c = codec.Codec.init(&pdf_codec);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const value = try c.expand(arena_alloc, pdf_data, .{ .faithful = true });

    var found_raw = false;
    for (value.object) |entry| {
        if (std.mem.eql(u8, entry.key, "_raw")) {
            found_raw = true;
            try std.testing.expectEqualSlices(u8, pdf_data, entry.value.string);
        }
    }
    try std.testing.expect(found_raw);
}

test "buildTestPdf produces valid PDF" {
    const allocator = std.testing.allocator;
    const pdf = try buildTestPdf(allocator);
    defer allocator.free(pdf);

    // Check magic
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));
    // Check has xref
    try std.testing.expect(std.mem.indexOf(u8, pdf, "xref") != null);
    // Check has trailer
    try std.testing.expect(std.mem.indexOf(u8, pdf, "trailer") != null);
    // Check has %%EOF
    try std.testing.expect(std.mem.indexOf(u8, pdf, "%%EOF") != null);
}

test {
    _ = parser;
    _ = xref;
    _ = filters;
    _ = serializer;
    _ = zlib;
}
