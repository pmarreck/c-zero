//! BG3 LSF (Larian Structured Format) Parser/Writer
//!
//! The LSF format is a structured binary format used by Baldur's Gate 3 to
//! store game data (nodes with typed attributes in a tree structure).
//!
//! Format structure:
//!   - Header: magic "LSOF", version, section sizes
//!   - Strings section (LZ4 block compressed): hash table of strings
//!   - Nodes section (LZ4 chunked): node tree
//!   - Attributes section (LZ4 chunked): attribute metadata
//!   - Values section (LZ4 chunked): attribute raw data
//!
//! Supports BG3 Release versions (V5-V7).

const std = @import("std");
const core = @import("c0_core");
const types = @import("types.zig");
const lz4 = @import("lz4.zig");
const zstd = @import("zstd.zig");

const Value = core.Value;
const Entry = core.Entry;

pub const LsfError = error{
    InvalidMagic,
    UnsupportedVersion,
    TruncatedInput,
    DecompressionFailed,
    InvalidStringTable,
    InvalidNodeTree,
    InvalidAttribute,
    OutOfMemory,
};

const LSF_MAGIC = "LSOF";
const LSF_CHUNK_SIZE: usize = 64 * 1024; // 64KB chunks

/// Metadata format (determines whether keys section is present)
const MetadataFormat = enum(u32) {
    none = 0,
    keys_and_adjacency = 1,
    none2 = 2,
    _,
};

/// LSF header (V5-V7)
const LsfHeader = struct {
    version: u32,
    engine_version: i64, // V5+ uses 64-bit, V1-V4 uses 32-bit (promoted to i64)
    strings_uncompressed_size: u32,
    strings_compressed_size: u32,
    keys_uncompressed_size: u32, // V6+: appears in header between strings and nodes
    keys_compressed_size: u32,
    nodes_uncompressed_size: u32,
    nodes_compressed_size: u32,
    attributes_uncompressed_size: u32,
    attributes_compressed_size: u32,
    values_uncompressed_size: u32,
    values_compressed_size: u32,
    compression_flags: u8,
    metadata_format: MetadataFormat,
    has_keys_section: bool, // derived: version >= 6 AND metadata_format == keys_and_adjacency
};

/// Parsed node from the nodes section
const RawNode = struct {
    name_hash_index: u32,
    first_attribute_index: i32,
    parent_index: i32,
    next_sibling_index: i32, // V3 format
};

/// Parsed attribute from the attributes section
const RawAttribute = struct {
    name_hash_index: u32,
    type_and_length: u32,
    node_index: u32, // V3: which node this attribute belongs to
    next_attribute_index: i32, // V3: linked list within a node
    data_offset: u32,

    fn attrType(self: RawAttribute) types.AttributeType {
        return @enumFromInt(@as(u8, @intCast(self.type_and_length & 0x3F)));
    }

    fn dataLength(self: RawAttribute) u32 {
        return self.type_and_length >> 6;
    }
};

/// Parse an LSF file and return a C0 Value
pub fn expand(allocator: std.mem.Allocator, data: []const u8) LsfError!Value {
    // Validate magic
    if (data.len < 4 or !std.mem.eql(u8, data[0..4], LSF_MAGIC)) {
        return LsfError.InvalidMagic;
    }

    // Parse header
    const header = try parseHeader(data);

    // Calculate section offsets
    var offset: usize = headerSize(header.version);

    // Decompress sections - data order on disk: strings, nodes, attributes, values, keys
    // (keys come LAST on disk even though they appear second in the V6+ header)
    const strings_data = try decompressSection(
        allocator, data, &offset,
        header.strings_compressed_size, header.strings_uncompressed_size,
        header.compression_flags, true,
    );
    defer allocator.free(strings_data);

    const nodes_data = try decompressSection(
        allocator, data, &offset,
        header.nodes_compressed_size, header.nodes_uncompressed_size,
        header.compression_flags, false,
    );
    defer allocator.free(nodes_data);

    const attributes_data = try decompressSection(
        allocator, data, &offset,
        header.attributes_compressed_size, header.attributes_uncompressed_size,
        header.compression_flags, false,
    );
    defer allocator.free(attributes_data);

    const values_data = try decompressSection(
        allocator, data, &offset,
        header.values_compressed_size, header.values_uncompressed_size,
        header.compression_flags, false,
    );
    defer allocator.free(values_data);

    // Keys section (V6+ with keys_and_adjacency metadata format) - data comes LAST on disk
    var keys_data: ?[]u8 = null;
    if (header.has_keys_section) {
        keys_data = try decompressSection(
            allocator,
            data,
            &offset,
            header.keys_compressed_size,
            header.keys_uncompressed_size,
            header.compression_flags,
            false,
        );
    }
    defer if (keys_data) |k| allocator.free(k);

    // Parse string table
    var string_table = try parseStringTable(allocator, strings_data);
    defer string_table.deinit(allocator);

    // Determine format based on metadata_format
    const has_sibling_data = header.metadata_format == .keys_and_adjacency;

    // Parse nodes
    const nodes = try parseNodes(allocator, nodes_data, has_sibling_data);
    defer allocator.free(nodes);

    // Parse attributes
    const attributes = try parseAttributes(allocator, attributes_data, has_sibling_data);
    defer allocator.free(attributes);

    // Build tree as C0 Value
    return buildTree(allocator, header.version, nodes, attributes, string_table, values_data, has_sibling_data);
}

fn headerSize(version: u32) usize {
    // Magic(4) + Version(4) + EngineVersion + Metadata + CompressionFlags(1) + Unknown2(1) + Unknown3(2) + MetadataFormat(4)
    const engine_ver_size: usize = if (version >= 5) 8 else 4;
    const sections: usize = if (version >= 6) 5 * 8 else 4 * 8; // 5 sections (with keys) or 4
    return 4 + 4 + engine_ver_size + sections + 1 + 1 + 2 + 4;
}

fn parseHeader(data: []const u8) LsfError!LsfHeader {
    if (data.len < 8) return LsfError.TruncatedInput;

    const version = std.mem.readInt(u32, data[4..8], .little);
    if (version < 5 or version > 7) return LsfError.UnsupportedVersion;

    var pos: usize = 8;
    const min_header = headerSize(version);
    if (data.len < min_header) return LsfError.TruncatedInput;

    var header: LsfHeader = undefined;
    header.version = version;

    // Engine version (V5+: 8 bytes, V1-V4: 4 bytes)
    if (version >= 5) {
        header.engine_version = std.mem.readInt(i64, data[pos..][0..8], .little);
        pos += 8;
    } else {
        header.engine_version = @as(i64, std.mem.readInt(i32, data[pos..][0..4], .little));
        pos += 4;
    }

    // Strings section
    header.strings_uncompressed_size = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;
    header.strings_compressed_size = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    // Keys section (V6+: in header between strings and nodes)
    if (version >= 6) {
        header.keys_uncompressed_size = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
        header.keys_compressed_size = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;
    } else {
        header.keys_uncompressed_size = 0;
        header.keys_compressed_size = 0;
    }

    // Nodes section
    header.nodes_uncompressed_size = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;
    header.nodes_compressed_size = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    // Attributes section
    header.attributes_uncompressed_size = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;
    header.attributes_compressed_size = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    // Values section
    header.values_uncompressed_size = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;
    header.values_compressed_size = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    // Compression flags (1 byte) + Unknown2 (1 byte) + Unknown3 (2 bytes)
    header.compression_flags = data[pos];
    pos += 4; // skip flags + unknown2 + unknown3

    // Metadata format
    header.metadata_format = @enumFromInt(std.mem.readInt(u32, data[pos..][0..4], .little));

    // Derive has_keys_section
    header.has_keys_section = version >= 6 and header.metadata_format == .keys_and_adjacency;

    return header;
}

fn decompressSection(
    allocator: std.mem.Allocator,
    data: []const u8,
    offset: *usize,
    compressed_size: u32,
    uncompressed_size: u32,
    compression_flags: u8,
    is_block_mode: bool,
) LsfError![]u8 {
    if (compressed_size == 0 and uncompressed_size == 0) {
        return allocator.alloc(u8, 0) catch return LsfError.OutOfMemory;
    }

    // Special case: compressed_size == 0 but uncompressed_size != 0
    // means data is stored uncompressed (read uncompressed_size bytes)
    if (compressed_size == 0) {
        if (offset.* + uncompressed_size > data.len) return LsfError.TruncatedInput;
        const raw = data[offset.*..][0..uncompressed_size];
        offset.* += uncompressed_size;
        return allocator.dupe(u8, raw) catch return LsfError.OutOfMemory;
    }

    if (offset.* + compressed_size > data.len) return LsfError.TruncatedInput;

    const section_data = data[offset.*..][0..compressed_size];
    offset.* += compressed_size;

    const compression_method = compression_flags & 0x0F;
    return switch (compression_method) {
        0 => allocator.dupe(u8, section_data) catch return LsfError.OutOfMemory, // no compression
        1, 2 => if (is_block_mode) // LZ4 / LZ4 HC
            lz4.decompressBlock(allocator, section_data, uncompressed_size) catch return LsfError.DecompressionFailed
        else
            // Non-string sections use LZ4 frame format (magic 0x04224D18)
            lz4.decompressFrame(allocator, section_data, uncompressed_size) catch return LsfError.DecompressionFailed,
        3 => zstd.decompress(allocator, section_data, uncompressed_size) catch return LsfError.DecompressionFailed, // zstd
        else => return LsfError.DecompressionFailed,
    };
}

/// String hash table: maps packed hash index (bucket << 16 | chain_pos) to string
const StringTable = std.AutoHashMapUnmanaged(u32, []const u8);

/// Parse the string hash table
/// Format: num_buckets (u32), then for each bucket:
///   chain_count (u16), then for each chain entry: string_length (u16) + string_data
fn parseStringTable(allocator: std.mem.Allocator, data: []const u8) LsfError!StringTable {
    if (data.len < 4) return LsfError.InvalidStringTable;

    const num_buckets = std.mem.readInt(u32, data[0..4], .little);
    var pos: usize = 4;

    var table: StringTable = .{};
    errdefer table.deinit(allocator);

    var bucket: u32 = 0;
    while (bucket < num_buckets) : (bucket += 1) {
        if (pos + 2 > data.len) return LsfError.InvalidStringTable;
        const chain_count = std.mem.readInt(u16, data[pos..][0..2], .little);
        pos += 2;

        var chain_pos: u16 = 0;
        while (chain_pos < chain_count) : (chain_pos += 1) {
            if (pos + 2 > data.len) return LsfError.InvalidStringTable;
            const str_len = std.mem.readInt(u16, data[pos..][0..2], .little);
            pos += 2;

            if (pos + str_len > data.len) return LsfError.InvalidStringTable;
            const str = allocator.dupe(u8, data[pos..][0..str_len]) catch return LsfError.OutOfMemory;
            pos += str_len;

            const packed_index = (bucket << 16) | @as(u32, chain_pos);
            table.put(allocator, packed_index, str) catch return LsfError.OutOfMemory;
        }
    }

    return table;
}

/// Parse node entries from the nodes section
/// V2 (no adjacency): 12 bytes (name_hash, first_attr, parent)
/// V3 (with adjacency): 16 bytes (name_hash, first_attr, parent, next_sibling)
fn parseNodes(allocator: std.mem.Allocator, data: []const u8, has_sibling_data: bool) LsfError![]RawNode {
    const node_size: usize = if (has_sibling_data) 16 else 12;
    if (data.len == 0) return allocator.alloc(RawNode, 0) catch return LsfError.OutOfMemory;

    const count = data.len / node_size;
    const nodes = allocator.alloc(RawNode, count) catch return LsfError.OutOfMemory;

    for (0..count) |i| {
        const base = i * node_size;
        if (base + node_size > data.len) return LsfError.InvalidNodeTree;
        nodes[i] = .{
            .name_hash_index = std.mem.readInt(u32, data[base..][0..4], .little),
            .first_attribute_index = std.mem.readInt(i32, data[base + 4 ..][0..4], .little),
            .parent_index = std.mem.readInt(i32, data[base + 8 ..][0..4], .little),
            .next_sibling_index = if (has_sibling_data)
                std.mem.readInt(i32, data[base + 12 ..][0..4], .little)
            else
                -1, // V2: no sibling data, will be computed later
        };
    }

    return nodes;
}

/// Parse attribute entries from the attributes section
/// V2 (no adjacency): 12 bytes (name_hash, type_and_length, node_index)
///   - data_offset computed by accumulating data_length per node
/// V3 (with adjacency): 16 bytes (name_hash, type_and_length, next_attribute_index, offset)
fn parseAttributes(allocator: std.mem.Allocator, data: []const u8, has_sibling_data: bool) LsfError![]RawAttribute {
    const attr_size: usize = if (has_sibling_data) 16 else 12;
    if (data.len == 0) return allocator.alloc(RawAttribute, 0) catch return LsfError.OutOfMemory;

    const count = data.len / attr_size;
    const attrs = allocator.alloc(RawAttribute, count) catch return LsfError.OutOfMemory;

    if (has_sibling_data) {
        // V3: name(4) + type_and_length(4) + next_attribute_index(4) + offset(4)
        for (0..count) |i| {
            const base = i * attr_size;
            if (base + attr_size > data.len) return LsfError.InvalidAttribute;
            attrs[i] = .{
                .name_hash_index = std.mem.readInt(u32, data[base..][0..4], .little),
                .type_and_length = std.mem.readInt(u32, data[base + 4 ..][0..4], .little),
                .node_index = 0, // V3: not stored, inferred from linked list
                .next_attribute_index = std.mem.readInt(i32, data[base + 8 ..][0..4], .little),
                .data_offset = std.mem.readInt(u32, data[base + 12 ..][0..4], .little),
            };
        }
    } else {
        // V2: name(4) + type_and_length(4) + node_index(4)
        // data_offset is computed by accumulating lengths
        var running_offset: u32 = 0;
        for (0..count) |i| {
            const base = i * attr_size;
            if (base + attr_size > data.len) return LsfError.InvalidAttribute;
            const type_and_length = std.mem.readInt(u32, data[base + 4 ..][0..4], .little);
            attrs[i] = .{
                .name_hash_index = std.mem.readInt(u32, data[base..][0..4], .little),
                .type_and_length = type_and_length,
                .node_index = std.mem.readInt(u32, data[base + 8 ..][0..4], .little),
                .next_attribute_index = -1, // V2: no linked list
                .data_offset = running_offset,
            };
            running_offset += type_and_length >> 6;
        }
    }

    return attrs;
}

/// Resolve a packed string hash index to a string from the string table
fn resolveString(string_table: StringTable, hash_index: u32) []const u8 {
    return string_table.get(hash_index) orelse "???";
}

/// Append a decoded attribute entry to the list
fn appendAttribute(
    allocator: std.mem.Allocator,
    attr_entries: *std.ArrayListUnmanaged(Entry),
    attr: RawAttribute,
    string_table: StringTable,
    values_data: []const u8,
) LsfError!void {
    const attr_name = resolveString(string_table, attr.name_hash_index);
    const attr_type = attr.attrType();
    const data_len = attr.dataLength();

    if (attr.data_offset + data_len <= values_data.len) {
        const attr_data = values_data[attr.data_offset..][0..data_len];

        const attr_value = blk: {
            if (attr_type == .TranslatedString or attr_type == .TranslatedFSString) {
                break :blk types.decodeTranslatedString(allocator, attr_data) catch {
                    break :blk Value{ .string = allocator.dupe(u8, attr_data) catch return LsfError.OutOfMemory };
                };
            } else if (attr_type == .IVec2 or attr_type == .IVec3 or attr_type == .IVec4 or
                attr_type == .Vec2 or attr_type == .Vec3 or attr_type == .Vec4)
            {
                break :blk types.decodeVector(allocator, attr_type, attr_data) catch {
                    break :blk Value{ .string = allocator.dupe(u8, attr_data) catch return LsfError.OutOfMemory };
                };
            } else {
                const scalar = types.decodeScalar(allocator, attr_type, attr_data) catch {
                    break :blk Value{ .string = allocator.dupe(u8, attr_data) catch return LsfError.OutOfMemory };
                };
                break :blk Value{ .string = scalar };
            }
        };

        const typed_entries = allocator.alloc(Entry, 2) catch return LsfError.OutOfMemory;
        typed_entries[0] = .{ .key = "_type", .value = .{ .string = attr_type.name() } };
        typed_entries[1] = .{ .key = "_value", .value = attr_value };

        attr_entries.append(allocator, .{
            .key = attr_name,
            .value = Value{ .object = typed_entries },
        }) catch return LsfError.OutOfMemory;
    }
}

/// Build a C0 Value tree from parsed LSF data
fn buildTree(
    allocator: std.mem.Allocator,
    version: u32,
    nodes: []const RawNode,
    attributes: []const RawAttribute,
    string_table: StringTable,
    values_data: []const u8,
    has_sibling_data: bool,
) LsfError!Value {
    if (nodes.len == 0) {
        const entries = allocator.alloc(Entry, 2) catch return LsfError.OutOfMemory;
        entries[0] = .{ .key = "format", .value = .{ .string = "bg3-lsf" } };
        const ver_str = std.fmt.allocPrint(allocator, "{d}", .{version}) catch return LsfError.OutOfMemory;
        entries[1] = .{ .key = "version", .value = .{ .string = ver_str } };
        return Value{ .object = entries };
    }

    // Build nodes recursively, starting from root (index 0)
    const root = try buildNode(allocator, 0, nodes, attributes, string_table, values_data, has_sibling_data);

    const ver_str = std.fmt.allocPrint(allocator, "{d}", .{version}) catch return LsfError.OutOfMemory;
    const entries = allocator.alloc(Entry, 3) catch return LsfError.OutOfMemory;
    entries[0] = .{ .key = "format", .value = .{ .string = "bg3-lsf" } };
    entries[1] = .{ .key = "version", .value = .{ .string = ver_str } };
    entries[2] = .{ .key = "root", .value = root };

    return Value{ .object = entries };
}

/// Recursively build a C0 Value for a node and its children
fn buildNode(
    allocator: std.mem.Allocator,
    node_index: usize,
    nodes: []const RawNode,
    attributes: []const RawAttribute,
    string_table: StringTable,
    values_data: []const u8,
    has_sibling_data: bool,
) LsfError!Value {
    if (node_index >= nodes.len) return LsfError.InvalidNodeTree;

    const node = nodes[node_index];
    const node_name = resolveString(string_table, node.name_hash_index);

    // Collect attributes for this node
    var attr_entries: std.ArrayListUnmanaged(Entry) = .{};
    defer attr_entries.deinit(allocator);

    if (has_sibling_data) {
        // V3: follow linked list from first_attribute_index
        var attr_idx = node.first_attribute_index;
        while (attr_idx >= 0 and @as(usize, @intCast(attr_idx)) < attributes.len) {
            const attr = attributes[@intCast(attr_idx)];
            try appendAttribute(allocator, &attr_entries, attr, string_table, values_data);
            attr_idx = attr.next_attribute_index;
        }
    } else {
        // V2: scan all attributes for those belonging to this node
        for (attributes) |attr| {
            if (attr.node_index == @as(u32, @intCast(node_index))) {
                try appendAttribute(allocator, &attr_entries, attr, string_table, values_data);
            }
        }
    }

    // Collect children for this node
    var children: std.ArrayListUnmanaged(Value) = .{};
    defer children.deinit(allocator);

    for (nodes, 0..) |child_node, i| {
        if (child_node.parent_index >= 0 and @as(usize, @intCast(child_node.parent_index)) == node_index) {
            const child_value = try buildNode(allocator, i, nodes, attributes, string_table, values_data, has_sibling_data);
            children.append(allocator, child_value) catch return LsfError.OutOfMemory;
        }
    }

    // Build node object: {_name: "NodeName", _attributes: {...}, _children: [...]}
    const has_attrs = attr_entries.items.len > 0;
    const has_children = children.items.len > 0;
    const entry_count: usize = 1 + @as(usize, if (has_attrs) 1 else 0) + @as(usize, if (has_children) 1 else 0);

    const node_entries = allocator.alloc(Entry, entry_count) catch return LsfError.OutOfMemory;
    var idx: usize = 0;

    node_entries[idx] = .{ .key = "_name", .value = .{ .string = node_name } };
    idx += 1;

    if (has_attrs) {
        const attr_obj_entries = attr_entries.toOwnedSlice(allocator) catch return LsfError.OutOfMemory;
        node_entries[idx] = .{ .key = "_attributes", .value = Value{ .object = attr_obj_entries } };
        idx += 1;
    }

    if (has_children) {
        const children_arr = children.toOwnedSlice(allocator) catch return LsfError.OutOfMemory;
        node_entries[idx] = .{ .key = "_children", .value = Value{ .array = children_arr } };
        idx += 1;
    }

    return Value{ .object = node_entries };
}

/// Collapse a C0 Value back to LSF binary (V7 format, V2 nodes/attributes, zstd compression)
pub fn collapse(allocator: std.mem.Allocator, value: Value) LsfError![]u8 {
    const entries = switch (value) {
        .object => |e| e,
        else => return LsfError.InvalidNodeTree,
    };

    var version: u32 = 7;
    var root_value: ?Value = null;

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, "version")) {
            const ver_str = switch (entry.value) {
                .string => |s| s,
                else => continue,
            };
            version = std.fmt.parseInt(u32, ver_str, 10) catch 7;
        } else if (std.mem.eql(u8, entry.key, "root")) {
            root_value = entry.value;
        }
    }

    // Phase 1: Flatten tree into parallel arrays
    var string_interner: StringInterner = .{};
    defer string_interner.deinit(allocator);
    var flat_nodes: std.ArrayListUnmanaged(FlatNode) = .{};
    defer flat_nodes.deinit(allocator);
    var flat_attrs: std.ArrayListUnmanaged(FlatAttribute) = .{};
    defer flat_attrs.deinit(allocator);
    var values_buf: std.ArrayListUnmanaged(u8) = .{};
    defer values_buf.deinit(allocator);

    if (root_value) |root| {
        try flattenNode(allocator, root, -1, &flat_nodes, &flat_attrs, &values_buf, &string_interner);
    }

    // Phase 2: Build hash table string section
    const strings_raw = try string_interner.buildHashTable(allocator);
    defer allocator.free(strings_raw);

    // Phase 3: Build V2 nodes section (12 bytes each: name_hash + first_attr + parent)
    var nodes_buf: std.ArrayListUnmanaged(u8) = .{};
    defer nodes_buf.deinit(allocator);
    for (flat_nodes.items) |node| {
        var buf: [12]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], node.name_hash_index, .little);
        std.mem.writeInt(i32, buf[4..8], node.first_attribute_index, .little);
        std.mem.writeInt(i32, buf[8..12], node.parent_index, .little);
        nodes_buf.appendSlice(allocator, &buf) catch return LsfError.OutOfMemory;
    }

    // Phase 4: Build V2 attributes section (12 bytes each: name_hash + type_and_length + node_index)
    var attrs_buf: std.ArrayListUnmanaged(u8) = .{};
    defer attrs_buf.deinit(allocator);
    for (flat_attrs.items) |attr| {
        var buf: [12]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], attr.name_hash_index, .little);
        std.mem.writeInt(u32, buf[4..8], attr.type_and_length, .little);
        std.mem.writeInt(u32, buf[8..12], attr.node_index, .little);
        attrs_buf.appendSlice(allocator, &buf) catch return LsfError.OutOfMemory;
    }

    // Phase 5: Compress sections with zstd
    const compression_flags: u8 = 3; // zstd (method 3)
    const zstd_level: c_int = 3;

    const strings_comp = zstd.compress(allocator, strings_raw, zstd_level) catch return LsfError.OutOfMemory;
    defer allocator.free(strings_comp);
    const nodes_comp = zstd.compress(allocator, nodes_buf.items, zstd_level) catch return LsfError.OutOfMemory;
    defer allocator.free(nodes_comp);
    const attrs_comp = zstd.compress(allocator, attrs_buf.items, zstd_level) catch return LsfError.OutOfMemory;
    defer allocator.free(attrs_comp);
    const values_comp = zstd.compress(allocator, values_buf.items, zstd_level) catch return LsfError.OutOfMemory;
    defer allocator.free(values_comp);

    // Phase 6: Assemble V7 header (64 bytes) + section data
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    // Magic + Version
    result.appendSlice(allocator, LSF_MAGIC) catch return LsfError.OutOfMemory;
    appendU32(&result, allocator, version);

    // Engine version (8 bytes for V5+)
    appendU32(&result, allocator, 0); // engine version low
    appendU32(&result, allocator, 0); // engine version high

    // Section sizes: strings
    appendU32(&result, allocator, @intCast(strings_raw.len));
    appendU32(&result, allocator, @intCast(strings_comp.len));

    // Section sizes: keys (V6+, always 0/0 for metadata_format=none)
    appendU32(&result, allocator, 0);
    appendU32(&result, allocator, 0);

    // Section sizes: nodes
    appendU32(&result, allocator, @intCast(nodes_buf.items.len));
    appendU32(&result, allocator, @intCast(nodes_comp.len));

    // Section sizes: attributes
    appendU32(&result, allocator, @intCast(attrs_buf.items.len));
    appendU32(&result, allocator, @intCast(attrs_comp.len));

    // Section sizes: values
    appendU32(&result, allocator, @intCast(values_buf.items.len));
    appendU32(&result, allocator, @intCast(values_comp.len));

    // CompressionFlags(1) + Unknown2(1) + Unknown3(2) + MetadataFormat(4)
    result.append(allocator, compression_flags) catch return LsfError.OutOfMemory;
    result.append(allocator, 0) catch return LsfError.OutOfMemory; // unknown2
    result.appendSlice(allocator, &[_]u8{ 0, 0 }) catch return LsfError.OutOfMemory; // unknown3
    appendU32(&result, allocator, 0); // metadata_format = none

    // Section data (order: strings, nodes, attributes, values)
    result.appendSlice(allocator, strings_comp) catch return LsfError.OutOfMemory;
    result.appendSlice(allocator, nodes_comp) catch return LsfError.OutOfMemory;
    result.appendSlice(allocator, attrs_comp) catch return LsfError.OutOfMemory;
    result.appendSlice(allocator, values_comp) catch return LsfError.OutOfMemory;

    return result.toOwnedSlice(allocator) catch return LsfError.OutOfMemory;
}

fn appendU32(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u32) void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, val, .little);
    list.appendSlice(allocator, &buf) catch {};
}

// ============================================================================
// String hash table for collapse
// ============================================================================

const HASH_BUCKET_COUNT: u32 = 0x200; // 512 buckets

/// BG3/LSLib string hash function: rotate-right + add each character
fn computeHashBucket(name: []const u8) u32 {
    var hash: u32 = 0;
    for (name) |c| {
        hash = (hash >> 1) | ((hash & 1) << 31); // rotate right by 1
        hash +%= c;
    }
    return hash % HASH_BUCKET_COUNT;
}

/// Manages string interning with hash table indices
const StringInterner = struct {
    /// Maps string content to packed hash index (bucket << 16 | chain_pos)
    lookup: std.StringHashMapUnmanaged(u32) = .{},
    /// Strings organized by bucket for serialization
    buckets: [HASH_BUCKET_COUNT]std.ArrayListUnmanaged([]const u8) = [_]std.ArrayListUnmanaged([]const u8){.{}} ** HASH_BUCKET_COUNT,

    fn deinit(self: *StringInterner, allocator: std.mem.Allocator) void {
        self.lookup.deinit(allocator);
        for (&self.buckets) |*bucket| {
            bucket.deinit(allocator);
        }
    }

    /// Intern a string and return its packed hash index
    fn intern(self: *StringInterner, allocator: std.mem.Allocator, s: []const u8) LsfError!u32 {
        if (self.lookup.get(s)) |existing| return existing;

        const bucket_idx = computeHashBucket(s);
        const chain_pos: u16 = @intCast(self.buckets[bucket_idx].items.len);
        const hash_index: u32 = (bucket_idx << 16) | @as(u32, chain_pos);

        self.buckets[bucket_idx].append(allocator, s) catch return LsfError.OutOfMemory;
        self.lookup.put(allocator, s, hash_index) catch return LsfError.OutOfMemory;
        return hash_index;
    }

    /// Serialize to hash table format: num_buckets(u32) + per-bucket: chain_count(u16) + entries(len:u16 + data)
    fn buildHashTable(self: *StringInterner, allocator: std.mem.Allocator) LsfError![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(allocator);

        // Number of buckets
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, HASH_BUCKET_COUNT, .little);
        buf.appendSlice(allocator, &tmp) catch return LsfError.OutOfMemory;

        for (&self.buckets) |*bucket| {
            // Chain count for this bucket
            var cc: [2]u8 = undefined;
            std.mem.writeInt(u16, &cc, @intCast(bucket.items.len), .little);
            buf.appendSlice(allocator, &cc) catch return LsfError.OutOfMemory;

            for (bucket.items) |s| {
                // String length + data
                var sl: [2]u8 = undefined;
                std.mem.writeInt(u16, &sl, @intCast(s.len), .little);
                buf.appendSlice(allocator, &sl) catch return LsfError.OutOfMemory;
                buf.appendSlice(allocator, s) catch return LsfError.OutOfMemory;
            }
        }

        return buf.toOwnedSlice(allocator) catch return LsfError.OutOfMemory;
    }
};

// ============================================================================
// Collapse helpers
// ============================================================================

const FlatNode = struct {
    name_hash_index: u32, // packed hash index into string table
    first_attribute_index: i32,
    parent_index: i32,
};

const FlatAttribute = struct {
    name_hash_index: u32, // packed hash index into string table
    type_and_length: u32,
    node_index: u32,
};

/// Flatten a C0 node tree into parallel arrays for serialization
fn flattenNode(
    allocator: std.mem.Allocator,
    value: Value,
    parent_index: i32,
    flat_nodes: *std.ArrayListUnmanaged(FlatNode),
    flat_attrs: *std.ArrayListUnmanaged(FlatAttribute),
    values_buf: *std.ArrayListUnmanaged(u8),
    interner: *StringInterner,
) LsfError!void {
    const node_entries = switch (value) {
        .object => |e| e,
        else => return LsfError.InvalidNodeTree,
    };

    var node_name: []const u8 = "???";
    var attributes_val: ?Value = null;
    var children_val: ?Value = null;

    for (node_entries) |entry| {
        if (std.mem.eql(u8, entry.key, "_name")) {
            node_name = switch (entry.value) {
                .string => |s| s,
                else => "???",
            };
        } else if (std.mem.eql(u8, entry.key, "_attributes")) {
            attributes_val = entry.value;
        } else if (std.mem.eql(u8, entry.key, "_children")) {
            children_val = entry.value;
        }
    }

    const node_index: u32 = @intCast(flat_nodes.items.len);
    const name_hash = try interner.intern(allocator, node_name);

    flat_nodes.append(allocator, .{
        .name_hash_index = name_hash,
        .first_attribute_index = -1,
        .parent_index = parent_index,
    }) catch return LsfError.OutOfMemory;

    // Process attributes
    if (attributes_val) |attrs_value| {
        const attr_entries = switch (attrs_value) {
            .object => |e| e,
            else => &[_]Entry{},
        };

        var first_attr: i32 = -1;

        for (attr_entries) |attr_entry| {
            const attr_name_hash = try interner.intern(allocator, attr_entry.key);

            var attr_type_name: []const u8 = "string";
            var attr_value_val: Value = attr_entry.value;

            switch (attr_entry.value) {
                .object => |typed_entries| {
                    for (typed_entries) |te| {
                        if (std.mem.eql(u8, te.key, "_type")) {
                            attr_type_name = switch (te.value) {
                                .string => |s| s,
                                else => "string",
                            };
                        } else if (std.mem.eql(u8, te.key, "_value")) {
                            attr_value_val = te.value;
                        }
                    }
                },
                else => {},
            }

            const attr_type = types.AttributeType.fromName(attr_type_name);
            const value_bytes = try encodeAttributeValue(allocator, attr_type, attr_value_val);
            defer allocator.free(value_bytes);

            values_buf.appendSlice(allocator, value_bytes) catch return LsfError.OutOfMemory;

            const attr_index: i32 = @intCast(flat_attrs.items.len);
            if (first_attr == -1) first_attr = attr_index;

            const type_and_length: u32 = (@as(u32, @intCast(value_bytes.len)) << 6) | @as(u32, @intFromEnum(attr_type));

            flat_attrs.append(allocator, .{
                .name_hash_index = attr_name_hash,
                .type_and_length = type_and_length,
                .node_index = node_index,
            }) catch return LsfError.OutOfMemory;
        }

        flat_nodes.items[node_index].first_attribute_index = first_attr;
    }

    // Process children
    if (children_val) |children_value| {
        const children = switch (children_value) {
            .array => |a| a,
            else => &[_]Value{},
        };

        for (children) |child| {
            try flattenNode(allocator, child, @intCast(node_index), flat_nodes, flat_attrs, values_buf, interner);
        }
    }
}

/// Encode a C0 attribute value back to raw bytes
fn encodeAttributeValue(allocator: std.mem.Allocator, attr_type: types.AttributeType, value: Value) LsfError![]u8 {
    switch (value) {
        .string => |s| {
            // String types: write string + null terminator
            if (attr_type == .String or attr_type == .Path or attr_type == .FixedString or
                attr_type == .LSString or attr_type == .WString or attr_type == .LSWString)
            {
                const buf = allocator.alloc(u8, s.len + 1) catch return LsfError.OutOfMemory;
                @memcpy(buf[0..s.len], s);
                buf[s.len] = 0; // null terminator
                return buf;
            }

            return types.encodeScalar(allocator, attr_type, s) catch {
                return allocator.dupe(u8, s) catch return LsfError.OutOfMemory;
            };
        },
        .object => |obj_entries| {
            if (attr_type == .TranslatedString or attr_type == .TranslatedFSString) {
                return types.encodeTranslatedString(allocator, obj_entries) catch {
                    return allocator.alloc(u8, 0) catch return LsfError.OutOfMemory;
                };
            }
            return allocator.alloc(u8, 0) catch return LsfError.OutOfMemory;
        },
        .array => |items| {
            return types.encodeVector(allocator, attr_type, items) catch {
                return allocator.alloc(u8, 0) catch return LsfError.OutOfMemory;
            };
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "LSF header parsing rejects non-LSF data" {
    const result = expand(std.testing.allocator, "not an LSF file");
    try std.testing.expectError(LsfError.InvalidMagic, result);
}

test "LSF header parsing rejects unsupported versions" {
    var data: [8]u8 = undefined;
    @memcpy(data[0..4], LSF_MAGIC);
    std.mem.writeInt(u32, data[4..8], 99, .little);

    const result = expand(std.testing.allocator, &data);
    try std.testing.expectError(LsfError.UnsupportedVersion, result);
}

test "LSF attribute type names" {
    try std.testing.expectEqualStrings("int", (types.AttributeType.Int).name());
    try std.testing.expectEqualStrings("float", (types.AttributeType.Float).name());
}
