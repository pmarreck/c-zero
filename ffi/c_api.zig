//! C0 FFI Layer - Arena-Based Memory Management
//!
//! Provides a C-compatible API for the C0 binary format.
//! All allocations are made via an arena allocator, allowing
//! C clients to free all memory with a single c0_arena_free() call.

const std = @import("std");
const core = @import("c0_core");

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
