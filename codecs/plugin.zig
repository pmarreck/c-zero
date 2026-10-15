//! Codec plugin adapter: turns any codec type into the c0_plugin.h C ABI that
//! codecs/plugin_main.c drives (protocol c0-codec/1, docs/plan_context/codec_plugins.md).
//!
//! A codec type provides getInfo, expandImpl and collapseImpl. Plugin(T) wraps them in
//! length-delimited C functions; exportPlugin(T) exports those under the c0_plugin_* names
//! for the single codec linked into one plugin executable. All codec work happens in an
//! arena; results are copied into std.heap.c_allocator memory owned by the caller until
//! c0_plugin_free.

const std = @import("std");
const core = @import("c0_core");
const codec = @import("c0_codec");

const Value = core.Value;
const Entry = core.Entry;

pub const protocol = "c0-codec/1";

/// Mirrors C0PluginArg in c0_plugin.h.
pub const Arg = extern struct {
    key: ?[*]const u8,
    key_len: usize,
    value: ?[*]const u8,
    value_len: usize,
};

/// Mirrors C0PluginBuffer in c0_plugin.h.
pub const Buffer = extern struct {
    data: [*]u8,
    len: usize,
};

pub const Status = enum(c_int) { ok = 0, codec_error = 1, out_of_memory = 2, invalid_argument = 3 };

const empty_buffer = Buffer{ .data = @constCast(@as([*]const u8, "")), .len = 0 };

fn boolText(b: bool) []const u8 {
    return if (b) "true" else "false";
}

fn strings(a: std.mem.Allocator, items: []const []const u8) ![]Value {
    const out = try a.alloc(Value, items.len);
    for (items, out) |s, *v| v.* = .{ .string = s };
    return out;
}

/// Serializes codec metadata as the compact C0 object returned by `info`. Magic bytes are hex
/// so their meaning never depends on payload encoding. Caller owns the result (allocated in `a`).
pub fn infoToC0(a: std.mem.Allocator, info: codec.CodecInfo) ![]u8 {
    const magic = try a.alloc(Value, info.magic.len);
    for (info.magic, magic) |m, *v| {
        const fields = try a.alloc(Entry, 2);
        fields[0] = .{ .key = "offset", .value = .{ .string = try std.fmt.allocPrint(a, "{d}", .{m.offset}) } };
        fields[1] = .{ .key = "hex", .value = .{ .string = try std.fmt.allocPrint(a, "{x}", .{m.bytes}) } };
        v.* = .{ .object = fields };
    }
    const args = try a.alloc(Value, info.custom_args.len);
    for (info.custom_args, args) |arg, *v| {
        const fields = try a.alloc(Entry, 3);
        fields[0] = .{ .key = "name", .value = .{ .string = arg.name } };
        fields[1] = .{ .key = "value_name", .value = .{ .string = arg.value_name } };
        fields[2] = .{ .key = "description", .value = .{ .string = arg.description } };
        v.* = .{ .object = fields };
    }
    const entries = [_]Entry{
        .{ .key = "protocol", .value = .{ .string = protocol } },
        .{ .key = "name", .value = .{ .string = info.name } },
        .{ .key = "description", .value = .{ .string = info.description } },
        .{ .key = "extensions", .value = .{ .array = try strings(a, info.extensions) } },
        .{ .key = "magic", .value = .{ .array = magic } },
        .{ .key = "format_names", .value = .{ .array = try strings(a, info.format_names) } },
        .{ .key = "faithful", .value = .{ .string = boolText(info.supports_faithful) } },
        .{ .key = "editable", .value = .{ .string = boolText(info.supports_editable) } },
        .{ .key = "help", .value = .{ .string = info.help } },
        .{ .key = "args", .value = .{ .array = args } },
    };
    return core.encode(a, .{ .object = &entries });
}

/// Copies `bytes` into caller-owned c_allocator memory; on allocation failure the buffer is
/// empty and the status reports out of memory.
fn deliver(out: *Buffer, status: Status, bytes: []const u8) c_int {
    const copy = std.heap.c_allocator.dupe(u8, bytes) catch {
        out.* = empty_buffer;
        return @intFromEnum(Status.out_of_memory);
    };
    out.* = .{ .data = copy.ptr, .len = copy.len };
    return @intFromEnum(status);
}

fn deliverError(out: *Buffer, status: Status, comptime fmt: []const u8, args: anytype) c_int {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    return deliver(out, status, msg);
}

fn slice(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return "";
    return (ptr orelse return null)[0..len];
}

/// Converts the C argument array to CodecArgValue slices, or null when any pointer is invalid.
fn convertArgs(a: std.mem.Allocator, args: ?[*]const Arg, args_len: usize) !?[]codec.CodecArgValue {
    if (args_len == 0) return &.{};
    const list = args orelse return null;
    const out = try a.alloc(codec.CodecArgValue, args_len);
    for (list[0..args_len], out) |arg, *o| {
        o.* = .{
            .key = slice(arg.key, arg.key_len) orelse return null,
            .value = slice(arg.value, arg.value_len) orelse return null,
        };
    }
    return out;
}

/// C ABI wrapper for one codec type; see c0_plugin.h for the contract.
pub fn Plugin(comptime CodecT: type) type {
    return struct {
        var instance: CodecT = .{};

        fn name() []const u8 {
            return instance.getInfo().name;
        }

        pub fn info(out: *Buffer) callconv(.c) c_int {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            const text = infoToC0(arena.allocator(), instance.getInfo()) catch
                return deliverError(out, .out_of_memory, "{s}: info failed: OutOfMemory", .{name()});
            return deliver(out, .ok, text);
        }

        pub fn expand(in: ?[*]const u8, in_len: usize, editable: c_int, pretty: c_int, args: ?[*]const Arg, args_len: usize, out: *Buffer) callconv(.c) c_int {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const input = slice(in, in_len) orelse return deliverError(out, .invalid_argument, "{s}: expand: null input with nonzero length", .{name()});
            const codec_args = (convertArgs(a, args, args_len) catch return deliverError(out, .out_of_memory, "{s}: expand failed: OutOfMemory", .{name()})) orelse
                return deliverError(out, .invalid_argument, "{s}: expand: invalid argument array", .{name()});
            const value = instance.expandImpl(a, input, .{ .faithful = editable == 0, .codec_args = codec_args }) catch |e|
                return deliverError(out, if (e == error.OutOfMemory) .out_of_memory else .codec_error, "{s}: expand failed: {s}", .{ name(), @errorName(e) });
            const text = core.encodeWithOptions(a, value, .{ .pretty = pretty != 0 }) catch |e|
                return deliverError(out, .codec_error, "{s}: expand failed: C0 encode error: {s}", .{ name(), @errorName(e) });
            return deliver(out, .ok, text);
        }

        pub fn collapse(in: ?[*]const u8, in_len: usize, editable: c_int, args: ?[*]const Arg, args_len: usize, out: *Buffer) callconv(.c) c_int {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const input = slice(in, in_len) orelse return deliverError(out, .invalid_argument, "{s}: collapse: null input with nonzero length", .{name()});
            const codec_args = (convertArgs(a, args, args_len) catch return deliverError(out, .out_of_memory, "{s}: collapse failed: OutOfMemory", .{name()})) orelse
                return deliverError(out, .invalid_argument, "{s}: collapse: invalid argument array", .{name()});
            const value = core.decode(a, input) catch |e|
                return deliverError(out, .codec_error, "{s}: collapse failed: C0 decode error: {s}", .{ name(), @errorName(e) });
            const bytes = instance.collapseImpl(a, value, .{ .faithful = editable == 0, .codec_args = codec_args }) catch |e|
                return deliverError(out, if (e == error.OutOfMemory) .out_of_memory else .codec_error, "{s}: collapse failed: {s}", .{ name(), @errorName(e) });
            return deliver(out, .ok, bytes);
        }

        pub fn free(buffer: Buffer) callconv(.c) void {
            if (buffer.len > 0) std.heap.c_allocator.free(buffer.data[0..buffer.len]);
        }
    };
}

/// Exports Plugin(CodecT) under the c0_plugin_* symbol names; call once, in a plugin's root file.
pub fn exportPlugin(comptime CodecT: type) void {
    const P = Plugin(CodecT);
    @export(&P.info, .{ .name = "c0_plugin_info" });
    @export(&P.expand, .{ .name = "c0_plugin_expand" });
    @export(&P.collapse, .{ .name = "c0_plugin_collapse" });
    @export(&P.free, .{ .name = "c0_plugin_free" });
}

// ============================================================================
// Tests
// ============================================================================

/// Minimal codec for adapter tests: wraps input bytes as {format:fake,data:...} and echoes the
/// `tag` argument and the mode so tests can see what reached the codec.
const FakeCodec = struct {
    pub fn getInfo(_: *FakeCodec) codec.CodecInfo {
        return .{
            .name = "fake",
            .description = "Test codec",
            .extensions = &.{ ".fk", ".fake" },
            .magic = &.{.{ .offset = 2, .bytes = "\x89F\x00" }},
            .format_names = &.{ "fake", "fake-v0" },
            .supports_faithful = true,
            .supports_editable = false,
            .help = "Help text",
            .custom_args = &.{.{ .name = "tag", .description = "Echoed tag", .value_name = "TEXT" }},
        };
    }

    pub fn expandImpl(_: *FakeCodec, allocator: std.mem.Allocator, data: []const u8, options: codec.CodecOptions) codec.CodecError!Value {
        if (std.mem.eql(u8, data, "fail")) return codec.CodecError.InvalidFormat;
        const entries = try allocator.alloc(Entry, 4);
        entries[0] = .{ .key = "format", .value = .{ .string = "fake" } };
        entries[1] = .{ .key = "data", .value = .{ .string = try allocator.dupe(u8, data) } };
        entries[2] = .{ .key = "tag", .value = .{ .string = options.getArg("tag") orelse "" } };
        entries[3] = .{ .key = "mode", .value = .{ .string = if (options.faithful) "faithful" else "editable" } };
        return .{ .object = entries };
    }

    pub fn collapseImpl(_: *FakeCodec, allocator: std.mem.Allocator, value: Value, _: codec.CodecOptions) codec.CodecError![]u8 {
        if (value != .object or value.object.len < 2) return codec.CodecError.InvalidFormat;
        return allocator.dupe(u8, value.object[1].value.string);
    }
};

const TestPlugin = Plugin(FakeCodec);

fn field(v: Value, key: []const u8) ?Value {
    for (v.object) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
    return null;
}

test "info serializes every CodecInfo field as protocol c0-codec/1" {
    var buf: Buffer = undefined;
    try std.testing.expectEqual(@as(c_int, 0), TestPlugin.info(&buf));
    defer TestPlugin.free(buf);
    const v = try core.decode(std.testing.allocator, buf.data[0..buf.len]);
    defer core.deinit(std.testing.allocator, v);
    try std.testing.expectEqualStrings("c0-codec/1", field(v, "protocol").?.string);
    try std.testing.expectEqualStrings("fake", field(v, "name").?.string);
    try std.testing.expectEqualStrings("Test codec", field(v, "description").?.string);
    try std.testing.expectEqualStrings(".fake", field(v, "extensions").?.array[1].string);
    const magic = field(v, "magic").?.array[0];
    try std.testing.expectEqualStrings("2", field(magic, "offset").?.string);
    try std.testing.expectEqualStrings("894600", field(magic, "hex").?.string);
    try std.testing.expectEqualStrings("fake-v0", field(v, "format_names").?.array[1].string);
    try std.testing.expectEqualStrings("true", field(v, "faithful").?.string);
    try std.testing.expectEqualStrings("false", field(v, "editable").?.string);
    try std.testing.expectEqualStrings("Help text", field(v, "help").?.string);
    const arg = field(v, "args").?.array[0];
    try std.testing.expectEqualStrings("tag", field(arg, "name").?.string);
    try std.testing.expectEqualStrings("TEXT", field(arg, "value_name").?.string);
    try std.testing.expectEqualStrings("Echoed tag", field(arg, "description").?.string);
}

test "info output is compact (single line)" {
    var buf: Buffer = undefined;
    try std.testing.expectEqual(@as(c_int, 0), TestPlugin.info(&buf));
    defer TestPlugin.free(buf);
    try std.testing.expect(std.mem.indexOfScalar(u8, buf.data[0..buf.len], '\n') == null);
}

test "expand then collapse round-trips bytes with embedded NUL through the ABI" {
    const input = "\x00ab\x00\xff\x00";
    const tag = Arg{ .key = "tag", .key_len = 3, .value = "t1", .value_len = 2 };
    var expanded: Buffer = undefined;
    try std.testing.expectEqual(@as(c_int, 0), TestPlugin.expand(input, input.len, 0, 0, @ptrCast(&tag), 1, &expanded));
    defer TestPlugin.free(expanded);
    const v = try core.decode(std.testing.allocator, expanded.data[0..expanded.len]);
    defer core.deinit(std.testing.allocator, v);
    try std.testing.expectEqualStrings("t1", field(v, "tag").?.string);
    try std.testing.expectEqualStrings("faithful", field(v, "mode").?.string);

    var collapsed: Buffer = undefined;
    try std.testing.expectEqual(@as(c_int, 0), TestPlugin.collapse(expanded.data, expanded.len, 0, null, 0, &collapsed));
    defer TestPlugin.free(collapsed);
    try std.testing.expectEqualSlices(u8, input, collapsed.data[0..collapsed.len]);
}

test "expand honors editable and pretty flags" {
    var compact: Buffer = undefined;
    try std.testing.expectEqual(@as(c_int, 0), TestPlugin.expand("x", 1, 1, 0, null, 0, &compact));
    defer TestPlugin.free(compact);
    var pretty: Buffer = undefined;
    try std.testing.expectEqual(@as(c_int, 0), TestPlugin.expand("x", 1, 1, 1, null, 0, &pretty));
    defer TestPlugin.free(pretty);
    try std.testing.expect(std.mem.indexOfScalar(u8, compact.data[0..compact.len], '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, pretty.data[0..pretty.len], '\n') != null);
    const v = try core.decode(std.testing.allocator, compact.data[0..compact.len]);
    defer core.deinit(std.testing.allocator, v);
    try std.testing.expectEqualStrings("editable", field(v, "mode").?.string);
}

test "codec failure returns CODEC_ERROR with a message naming codec and error" {
    var out: Buffer = undefined;
    try std.testing.expectEqual(@as(c_int, 1), TestPlugin.expand("fail", 4, 0, 1, null, 0, &out));
    defer TestPlugin.free(out);
    try std.testing.expectEqualStrings("fake: expand failed: InvalidFormat", out.data[0..out.len]);
}

test "collapse of malformed C0 reports a decode error" {
    var out: Buffer = undefined;
    try std.testing.expectEqual(@as(c_int, 1), TestPlugin.collapse("{unterminated", 13, 0, null, 0, &out));
    defer TestPlugin.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out.data[0..out.len], "fake: collapse failed: C0 decode error: "));
}

test "null input with nonzero length is rejected as an invalid argument" {
    var null_input: Buffer = undefined;
    try std.testing.expectEqual(@as(c_int, 3), TestPlugin.expand(null, 5, 0, 0, null, 0, &null_input));
    defer TestPlugin.free(null_input);
    var null_args: Buffer = undefined;
    try std.testing.expectEqual(@as(c_int, 3), TestPlugin.collapse("x", 1, 0, null, 2, &null_args));
    defer TestPlugin.free(null_args);
}

test "empty input is accepted with a null pointer" {
    var out: Buffer = undefined;
    try std.testing.expectEqual(@as(c_int, 0), TestPlugin.expand(null, 0, 0, 0, null, 0, &out));
    defer TestPlugin.free(out);
}
