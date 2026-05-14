//! BG3 LSPK Package Parser/Writer
//!
//! LSPK is the outer container format for BG3 save files (.lsv, .pak).
//! All versions: Magic "LSPK" at offset 0, header immediately after.
//!
//! Only V18 (BG3 Full Release) is fully supported.
//! V15/V16 (Early Access) are detected and rejected with a clear error.
//!
//! V18 Structure:
//!   [LSPK magic 4B][LSPKHeader16 36B][file data...][compressed file list]
//!   Header: version, file_list_offset, file_list_size, flags, priority, MD5, num_parts
//!   File list: [numFiles u32][LZ4 chunked compressed FileEntry18 data]
//!   FileEntry18: 272 bytes (256B name + 4B offset_lo + 2B offset_hi + 1B archive_part
//!                + 1B flags + 4B size_on_disk + 4B uncompressed_size)

const std = @import("std");
const core = @import("c0_core");
const lz4 = @import("lz4.zig");
const zstd = @import("zstd.zig");
const lsf = @import("lsf.zig");

const Value = core.Value;
const Entry = core.Entry;

pub const LspkError = error{
    InvalidMagic,
    UnsupportedVersion,
    TruncatedInput,
    DecompressionFailed,
    InvalidFileList,
    InvalidFileData,
    InvalidFormat,
    OutOfMemory,
};

const LSPK_MAGIC = "LSPK";
const MAGIC_SIZE: usize = 4;
const HEADER_SIZE: usize = 36; // LSPKHeader16: version(4) + offset(8) + size(4) + flags(1) + priority(1) + md5(16) + numparts(2)
const TOTAL_HEADER: usize = MAGIC_SIZE + HEADER_SIZE; // 40 bytes
const FILE_ENTRY_SIZE: usize = 272;
const FILE_NAME_SIZE: usize = 256;

/// Compression methods per file (lower 4 bits of Flags byte)
const CompressionMethod = enum(u4) {
    none = 0,
    zlib = 1,
    lz4 = 2,
    zstd = 3,
    _,
};

/// Parsed LSPK header
const LspkHeader = struct {
    version: u32,
    file_list_offset: u64,
    file_list_size: u32,
    flags: u8,
    priority: u8,
    md5: [16]u8,
    num_parts: u16,
};

/// A parsed file entry from the LSPK file list (V18 FileEntry18 layout)
const FileEntry = struct {
    name: []const u8, // slice into decompressed file list data
    offset: u64, // OffsetInFile1 | (OffsetInFile2 << 32)
    archive_part: u8,
    compression: CompressionMethod,
    size_on_disk: u32,
    uncompressed_size: u32,
};

/// Parse an LSPK package and return a C0 Value
pub fn expand(allocator: std.mem.Allocator, data: []const u8) LspkError!Value {
    if (data.len < TOTAL_HEADER) return LspkError.TruncatedInput;

    // Magic "LSPK" at offset 0
    if (!std.mem.eql(u8, data[0..4], LSPK_MAGIC)) {
        return LspkError.InvalidMagic;
    }

    const header = parseHeader(data) catch return LspkError.TruncatedInput;

    // Only V18 is fully supported
    if (header.version != 18) return LspkError.UnsupportedVersion;

    // Read and decompress file list
    if (header.file_list_offset + header.file_list_size > data.len)
        return LspkError.TruncatedInput;

    const file_list_raw = data[@intCast(header.file_list_offset)..][0..header.file_list_size];
    if (file_list_raw.len < 4) return LspkError.InvalidFileList;

    // First 4 bytes = number of files
    const num_files = std.mem.readInt(u32, file_list_raw[0..4], .little);
    const expected_decompressed = @as(usize, num_files) * FILE_ENTRY_SIZE;

    // Remaining bytes = LZ4 chunked compressed file entry data
    const compressed_entries = file_list_raw[4..];
    const file_list_data = lz4.decompressChunked(
        allocator,
        compressed_entries,
        expected_decompressed,
        64 * 1024, // 64KB chunks
    ) catch return LspkError.DecompressionFailed;
    defer allocator.free(file_list_data);

    // Parse file entries
    var files: std.ArrayListUnmanaged(Value) = .empty;
    defer files.deinit(allocator);

    for (0..num_files) |i| {
        const entry_base = i * FILE_ENTRY_SIZE;
        if (entry_base + FILE_ENTRY_SIZE > file_list_data.len) break;
        const entry_data = file_list_data[entry_base..][0..FILE_ENTRY_SIZE];

        const file_entry = parseFileEntry(entry_data);

        // Extract and optionally decompress file data
        const file_content = try extractFileContent(allocator, data, file_entry);
        defer allocator.free(file_content);

        // If it's an LSF file, recursively expand it
        const content_value = blk: {
            if (std.mem.endsWith(u8, file_entry.name, ".lsf")) {
                break :blk lsf.expand(allocator, file_content) catch {
                    // LSF parse failed — fall back to raw bytes
                    break :blk Value{ .string = allocator.dupe(u8, file_content) catch return LspkError.OutOfMemory };
                };
            }
            // Non-LSF files: include as raw bytes (will be pb-encoded by C0)
            break :blk Value{ .string = allocator.dupe(u8, file_content) catch return LspkError.OutOfMemory };
        };

        // Build file entry object: {name: "filename", content: ...}
        const file_entries = allocator.alloc(Entry, 2) catch return LspkError.OutOfMemory;
        file_entries[0] = .{
            .key = "name",
            .value = .{ .string = allocator.dupe(u8, file_entry.name) catch return LspkError.OutOfMemory },
        };
        file_entries[1] = .{ .key = "content", .value = content_value };
        files.append(allocator, Value{ .object = file_entries }) catch return LspkError.OutOfMemory;
    }

    // Build top-level: {format:bg3-lspk, version:18, files:[...]}
    const ver_str = std.fmt.allocPrint(allocator, "{d}", .{header.version}) catch return LspkError.OutOfMemory;
    const files_arr = files.toOwnedSlice(allocator) catch return LspkError.OutOfMemory;

    const top_entries = allocator.alloc(Entry, 3) catch return LspkError.OutOfMemory;
    top_entries[0] = .{ .key = "format", .value = .{ .string = "bg3-lspk" } };
    top_entries[1] = .{ .key = "version", .value = .{ .string = ver_str } };
    top_entries[2] = .{ .key = "files", .value = .{ .array = files_arr } };

    return Value{ .object = top_entries };
}

/// Collapse a C0 Value back to LSPK V18 binary
pub fn collapse(allocator: std.mem.Allocator, value: Value) LspkError![]u8 {
    // Expect {format:bg3-lspk, version:18, files:[...]}
    const entries = switch (value) {
        .object => |e| e,
        else => return LspkError.InvalidFormat,
    };

    // Extract files array
    var files_val: ?Value = null;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, "files")) {
            files_val = entry.value;
        }
    }
    const files = switch (files_val orelse return LspkError.InvalidFormat) {
        .array => |a| a,
        else => return LspkError.InvalidFormat,
    };

    // Phase 1: Collapse each file's content to binary
    var file_datas: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (file_datas.items) |fd| allocator.free(fd);
        file_datas.deinit(allocator);
    }
    var file_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer file_names.deinit(allocator);

    for (files) |file_val| {
        const file_entries = switch (file_val) {
            .object => |e| e,
            else => return LspkError.InvalidFormat,
        };

        var name: ?[]const u8 = null;
        var content: ?Value = null;
        for (file_entries) |fe| {
            if (std.mem.eql(u8, fe.key, "name")) {
                name = switch (fe.value) {
                    .string => |s| s,
                    else => null,
                };
            } else if (std.mem.eql(u8, fe.key, "content")) {
                content = fe.value;
            }
        }

        const file_name = name orelse return LspkError.InvalidFormat;
        const file_content = content orelse return LspkError.InvalidFormat;

        // If content is an LSF object, collapse it
        const file_bytes = blk: {
            if (isLsfValue(file_content)) {
                break :blk lsf.collapse(allocator, file_content) catch return LspkError.InvalidFormat;
            }
            // Raw bytes content
            break :blk switch (file_content) {
                .string => |s| allocator.dupe(u8, s) catch return LspkError.OutOfMemory,
                else => return LspkError.InvalidFormat,
            };
        };

        file_datas.append(allocator, file_bytes) catch return LspkError.OutOfMemory;
        file_names.append(allocator, file_name) catch return LspkError.OutOfMemory;
    }

    // Phase 2: Zstd compress each file and track offsets
    const num_files = file_datas.items.len;
    var compressed_datas: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (compressed_datas.items) |cd| allocator.free(cd);
        compressed_datas.deinit(allocator);
    }

    for (file_datas.items) |fd| {
        const compressed = zstd.compress(allocator, fd, 1) catch return LspkError.OutOfMemory;
        compressed_datas.append(allocator, compressed) catch return LspkError.OutOfMemory;
    }

    // Phase 3: Build the package
    // Layout: [header 40B][compressed file data...][compressed file list]
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);

    // Reserve header space (will fill in later)
    result.appendNTimes(allocator, 0, TOTAL_HEADER) catch return LspkError.OutOfMemory;

    // Write compressed file data and record offsets
    var file_offsets: std.ArrayListUnmanaged(u64) = .empty;
    defer file_offsets.deinit(allocator);

    for (compressed_datas.items) |cd| {
        file_offsets.append(allocator, @intCast(result.items.len)) catch return LspkError.OutOfMemory;
        result.appendSlice(allocator, cd) catch return LspkError.OutOfMemory;
    }

    // Phase 4: Build FileEntry18 list
    var entry_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer entry_buf.deinit(allocator);

    for (0..num_files) |i| {
        // Name: 256 bytes, null-padded
        var name_bytes: [FILE_NAME_SIZE]u8 = .{0} ** FILE_NAME_SIZE;
        const name = file_names.items[i];
        const copy_len = @min(name.len, FILE_NAME_SIZE);
        @memcpy(name_bytes[0..copy_len], name[0..copy_len]);
        entry_buf.appendSlice(allocator, &name_bytes) catch return LspkError.OutOfMemory;

        // OffsetInFile1 (u32 LE) - lower 32 bits
        var tmp4: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp4, @intCast(file_offsets.items[i] & 0xFFFFFFFF), .little);
        entry_buf.appendSlice(allocator, &tmp4) catch return LspkError.OutOfMemory;

        // OffsetInFile2 (u16 LE) - upper 16 bits
        var tmp2: [2]u8 = undefined;
        std.mem.writeInt(u16, &tmp2, @intCast((file_offsets.items[i] >> 32) & 0xFFFF), .little);
        entry_buf.appendSlice(allocator, &tmp2) catch return LspkError.OutOfMemory;

        // ArchivePart (u8)
        entry_buf.append(allocator, 0) catch return LspkError.OutOfMemory;

        // Flags (u8) - zstd compression = 3
        entry_buf.append(allocator, @intFromEnum(CompressionMethod.zstd)) catch return LspkError.OutOfMemory;

        // SizeOnDisk (u32 LE)
        std.mem.writeInt(u32, &tmp4, @intCast(compressed_datas.items[i].len), .little);
        entry_buf.appendSlice(allocator, &tmp4) catch return LspkError.OutOfMemory;

        // UncompressedSize (u32 LE)
        std.mem.writeInt(u32, &tmp4, @intCast(file_datas.items[i].len), .little);
        entry_buf.appendSlice(allocator, &tmp4) catch return LspkError.OutOfMemory;
    }

    // Phase 5: Compress file list with LZ4 chunked
    const entry_data = entry_buf.items;
    const compressed_entries = lz4.compressChunked(allocator, entry_data, 64 * 1024) catch return LspkError.OutOfMemory;
    defer allocator.free(compressed_entries);

    // Record file list position
    const file_list_offset: u64 = @intCast(result.items.len);

    // Write: numFiles (u32) + compressed entry data
    var num_files_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &num_files_buf, @intCast(num_files), .little);
    result.appendSlice(allocator, &num_files_buf) catch return LspkError.OutOfMemory;
    result.appendSlice(allocator, compressed_entries) catch return LspkError.OutOfMemory;

    const file_list_size: u32 = @intCast(4 + compressed_entries.len);

    // Phase 6: Write header
    // Magic
    @memcpy(result.items[0..4], LSPK_MAGIC);

    // Version
    std.mem.writeInt(u32, result.items[4..8], 18, .little);

    // FileListOffset (u64 LE)
    std.mem.writeInt(u64, result.items[8..16], file_list_offset, .little);

    // FileListSize (u32 LE)
    std.mem.writeInt(u32, result.items[16..20], file_list_size, .little);

    // Flags, Priority
    result.items[20] = 0;
    result.items[21] = 0;

    // MD5 (16 bytes) - compute over all file data
    var md5_hash: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(result.items[TOTAL_HEADER..@intCast(file_list_offset)], &md5_hash, .{});
    @memcpy(result.items[22..38], &md5_hash);

    // NumParts (u16 LE)
    std.mem.writeInt(u16, result.items[38..40], 1, .little);

    return result.toOwnedSlice(allocator) catch return LspkError.OutOfMemory;
}

fn isLsfValue(value: Value) bool {
    switch (value) {
        .object => |entries| {
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, "format")) {
                    switch (entry.value) {
                        .string => |s| return std.mem.eql(u8, s, "bg3-lsf"),
                        else => return false,
                    }
                }
            }
        },
        else => {},
    }
    return false;
}

fn parseHeader(data: []const u8) LspkError!LspkHeader {
    if (data.len < TOTAL_HEADER) return LspkError.TruncatedInput;

    var header: LspkHeader = undefined;
    header.version = std.mem.readInt(u32, data[4..8], .little);
    header.file_list_offset = std.mem.readInt(u64, data[8..16], .little);
    header.file_list_size = std.mem.readInt(u32, data[16..20], .little);
    header.flags = data[20];
    header.priority = data[21];
    @memcpy(&header.md5, data[22..38]);
    header.num_parts = std.mem.readInt(u16, data[38..40], .little);

    return header;
}

/// Parse a V18 FileEntry18 from 272 bytes
fn parseFileEntry(data: []const u8) FileEntry {
    // Name: 256 bytes, null-terminated
    const name_bytes = data[0..FILE_NAME_SIZE];
    const name_len = std.mem.indexOfScalar(u8, name_bytes, 0) orelse FILE_NAME_SIZE;
    const name = name_bytes[0..name_len];

    // OffsetInFile1 (u32) | (OffsetInFile2 (u16) << 32)
    const offset_lo = std.mem.readInt(u32, data[FILE_NAME_SIZE..][0..4], .little);
    const offset_hi = std.mem.readInt(u16, data[FILE_NAME_SIZE + 4 ..][0..2], .little);
    const offset = @as(u64, offset_lo) | (@as(u64, offset_hi) << 32);

    const archive_part = data[FILE_NAME_SIZE + 6];
    const flags = data[FILE_NAME_SIZE + 7];
    const compression: CompressionMethod = @enumFromInt(@as(u4, @intCast(flags & 0x0F)));

    const size_on_disk = std.mem.readInt(u32, data[FILE_NAME_SIZE + 8 ..][0..4], .little);
    const uncompressed_size = std.mem.readInt(u32, data[FILE_NAME_SIZE + 12 ..][0..4], .little);

    return .{
        .name = name,
        .offset = offset,
        .archive_part = archive_part,
        .compression = compression,
        .size_on_disk = size_on_disk,
        .uncompressed_size = uncompressed_size,
    };
}

fn extractFileContent(allocator: std.mem.Allocator, package_data: []const u8, entry: FileEntry) LspkError![]u8 {
    if (entry.offset + entry.size_on_disk > package_data.len) return LspkError.InvalidFileData;
    const raw = package_data[@intCast(entry.offset)..][0..entry.size_on_disk];

    return switch (entry.compression) {
        .none => allocator.dupe(u8, raw) catch return LspkError.OutOfMemory,
        .lz4 => lz4.decompressBlock(allocator, raw, entry.uncompressed_size) catch return LspkError.DecompressionFailed,
        .zstd => zstd.decompress(allocator, raw, entry.uncompressed_size) catch return LspkError.DecompressionFailed,
        else => allocator.dupe(u8, raw) catch return LspkError.OutOfMemory,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "LSPK rejects non-LSPK data" {
    const bad_data = "This is not an LSPK file and is long enough to pass size check!!";
    const result = expand(std.testing.allocator, bad_data);
    try std.testing.expectError(LspkError.InvalidMagic, result);
}

test "LSPK rejects truncated input" {
    const result = expand(std.testing.allocator, "short");
    try std.testing.expectError(LspkError.TruncatedInput, result);
}

test "LSPK rejects old versions" {
    // Build a minimal header with V16
    var data: [40]u8 = .{0} ** 40;
    @memcpy(data[0..4], LSPK_MAGIC);
    std.mem.writeInt(u32, data[4..8], 16, .little);
    const result = expand(std.testing.allocator, &data);
    try std.testing.expectError(LspkError.UnsupportedVersion, result);
}
