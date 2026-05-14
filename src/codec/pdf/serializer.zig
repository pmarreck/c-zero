//! PDF serializer (collapse).
//!
//! Converts C0 structured values back into valid PDF binary format.
//! Multi-pass: serialize objects (tracking offsets), write xref table, trailer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("c0_core");
const Value = core.Value;
const Entry = core.Entry;
const codec = @import("../mod.zig");
const CodecError = codec.CodecError;
const CodecOptions = codec.CodecOptions;
const parser = @import("parser.zig");
const filters = @import("filters.zig");

/// Collapse a C0 PDF value back to PDF binary.
pub fn collapsePdf(allocator: Allocator, value: Value, options: CodecOptions) CodecError![]u8 {
    const entries = switch (value) {
        .object => |e| e,
        else => return CodecError.InvalidFormat,
    };

    // Faithful mode: return _raw if present
    if (options.faithful) {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.key, "_raw")) {
                switch (entry.value) {
                    .string => |raw| {
                        return allocator.dupe(u8, raw) catch return CodecError.OutOfMemory;
                    },
                    else => {},
                }
            }
        }
    }

    // Editable mode: rebuild PDF from structure
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    // Get header
    const header = getEntryString(entries, "header") orelse "%PDF-1.4";
    result.appendSlice(allocator, header) catch return CodecError.OutOfMemory;
    result.appendSlice(allocator, "\n%\xe2\xe3\xcf\xd3\n") catch return CodecError.OutOfMemory;

    // Get objects array
    const objects = getEntryArray(entries, "objects") orelse return CodecError.InvalidFormat;

    // Phase 1 & 2: Serialize objects, record offsets
    var offsets: std.ArrayListUnmanaged(ObjOffset) = .empty;
    defer offsets.deinit(allocator);

    for (objects) |obj_val| {
        const obj_entries = switch (obj_val) {
            .object => |e| e,
            else => continue,
        };

        const num = getEntryInt(obj_entries, "num") orelse continue;
        const gen = getEntryInt(obj_entries, "gen") orelse 0;

        const offset = result.items.len;
        offsets.append(allocator, .{
            .num = @intCast(num),
            .gen = @intCast(gen),
            .offset = offset,
        }) catch return CodecError.OutOfMemory;

        // Write "N G obj\n"
        writeObjHeader(&result, allocator, @intCast(num), @intCast(gen)) catch return CodecError.OutOfMemory;

        // Get dictionary
        const dict_val = getEntryValue(obj_entries, "dict");
        const stream_data = getEntryBytes(obj_entries, "stream");
        const stream_raw = getEntryBytes(obj_entries, "_stream_raw");

        // Determine stream bytes for output
        var encoded_stream: ?[]u8 = null;
        defer if (encoded_stream) |es| allocator.free(es);

        if (stream_data) |sd| {
            // Re-encode stream through filter chain
            if (dict_val) |dv| {
                const filter_chain = getFilterChain(allocator, dv);
                if (filter_chain.len > 0) {
                    encoded_stream = filters.applyEncodeChain(allocator, sd, filter_chain) catch null;
                }
            }
        }

        const actual_stream = if (encoded_stream) |es|
            es
        else if (stream_data) |sd|
            sd
        else if (stream_raw) |sr|
            sr
        else
            null;

        // Write dictionary (with updated Length if stream present)
        if (dict_val) |dv| {
            writeDictWithLength(&result, allocator, dv, if (actual_stream) |s| s.len else null) catch return CodecError.OutOfMemory;
        } else {
            result.appendSlice(allocator, "<< >>") catch return CodecError.OutOfMemory;
        }
        result.append(allocator, '\n') catch return CodecError.OutOfMemory;

        // Write stream if present
        if (actual_stream) |stream| {
            result.appendSlice(allocator, "stream\n") catch return CodecError.OutOfMemory;
            result.appendSlice(allocator, stream) catch return CodecError.OutOfMemory;
            result.appendSlice(allocator, "\nendstream\n") catch return CodecError.OutOfMemory;
        }

        result.appendSlice(allocator, "endobj\n") catch return CodecError.OutOfMemory;
    }

    // Phase 3: Write xref table
    const xref_offset = result.items.len;

    // Sort offsets by object number
    std.mem.sort(ObjOffset, offsets.items, {}, struct {
        fn lessThan(_: void, a: ObjOffset, b: ObjOffset) bool {
            return a.num < b.num;
        }
    }.lessThan);

    // Determine max object number
    var max_num: u32 = 0;
    for (offsets.items) |off| {
        if (off.num > max_num) max_num = off.num;
    }

    result.appendSlice(allocator, "xref\n") catch return CodecError.OutOfMemory;

    // Write "0 N+1" header
    const xref_header = std.fmt.allocPrint(allocator, "0 {d}\n", .{max_num + 1}) catch return CodecError.OutOfMemory;
    defer allocator.free(xref_header);
    result.appendSlice(allocator, xref_header) catch return CodecError.OutOfMemory;

    // Entry 0: free list head
    result.appendSlice(allocator, "0000000000 65535 f \n") catch return CodecError.OutOfMemory;

    // Entries 1..max_num
    for (1..max_num + 1) |obj_num| {
        var found = false;
        for (offsets.items) |off| {
            if (off.num == obj_num) {
                var entry_buf: [21]u8 = undefined;
                const entry_str = std.fmt.bufPrint(&entry_buf, "{d:0>10} {d:0>5} n \n", .{ off.offset, off.gen }) catch continue;
                result.appendSlice(allocator, entry_str) catch return CodecError.OutOfMemory;
                found = true;
                break;
            }
        }
        if (!found) {
            result.appendSlice(allocator, "0000000000 00000 f \n") catch return CodecError.OutOfMemory;
        }
    }

    // Phase 4: Write trailer
    result.appendSlice(allocator, "trailer\n") catch return CodecError.OutOfMemory;

    // Build trailer dict
    const trailer_val = getEntryValue(entries, "trailer");
    if (trailer_val) |tv| {
        // Update /Size in trailer
        writeTrailerDict(&result, allocator, tv, max_num + 1) catch return CodecError.OutOfMemory;
    } else {
        // Build minimal trailer
        const root_ref = findRootRef(objects);
        const trailer_str = std.fmt.allocPrint(allocator, "<< /Size {d}{s} >>", .{
            max_num + 1,
            if (root_ref) |r| r else "",
        }) catch return CodecError.OutOfMemory;
        defer allocator.free(trailer_str);
        result.appendSlice(allocator, trailer_str) catch return CodecError.OutOfMemory;
    }

    result.append(allocator, '\n') catch return CodecError.OutOfMemory;

    // startxref
    const startxref_str = std.fmt.allocPrint(allocator, "startxref\n{d}\n%%EOF\n", .{xref_offset}) catch return CodecError.OutOfMemory;
    defer allocator.free(startxref_str);
    result.appendSlice(allocator, startxref_str) catch return CodecError.OutOfMemory;

    return result.toOwnedSlice(allocator) catch return CodecError.OutOfMemory;
}

const ObjOffset = struct {
    num: u32,
    gen: u16,
    offset: usize,
};

// ============================================================================
// PDF value serialization
// ============================================================================

/// Write a PDF value to output.
fn writePdfValue(result: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: Value) !void {
    switch (value) {
        .string => |s| {
            try writePdfScalar(result, allocator, s);
        },
        .array => |arr| {
            try result.appendSlice(allocator, "[ ");
            for (arr) |item| {
                try writePdfValue(result, allocator, item);
                try result.append(allocator, ' ');
            }
            try result.append(allocator, ']');
        },
        .object => |entries| {
            // Check if this is an indirect reference: {ref:N, gen:G}
            if (isIndirectRef(entries)) {
                const ref_num = getEntryString(entries, "ref") orelse "0";
                const ref_gen = getEntryString(entries, "gen") orelse "0";
                try result.appendSlice(allocator, ref_num);
                try result.append(allocator, ' ');
                try result.appendSlice(allocator, ref_gen);
                try result.appendSlice(allocator, " R");
            } else {
                // Regular dictionary
                try result.appendSlice(allocator, "<< ");
                for (entries) |entry| {
                    try result.append(allocator, '/');
                    try result.appendSlice(allocator, entry.key);
                    try result.append(allocator, ' ');
                    try writePdfValue(result, allocator, entry.value);
                    try result.append(allocator, ' ');
                }
                try result.appendSlice(allocator, ">>");
            }
        },
    }
}

/// Write a scalar value with appropriate PDF type.
fn writePdfScalar(result: *std.ArrayListUnmanaged(u8), allocator: Allocator, s: []const u8) !void {
    // Check for special values
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "null")) {
        try result.appendSlice(allocator, s);
        return;
    }

    // Check if it's a number
    if (isNumber(s)) {
        try result.appendSlice(allocator, s);
        return;
    }

    // Check if it looks like a PDF name (no spaces, no special chars requiring escaping)
    if (isPdfNameSafe(s)) {
        // Could be a name; context-dependent. When used as dict value, wrap as string.
        // But when this is a dict key, the caller adds / prefix.
        // For dict values, use (string) syntax.
        try result.append(allocator, '(');
        try writePdfStringEscaped(result, allocator, s);
        try result.append(allocator, ')');
        return;
    }

    // General string
    try result.append(allocator, '(');
    try writePdfStringEscaped(result, allocator, s);
    try result.append(allocator, ')');
}

/// Write a string with PDF escape sequences.
fn writePdfStringEscaped(result: *std.ArrayListUnmanaged(u8), allocator: Allocator, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '(' => try result.appendSlice(allocator, "\\("),
            ')' => try result.appendSlice(allocator, "\\)"),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            0x08 => try result.appendSlice(allocator, "\\b"),
            0x0C => try result.appendSlice(allocator, "\\f"),
            else => {
                if (ch < 0x20 or ch > 0x7E) {
                    // Use octal escape for non-printable
                    var octal: [4]u8 = undefined;
                    const len = std.fmt.bufPrint(&octal, "\\{o:0>3}", .{ch}) catch unreachable;
                    try result.appendSlice(allocator, len);
                } else {
                    try result.append(allocator, ch);
                }
            },
        }
    }
}

/// Check if a string represents a number.
fn isNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '+' or s[0] == '-') i = 1;
    if (i >= s.len) return false;
    var has_digit = false;
    var has_dot = false;
    while (i < s.len) {
        if (s[i] >= '0' and s[i] <= '9') {
            has_digit = true;
        } else if (s[i] == '.' and !has_dot) {
            has_dot = true;
        } else {
            return false;
        }
        i += 1;
    }
    return has_digit;
}

/// Check if a string is safe to use as a PDF name (no escaping needed).
fn isPdfNameSafe(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (ch <= ' ' or ch >= 127) return false;
        if (ch == '(' or ch == ')' or ch == '<' or ch == '>' or
            ch == '[' or ch == ']' or ch == '{' or ch == '}' or
            ch == '/' or ch == '%' or ch == '#') return false;
    }
    return true;
}

/// Check if entries represent an indirect reference {ref:N, gen:G}.
fn isIndirectRef(entries: []const Entry) bool {
    if (entries.len != 2) return false;
    var has_ref = false;
    var has_gen = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, "ref")) has_ref = true;
        if (std.mem.eql(u8, entry.key, "gen")) has_gen = true;
    }
    return has_ref and has_gen;
}

// ============================================================================
// Internal helpers
// ============================================================================

fn writeObjHeader(result: *std.ArrayListUnmanaged(u8), allocator: Allocator, num: u32, gen: u16) !void {
    const header = std.fmt.allocPrint(allocator, "{d} {d} obj\n", .{ num, gen }) catch return error.OutOfMemory;
    defer allocator.free(header);
    try result.appendSlice(allocator, header);
}

/// Write dictionary, optionally overriding /Length.
fn writeDictWithLength(result: *std.ArrayListUnmanaged(u8), allocator: Allocator, dict: Value, stream_len: ?usize) !void {
    const entries = switch (dict) {
        .object => |e| e,
        else => {
            try result.appendSlice(allocator, "<< >>");
            return;
        },
    };

    try result.appendSlice(allocator, "<< ");
    var wrote_length = false;

    for (entries) |entry| {
        try result.append(allocator, '/');
        try result.appendSlice(allocator, entry.key);
        try result.append(allocator, ' ');

        if (std.mem.eql(u8, entry.key, "Length") and stream_len != null) {
            // Override Length
            const len_str = std.fmt.allocPrint(allocator, "{d}", .{stream_len.?}) catch return error.OutOfMemory;
            defer allocator.free(len_str);
            try result.appendSlice(allocator, len_str);
            wrote_length = true;
        } else {
            // Check if this is a dictionary value that should be a PDF name
            switch (entry.value) {
                .string => |s| {
                    // Dictionary values: detect if this should be a name
                    // Heuristic: if it's a known PDF name-like value and is name-safe
                    if (isDictValueName(entry.key, s)) {
                        try result.append(allocator, '/');
                        try result.appendSlice(allocator, s);
                    } else {
                        try writePdfScalar(result, allocator, s);
                    }
                },
                else => try writePdfValue(result, allocator, entry.value),
            }
        }
        try result.append(allocator, ' ');
    }

    // Add /Length if not present and stream exists
    if (!wrote_length and stream_len != null) {
        const len_str = std.fmt.allocPrint(allocator, "/Length {d} ", .{stream_len.?}) catch return error.OutOfMemory;
        defer allocator.free(len_str);
        try result.appendSlice(allocator, len_str);
    }

    try result.appendSlice(allocator, ">>");
}

/// Determine if a dictionary value should be serialized as a PDF name.
/// Known PDF keys that take name values.
fn isDictValueName(key: []const u8, value: []const u8) bool {
    // These keys always have name values in PDF
    const name_keys = [_][]const u8{
        "Type",     "Subtype",  "S",         "Filter",
        "BaseFont", "Encoding", "ColorSpace", "Intent",
    };

    for (name_keys) |nk| {
        if (std.mem.eql(u8, key, nk)) {
            return isPdfNameSafe(value);
        }
    }

    // If the value matches a known PDF name pattern (starts with uppercase, no spaces)
    if (value.len > 0 and value[0] >= 'A' and value[0] <= 'Z' and isPdfNameSafe(value)) {
        // Check if it looks like a standard PDF name
        if (std.mem.eql(u8, value, "Catalog") or
            std.mem.eql(u8, value, "Pages") or
            std.mem.eql(u8, value, "Page") or
            std.mem.eql(u8, value, "Font") or
            std.mem.eql(u8, value, "XObject") or
            std.mem.eql(u8, value, "Image") or
            std.mem.eql(u8, value, "FlateDecode") or
            std.mem.eql(u8, value, "DCTDecode") or
            std.mem.eql(u8, value, "ASCII85Decode") or
            std.mem.eql(u8, value, "ASCIIHexDecode") or
            std.mem.eql(u8, value, "LZWDecode") or
            std.mem.eql(u8, value, "RunLengthDecode") or
            std.mem.eql(u8, value, "Type1") or
            std.mem.eql(u8, value, "TrueType") or
            std.mem.eql(u8, value, "CIDFontType0") or
            std.mem.eql(u8, value, "CIDFontType2") or
            std.mem.eql(u8, value, "DeviceRGB") or
            std.mem.eql(u8, value, "DeviceCMYK") or
            std.mem.eql(u8, value, "DeviceGray"))
        {
            return true;
        }
    }

    return false;
}

/// Write trailer dictionary, updating /Size.
fn writeTrailerDict(result: *std.ArrayListUnmanaged(u8), allocator: Allocator, trailer: Value, size: u32) !void {
    const entries = switch (trailer) {
        .object => |e| e,
        else => {
            const str = std.fmt.allocPrint(allocator, "<< /Size {d} >>", .{size}) catch return error.OutOfMemory;
            defer allocator.free(str);
            try result.appendSlice(allocator, str);
            return;
        },
    };

    try result.appendSlice(allocator, "<< ");
    var wrote_size = false;

    for (entries) |entry| {
        // Skip xref-stream-specific keys in trailer output
        if (std.mem.eql(u8, entry.key, "Type") or
            std.mem.eql(u8, entry.key, "W") or
            std.mem.eql(u8, entry.key, "Index") or
            std.mem.eql(u8, entry.key, "Filter") or
            std.mem.eql(u8, entry.key, "Length") or
            std.mem.eql(u8, entry.key, "DecodeParms"))
        {
            continue;
        }

        try result.append(allocator, '/');
        try result.appendSlice(allocator, entry.key);
        try result.append(allocator, ' ');

        if (std.mem.eql(u8, entry.key, "Size")) {
            const size_str = std.fmt.allocPrint(allocator, "{d}", .{size}) catch return error.OutOfMemory;
            defer allocator.free(size_str);
            try result.appendSlice(allocator, size_str);
            wrote_size = true;
        } else if (std.mem.eql(u8, entry.key, "Prev")) {
            // Skip /Prev — we flatten to single xref
            continue;
        } else {
            try writePdfValue(result, allocator, entry.value);
        }
        try result.append(allocator, ' ');
    }

    if (!wrote_size) {
        const size_str = std.fmt.allocPrint(allocator, "/Size {d} ", .{size}) catch return error.OutOfMemory;
        defer allocator.free(size_str);
        try result.appendSlice(allocator, size_str);
    }

    try result.appendSlice(allocator, ">>");
}

fn getEntryString(entries: []const Entry, key: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            switch (entry.value) {
                .string => |s| return s,
                else => return null,
            }
        }
    }
    return null;
}

fn getEntryBytes(entries: []const Entry, key: []const u8) ?[]const u8 {
    return getEntryString(entries, key);
}

fn getEntryInt(entries: []const Entry, key: []const u8) ?usize {
    const s = getEntryString(entries, key) orelse return null;
    return std.fmt.parseInt(usize, s, 10) catch null;
}

fn getEntryArray(entries: []const Entry, key: []const u8) ?[]const Value {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            switch (entry.value) {
                .array => |a| return a,
                else => return null,
            }
        }
    }
    return null;
}

fn getEntryValue(entries: []const Entry, key: []const u8) ?Value {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

fn findRootRef(objects: []const Value) ?[]const u8 {
    _ = objects;
    // Find Catalog object and build " /Root N 0 R" string
    // This is a simplified version; full implementation would search objects
    return null;
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
                        chain.append(allocator, filters.detectFilter(name)) catch return &.{};
                    },
                    else => {},
                }
            }
            return chain.toOwnedSlice(allocator) catch return &.{};
        },
        else => return &.{},
    }
}

// ============================================================================
// Tests
// ============================================================================

test "isNumber" {
    try std.testing.expect(isNumber("42"));
    try std.testing.expect(isNumber("3.14"));
    try std.testing.expect(isNumber("-1"));
    try std.testing.expect(isNumber("+0.5"));
    try std.testing.expect(!isNumber("hello"));
    try std.testing.expect(!isNumber(""));
    try std.testing.expect(!isNumber("12a"));
}

test "isIndirectRef" {
    const ref_entries = [_]Entry{
        .{ .key = "ref", .value = .{ .string = "5" } },
        .{ .key = "gen", .value = .{ .string = "0" } },
    };
    try std.testing.expect(isIndirectRef(&ref_entries));

    const dict_entries = [_]Entry{
        .{ .key = "Type", .value = .{ .string = "Catalog" } },
    };
    try std.testing.expect(!isIndirectRef(&dict_entries));
}

test "writePdfValue number" {
    const allocator = std.testing.allocator;
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    try writePdfValue(&result, allocator, .{ .string = "42" });
    try std.testing.expectEqualStrings("42", result.items);
}

test "writePdfValue indirect ref" {
    const allocator = std.testing.allocator;
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    const ref_entries = try allocator.alloc(Entry, 2);
    defer allocator.free(ref_entries);
    ref_entries[0] = .{ .key = "ref", .value = .{ .string = "5" } };
    ref_entries[1] = .{ .key = "gen", .value = .{ .string = "0" } };

    try writePdfValue(&result, allocator, .{ .object = ref_entries });
    try std.testing.expectEqualStrings("5 0 R", result.items);
}

test "collapse minimal PDF" {
    const allocator = std.testing.allocator;

    // Build a minimal C0 PDF structure
    const catalog_dict_entries = try allocator.alloc(Entry, 2);
    catalog_dict_entries[0] = .{ .key = "Type", .value = .{ .string = "Catalog" } };
    const pages_ref = try allocator.alloc(Entry, 2);
    pages_ref[0] = .{ .key = "ref", .value = .{ .string = "2" } };
    pages_ref[1] = .{ .key = "gen", .value = .{ .string = "0" } };
    catalog_dict_entries[1] = .{ .key = "Pages", .value = .{ .object = pages_ref } };

    const obj1_entries = try allocator.alloc(Entry, 3);
    obj1_entries[0] = .{ .key = "num", .value = .{ .string = "1" } };
    obj1_entries[1] = .{ .key = "gen", .value = .{ .string = "0" } };
    obj1_entries[2] = .{ .key = "dict", .value = .{ .object = catalog_dict_entries } };

    const pages_dict = try allocator.alloc(Entry, 1);
    pages_dict[0] = .{ .key = "Type", .value = .{ .string = "Pages" } };

    const obj2_entries = try allocator.alloc(Entry, 3);
    obj2_entries[0] = .{ .key = "num", .value = .{ .string = "2" } };
    obj2_entries[1] = .{ .key = "gen", .value = .{ .string = "0" } };
    obj2_entries[2] = .{ .key = "dict", .value = .{ .object = pages_dict } };

    const objects = try allocator.alloc(Value, 2);
    objects[0] = .{ .object = obj1_entries };
    objects[1] = .{ .object = obj2_entries };

    const trailer_entries = try allocator.alloc(Entry, 2);
    const root_ref = try allocator.alloc(Entry, 2);
    root_ref[0] = .{ .key = "ref", .value = .{ .string = "1" } };
    root_ref[1] = .{ .key = "gen", .value = .{ .string = "0" } };
    trailer_entries[0] = .{ .key = "Size", .value = .{ .string = "3" } };
    trailer_entries[1] = .{ .key = "Root", .value = .{ .object = root_ref } };

    const top_entries = try allocator.alloc(Entry, 5);
    top_entries[0] = .{ .key = "format", .value = .{ .string = "pdf" } };
    top_entries[1] = .{ .key = "version", .value = .{ .string = "1.4" } };
    top_entries[2] = .{ .key = "header", .value = .{ .string = "%PDF-1.4" } };
    top_entries[3] = .{ .key = "objects", .value = .{ .array = objects } };
    top_entries[4] = .{ .key = "trailer", .value = .{ .object = trailer_entries } };

    const value = Value{ .object = top_entries };

    const pdf_bytes = try collapsePdf(allocator, value, .{ .faithful = false });
    defer allocator.free(pdf_bytes);

    // Free all the structures
    allocator.free(top_entries);
    allocator.free(trailer_entries);
    allocator.free(root_ref);
    allocator.free(objects);
    allocator.free(obj2_entries);
    allocator.free(pages_dict);
    allocator.free(obj1_entries);
    allocator.free(catalog_dict_entries);
    allocator.free(pages_ref);

    // Verify output
    try std.testing.expect(std.mem.startsWith(u8, pdf_bytes, "%PDF-1.4"));
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "xref") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "trailer") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "%%EOF") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "1 0 obj") != null);
    try std.testing.expect(std.mem.indexOf(u8, pdf_bytes, "2 0 obj") != null);
}
