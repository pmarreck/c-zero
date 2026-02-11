//! C0 FFI Layer - Arena-Based Memory Management
//!
//! Provides a C-compatible API for the C0 binary format.
//! All allocations are made via an arena allocator, allowing
//! C clients to free all memory with a single c0_arena_free() call.

const std = @import("std");
const core = @import("c0_core");
const codec_mod = @import("c0_codec");

// ============================================================================
// Error Codes (must match c0.h)
// ============================================================================

pub const C0Error = enum(c_int) {
    C0_OK = 0,
    C0_ERR_NULL_ARG = 1,
    C0_ERR_OUT_OF_MEMORY = 2,
    C0_ERR_INVALID_TYPE = 3,
    C0_ERR_DECODE_FAILED = 4,
    C0_ERR_INDEX_OUT_OF_BOUNDS = 5,
    C0_ERR_CODEC_FAILED = 6,
    C0_ERR_UNKNOWN_CODEC = 7,
};

// ============================================================================
// Arena
// ============================================================================

/// Opaque arena type for C
pub const C0Arena = opaque {
    fn fromInternal(arena: *ArenaState) *C0Arena {
        return @ptrCast(arena);
    }

    fn toInternal(self: *C0Arena) *ArenaState {
        return @ptrCast(@alignCast(self));
    }
};

/// Internal arena state
const ArenaState = struct {
    arena: std.heap.ArenaAllocator,

    fn allocator(self: *ArenaState) std.mem.Allocator {
        return self.arena.allocator();
    }
};

// ============================================================================
// Value Wrapper
// ============================================================================

/// Value type enum for runtime type checking
const ValueType = enum {
    string,
    array,
    object,
};

/// Mutable value wrapper for FFI
/// Allows building values incrementally from C
pub const C0Value = struct {
    arena: *ArenaState,
    type: ValueType,
    data: union {
        string: []const u8,
        array: std.ArrayListUnmanaged(core.Value),
        object: std.ArrayListUnmanaged(core.Entry),
    },

    fn toCore(self: *const C0Value) core.Value {
        return switch (self.type) {
            .string => core.Value{ .string = self.data.string },
            .array => core.Value{ .array = self.data.array.items },
            .object => core.Value{ .object = self.data.object.items },
        };
    }
};

// ============================================================================
// Arena Lifecycle
// ============================================================================

/// Create a new arena
export fn c0_arena_new() ?*C0Arena {
    const state = std.heap.page_allocator.create(ArenaState) catch return null;
    state.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
    return C0Arena.fromInternal(state);
}

/// Free arena and all allocations
export fn c0_arena_free(arena: ?*C0Arena) void {
    const a = arena orelse return;
    const state = a.toInternal();
    state.arena.deinit();
    std.heap.page_allocator.destroy(state);
}

// ============================================================================
// Value Constructors
// ============================================================================

/// Create a string value
export fn c0_string(arena: ?*C0Arena, data: ?[*]const u8, len: usize) ?*C0Value {
    const a = arena orelse return null;
    const state = a.toInternal();
    const allocator = state.allocator();

    // Handle null data as empty string
    const src = if (data) |d| d[0..len] else "";

    // Copy string data into arena
    const str_copy = allocator.dupe(u8, src) catch return null;

    const val = allocator.create(C0Value) catch return null;
    val.* = .{
        .arena = state,
        .type = .string,
        .data = .{ .string = str_copy },
    };
    return val;
}

/// Create an empty array
export fn c0_array(arena: ?*C0Arena) ?*C0Value {
    const a = arena orelse return null;
    const state = a.toInternal();
    const allocator = state.allocator();

    const val = allocator.create(C0Value) catch return null;
    val.* = .{
        .arena = state,
        .type = .array,
        .data = .{ .array = .{} },
    };
    return val;
}

/// Create an empty object
export fn c0_object(arena: ?*C0Arena) ?*C0Value {
    const a = arena orelse return null;
    const state = a.toInternal();
    const allocator = state.allocator();

    const val = allocator.create(C0Value) catch return null;
    val.* = .{
        .arena = state,
        .type = .object,
        .data = .{ .object = .{} },
    };
    return val;
}

// ============================================================================
// Array Operations
// ============================================================================

/// Push a value onto an array
export fn c0_array_push(arr: ?*C0Value, value: ?*C0Value) C0Error {
    const a = arr orelse return .C0_ERR_NULL_ARG;
    const v = value orelse return .C0_ERR_NULL_ARG;

    if (a.type != .array) return .C0_ERR_INVALID_TYPE;

    const allocator = a.arena.allocator();
    a.data.array.append(allocator, v.toCore()) catch return .C0_ERR_OUT_OF_MEMORY;
    return .C0_OK;
}

/// Get array length
export fn c0_array_len(arr: ?*const C0Value) usize {
    const a = arr orelse return 0;
    if (a.type != .array) return 0;
    return a.data.array.items.len;
}

/// Get array element at index
export fn c0_array_get(arr: ?*const C0Value, index: usize) ?*C0Value {
    const a = arr orelse return null;
    if (a.type != .array) return null;
    if (index >= a.data.array.items.len) return null;

    const allocator = a.arena.allocator();
    const item = a.data.array.items[index];

    // Create a new C0Value wrapper for the item
    const wrapper = allocator.create(C0Value) catch return null;
    wrapper.* = coreToC0Value(a.arena, allocator, item) catch return null;
    return wrapper;
}

// ============================================================================
// Object Operations
// ============================================================================

/// Set a key-value pair on an object
export fn c0_object_set(obj: ?*C0Value, key: ?[*]const u8, key_len: usize, value: ?*C0Value) C0Error {
    const o = obj orelse return .C0_ERR_NULL_ARG;
    const k = key orelse return .C0_ERR_NULL_ARG;
    const v = value orelse return .C0_ERR_NULL_ARG;

    if (o.type != .object) return .C0_ERR_INVALID_TYPE;

    const allocator = o.arena.allocator();

    // Copy key into arena
    const key_copy = allocator.dupe(u8, k[0..key_len]) catch return .C0_ERR_OUT_OF_MEMORY;

    o.data.object.append(allocator, .{
        .key = key_copy,
        .value = v.toCore(),
    }) catch return .C0_ERR_OUT_OF_MEMORY;

    return .C0_OK;
}

/// Get object length (number of key-value pairs)
export fn c0_object_len(obj: ?*const C0Value) usize {
    const o = obj orelse return 0;
    if (o.type != .object) return 0;
    return o.data.object.items.len;
}

/// Get key at index
export fn c0_object_key(obj: ?*const C0Value, index: usize, key_len: ?*usize) ?[*]const u8 {
    const o = obj orelse return null;
    if (o.type != .object) return null;
    if (index >= o.data.object.items.len) return null;

    const entry = o.data.object.items[index];
    if (key_len) |len_ptr| {
        len_ptr.* = entry.key.len;
    }
    return entry.key.ptr;
}

/// Get value at index
export fn c0_object_value(obj: ?*const C0Value, index: usize) ?*C0Value {
    const o = obj orelse return null;
    if (o.type != .object) return null;
    if (index >= o.data.object.items.len) return null;

    const allocator = o.arena.allocator();
    const entry = o.data.object.items[index];

    // Create a new C0Value wrapper for the value
    const wrapper = allocator.create(C0Value) catch return null;
    wrapper.* = coreToC0Value(o.arena, allocator, entry.value) catch return null;
    return wrapper;
}

// ============================================================================
// Value Inspection
// ============================================================================

/// Check if value is a string
export fn c0_is_string(val: ?*const C0Value) c_int {
    const v = val orelse return 0;
    return if (v.type == .string) 1 else 0;
}

/// Check if value is an array
export fn c0_is_array(val: ?*const C0Value) c_int {
    const v = val orelse return 0;
    return if (v.type == .array) 1 else 0;
}

/// Check if value is an object
export fn c0_is_object(val: ?*const C0Value) c_int {
    const v = val orelse return 0;
    return if (v.type == .object) 1 else 0;
}

/// Get string data and length
export fn c0_string_data(val: ?*const C0Value, len: ?*usize) ?[*]const u8 {
    const v = val orelse return null;
    if (v.type != .string) return null;

    if (len) |len_ptr| {
        len_ptr.* = v.data.string.len;
    }
    return v.data.string.ptr;
}

// ============================================================================
// Encode/Decode
// ============================================================================

/// Encode a value to C0 binary format
export fn c0_encode(arena: ?*C0Arena, val: ?*const C0Value, out_len: ?*usize) ?[*]u8 {
    const a = arena orelse return null;
    const v = val orelse return null;

    const state = a.toInternal();
    const allocator = state.allocator();

    const core_val = v.toCore();
    const encoded = core.encode(allocator, core_val) catch return null;

    if (out_len) |len_ptr| {
        len_ptr.* = encoded.len;
    }
    return encoded.ptr;
}

/// Decode C0 binary data to a value
export fn c0_decode(arena: ?*C0Arena, data: ?[*]const u8, len: usize) ?*C0Value {
    const a = arena orelse return null;
    const d = data orelse return null;

    const state = a.toInternal();
    const allocator = state.allocator();

    const decoded = core.decode(allocator, d[0..len]) catch return null;

    const wrapper = allocator.create(C0Value) catch return null;
    wrapper.* = coreToC0Value(state, allocator, decoded) catch return null;
    return wrapper;
}

// ============================================================================
// Codec Operations
// ============================================================================

/// C-compatible codec info struct
pub const C0CodecInfo = extern struct {
    name: [*]const u8,
    name_len: usize,
    description: [*]const u8,
    description_len: usize,
    supports_faithful: c_int,
    supports_editable: c_int,
};

/// Expand: file bytes -> C0 text
/// codec_name: NULL for auto-detect
/// filename: NULL if unknown, used for extension matching
/// faithful: 1=faithful, 0=editable
/// pretty: 1=pretty-print with tabs/newlines, 0=compact
export fn c0_codec_expand(
    arena: ?*C0Arena,
    codec_name: ?[*]const u8,
    codec_name_len: usize,
    filename: ?[*]const u8,
    filename_len: usize,
    data: ?[*]const u8,
    len: usize,
    faithful: c_int,
    pretty: c_int,
    out_len: ?*usize,
) ?[*]u8 {
    const a = arena orelse return null;
    const d = data orelse return null;
    const state = a.toInternal();
    const allocator = state.allocator();
    const registry = codec_mod.builtin_registry;

    // Find codec
    const found_codec = blk: {
        if (codec_name) |cn| {
            break :blk registry.findByName(cn[0..codec_name_len]);
        } else {
            const fname: ?[]const u8 = if (filename) |f| f[0..filename_len] else null;
            break :blk registry.detect(fname, d[0..len]);
        }
    } orelse return null;

    const options = codec_mod.CodecOptions{ .faithful = faithful != 0 };

    // Expand to Value
    const value = found_codec.expand(allocator, d[0..len], options) catch return null;

    // Encode Value to C0 text
    const c0_bytes = core.encodeWithOptions(allocator, value, .{
        .pretty = pretty != 0,
    }) catch return null;

    if (out_len) |lp| {
        lp.* = c0_bytes.len;
    }
    return c0_bytes.ptr;
}

/// Collapse: C0 text -> file bytes
/// codec_name: NULL = infer from C0 "format" field
/// faithful: 1=faithful, 0=editable
export fn c0_codec_collapse(
    arena: ?*C0Arena,
    codec_name: ?[*]const u8,
    codec_name_len: usize,
    c0_data: ?[*]const u8,
    c0_len: usize,
    faithful: c_int,
    out_len: ?*usize,
) ?[*]u8 {
    const a = arena orelse return null;
    const d = c0_data orelse return null;
    const state = a.toInternal();
    const allocator = state.allocator();
    const registry = codec_mod.builtin_registry;

    // Decode C0 text to Value
    const value = core.decode(allocator, d[0..c0_len]) catch return null;

    // Find codec
    const found_codec = blk: {
        if (codec_name) |cn| {
            break :blk registry.findByName(cn[0..codec_name_len]);
        } else {
            // Infer from the "format" field in the decoded value
            break :blk registry.findByFormatField(value);
        }
    } orelse return null;

    const options = codec_mod.CodecOptions{ .faithful = faithful != 0 };

    // Collapse Value to native bytes
    const native_bytes = found_codec.collapse(allocator, value, options) catch return null;

    if (out_len) |lp| {
        lp.* = native_bytes.len;
    }
    return native_bytes.ptr;
}

/// Detect codec from file data and optional filename
/// Returns codec name or NULL if not detected
export fn c0_codec_detect(
    data: ?[*]const u8,
    len: usize,
    filename: ?[*]const u8,
    filename_len: usize,
) ?[*]const u8 {
    const d = data orelse return null;
    const registry = codec_mod.builtin_registry;
    const fname: ?[]const u8 = if (filename) |f| f[0..filename_len] else null;

    const found = registry.detect(fname, d[0..len]) orelse return null;
    return found.info().name.ptr;
}

/// Get number of available codecs
export fn c0_codec_count() usize {
    return codec_mod.builtin_registry.codecs.len;
}

/// Get info for codec at index
export fn c0_codec_info(index: usize) C0CodecInfo {
    const registry = codec_mod.builtin_registry;
    if (index >= registry.codecs.len) {
        return .{
            .name = "",
            .name_len = 0,
            .description = "",
            .description_len = 0,
            .supports_faithful = 0,
            .supports_editable = 0,
        };
    }
    const info = registry.codecs[index].info();
    return .{
        .name = info.name.ptr,
        .name_len = info.name.len,
        .description = info.description.ptr,
        .description_len = info.description.len,
        .supports_faithful = if (info.supports_faithful) 1 else 0,
        .supports_editable = if (info.supports_editable) 1 else 0,
    };
}

/// Convert C0 data to JSON (naive — all strings become JSON strings, no type interpretation).
/// Returns JSON bytes, or NULL on failure.
export fn c0_to_json(
    arena: ?*C0Arena,
    c0_data: ?[*]const u8,
    c0_len: usize,
    out_len: ?*usize,
) ?[*]u8 {
    const a = arena orelse return null;
    const d = c0_data orelse return null;
    const state = a.toInternal();
    const allocator = state.allocator();

    // Decode C0 text to Value
    const value = core.decode(allocator, d[0..c0_len]) catch return null;

    // Convert to JSON
    const json_bytes = core.valueToJson(allocator, value) catch return null;

    if (out_len) |lp| {
        lp.* = json_bytes.len;
    }
    return json_bytes.ptr;
}

/// Query a path in C0 data, returning the result.
/// For strings: returns raw string bytes.
/// For arrays/objects: returns compact C0 text.
/// Returns NULL if the path is invalid or doesn't match.
export fn c0_get(
    arena: ?*C0Arena,
    c0_data: ?[*]const u8,
    c0_len: usize,
    path: ?[*]const u8,
    path_len: usize,
    out_len: ?*usize,
) ?[*]u8 {
    const a = arena orelse return null;
    const d = c0_data orelse return null;
    const p = path orelse return null;
    const state = a.toInternal();
    const allocator = state.allocator();

    // Decode C0 text to Value
    const value = core.decode(allocator, d[0..c0_len]) catch return null;

    // Parse path
    const segments = core.parsePath(allocator, p[0..path_len]) catch return null;

    // Traverse
    const result = core.queryValue(value, segments) orelse return null;

    // Format result
    const output = core.query.formatResult(allocator, result) catch return null;

    if (out_len) |lp| {
        lp.* = output.len;
    }
    return output.ptr;
}

/// Set a value at a path in C0 data, returning new C0 text.
/// path: jq-style path (e.g., ".name", ".users[0].age")
/// new_value_c0: the new value as C0 text (e.g., "hello" for a string, "[a,b]" for an array)
/// Returns new C0 text with the value replaced, or NULL on failure.
export fn c0_set(
    arena: ?*C0Arena,
    c0_data: ?[*]const u8,
    c0_len: usize,
    path_ptr: ?[*]const u8,
    path_len: usize,
    new_value_c0: ?[*]const u8,
    new_value_len: usize,
    pretty: c_int,
    out_len: ?*usize,
) ?[*]u8 {
    const a = arena orelse return null;
    const d = c0_data orelse return null;
    const p = path_ptr orelse return null;
    const nv = new_value_c0 orelse return null;
    const state = a.toInternal();
    const allocator = state.allocator();

    // Decode the root C0 data
    const root = core.decode(allocator, d[0..c0_len]) catch return null;

    // Decode the new value
    const new_val = core.decode(allocator, nv[0..new_value_len]) catch return null;

    // Parse path
    const segments = core.parsePath(allocator, p[0..path_len]) catch return null;

    // Set value
    const updated = core.query.setValue(allocator, root, segments, new_val) catch return null;

    // Re-encode
    const output = core.encodeWithOptions(allocator, updated, .{
        .pretty = pretty != 0,
    }) catch return null;

    if (out_len) |lp| {
        lp.* = output.len;
    }
    return output.ptr;
}

// ============================================================================
// Internal Helpers
// ============================================================================

/// Convert core.Value to C0Value
fn coreToC0Value(arena: *ArenaState, allocator: std.mem.Allocator, val: core.Value) !C0Value {
    return switch (val) {
        .string => |s| C0Value{
            .arena = arena,
            .type = .string,
            .data = .{ .string = s },
        },
        .array => |arr| blk: {
            var list: std.ArrayListUnmanaged(core.Value) = .{};
            try list.appendSlice(allocator, arr);
            break :blk C0Value{
                .arena = arena,
                .type = .array,
                .data = .{ .array = list },
            };
        },
        .object => |obj| blk: {
            var list: std.ArrayListUnmanaged(core.Entry) = .{};
            try list.appendSlice(allocator, obj);
            break :blk C0Value{
                .arena = arena,
                .type = .object,
                .data = .{ .object = list },
            };
        },
    };
}

// ============================================================================
// Tests
// ============================================================================

test "arena lifecycle" {
    const arena = c0_arena_new();
    try std.testing.expect(arena != null);
    c0_arena_free(arena);
}

test "string creation" {
    const arena = c0_arena_new() orelse unreachable;
    defer c0_arena_free(arena);

    const str = c0_string(arena, "hello", 5);
    try std.testing.expect(str != null);
    try std.testing.expect(c0_is_string(str) == 1);

    var len: usize = undefined;
    const data = c0_string_data(str, &len);
    try std.testing.expect(data != null);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualStrings("hello", data.?[0..len]);
}

test "empty string" {
    const arena = c0_arena_new() orelse unreachable;
    defer c0_arena_free(arena);

    const str = c0_string(arena, null, 0);
    try std.testing.expect(str != null);
    try std.testing.expect(c0_is_string(str) == 1);

    var len: usize = undefined;
    _ = c0_string_data(str, &len);
    try std.testing.expectEqual(@as(usize, 0), len);
}

test "array operations" {
    const arena = c0_arena_new() orelse unreachable;
    defer c0_arena_free(arena);

    const arr = c0_array(arena);
    try std.testing.expect(arr != null);
    try std.testing.expect(c0_is_array(arr) == 1);
    try std.testing.expectEqual(@as(usize, 0), c0_array_len(arr));

    const str1 = c0_string(arena, "a", 1);
    const str2 = c0_string(arena, "b", 1);

    try std.testing.expectEqual(C0Error.C0_OK, c0_array_push(arr, str1));
    try std.testing.expectEqual(C0Error.C0_OK, c0_array_push(arr, str2));
    try std.testing.expectEqual(@as(usize, 2), c0_array_len(arr));

    const item0 = c0_array_get(arr, 0);
    try std.testing.expect(item0 != null);
    try std.testing.expect(c0_is_string(item0) == 1);

    const item_oob = c0_array_get(arr, 99);
    try std.testing.expect(item_oob == null);
}

test "object operations" {
    const arena = c0_arena_new() orelse unreachable;
    defer c0_arena_free(arena);

    const obj = c0_object(arena);
    try std.testing.expect(obj != null);
    try std.testing.expect(c0_is_object(obj) == 1);
    try std.testing.expectEqual(@as(usize, 0), c0_object_len(obj));

    const val = c0_string(arena, "world", 5);
    try std.testing.expectEqual(C0Error.C0_OK, c0_object_set(obj, "hello", 5, val));
    try std.testing.expectEqual(@as(usize, 1), c0_object_len(obj));

    var key_len: usize = undefined;
    const key = c0_object_key(obj, 0, &key_len);
    try std.testing.expect(key != null);
    try std.testing.expectEqual(@as(usize, 5), key_len);
    try std.testing.expectEqualStrings("hello", key.?[0..key_len]);

    const val_out = c0_object_value(obj, 0);
    try std.testing.expect(val_out != null);
    try std.testing.expect(c0_is_string(val_out) == 1);
}

test "encode/decode roundtrip" {
    const arena = c0_arena_new() orelse unreachable;
    defer c0_arena_free(arena);

    // Build: ["hello", "world"]
    const arr = c0_array(arena) orelse unreachable;
    _ = c0_array_push(arr, c0_string(arena, "hello", 5));
    _ = c0_array_push(arr, c0_string(arena, "world", 5));

    // Encode
    var enc_len: usize = undefined;
    const encoded = c0_encode(arena, arr, &enc_len);
    try std.testing.expect(encoded != null);
    try std.testing.expect(enc_len > 0);

    // Decode
    const decoded = c0_decode(arena, encoded, enc_len);
    try std.testing.expect(decoded != null);
    try std.testing.expect(c0_is_array(decoded) == 1);
    try std.testing.expectEqual(@as(usize, 2), c0_array_len(decoded));
}

test "nested structure encode/decode" {
    const arena = c0_arena_new() orelse unreachable;
    defer c0_arena_free(arena);

    // Build: {"arr": ["x"]}
    const inner_arr = c0_array(arena) orelse unreachable;
    _ = c0_array_push(inner_arr, c0_string(arena, "x", 1));

    const obj = c0_object(arena) orelse unreachable;
    _ = c0_object_set(obj, "arr", 3, inner_arr);

    // Encode
    var enc_len: usize = undefined;
    const encoded = c0_encode(arena, obj, &enc_len);
    try std.testing.expect(encoded != null);

    // Decode
    const decoded = c0_decode(arena, encoded, enc_len);
    try std.testing.expect(decoded != null);
    try std.testing.expect(c0_is_object(decoded) == 1);
    try std.testing.expectEqual(@as(usize, 1), c0_object_len(decoded));

    const decoded_val = c0_object_value(decoded, 0);
    try std.testing.expect(c0_is_array(decoded_val) == 1);
    try std.testing.expectEqual(@as(usize, 1), c0_array_len(decoded_val));
}

test "null argument handling" {
    try std.testing.expect(c0_arena_new() != null);
    c0_arena_free(null); // Should not crash

    try std.testing.expect(c0_string(null, "test", 4) == null);
    try std.testing.expect(c0_array(null) == null);
    try std.testing.expect(c0_object(null) == null);

    try std.testing.expectEqual(C0Error.C0_ERR_NULL_ARG, c0_array_push(null, null));
    try std.testing.expectEqual(@as(usize, 0), c0_array_len(null));
    try std.testing.expect(c0_array_get(null, 0) == null);

    try std.testing.expectEqual(C0Error.C0_ERR_NULL_ARG, c0_object_set(null, null, 0, null));
    try std.testing.expectEqual(@as(usize, 0), c0_object_len(null));
    try std.testing.expect(c0_object_key(null, 0, null) == null);
    try std.testing.expect(c0_object_value(null, 0) == null);

    try std.testing.expect(c0_is_string(null) == 0);
    try std.testing.expect(c0_is_array(null) == 0);
    try std.testing.expect(c0_is_object(null) == 0);
    try std.testing.expect(c0_string_data(null, null) == null);

    try std.testing.expect(c0_encode(null, null, null) == null);
    try std.testing.expect(c0_decode(null, null, 0) == null);
}

test "type checking" {
    const arena = c0_arena_new() orelse unreachable;
    defer c0_arena_free(arena);

    const str = c0_string(arena, "test", 4) orelse unreachable;
    const arr = c0_array(arena) orelse unreachable;
    const obj = c0_object(arena) orelse unreachable;

    // Push to non-array should fail
    try std.testing.expectEqual(C0Error.C0_ERR_INVALID_TYPE, c0_array_push(str, str));
    try std.testing.expectEqual(C0Error.C0_ERR_INVALID_TYPE, c0_array_push(obj, str));

    // Set on non-object should fail
    try std.testing.expectEqual(C0Error.C0_ERR_INVALID_TYPE, c0_object_set(str, "k", 1, str));
    try std.testing.expectEqual(C0Error.C0_ERR_INVALID_TYPE, c0_object_set(arr, "k", 1, str));

    // String data on non-string should fail
    try std.testing.expect(c0_string_data(arr, null) == null);
    try std.testing.expect(c0_string_data(obj, null) == null);
}
