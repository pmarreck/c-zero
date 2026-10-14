//! Benchmark adapter for the performance-profile engine (performance-measurement/v1 JSON on
//! stdout). Each sample round-trips a seeded, generated object tree through the C0 core: encode
//! to bytes, decode back, then compare the decoded tree with the generated source. The source tree
//! comes from the seeded generator, not from the codec, so wrong or skipped work cannot verify.
//! Payloads are uniformly random bytes, which puts every structural delimiter, whitespace byte,
//! control code and non-ASCII byte through printable_binary escaping. The domain excludes raw
//! strings that smart encoding corrupts (see isEncodedLookalike); those are a known defect pinned
//! by the ledger in src/core/roundtrip_test.zig, so a passing measurement is no general round-trip
//! correctness claim.
//!
//! Usage: c0-bench CASE SIZES SEED
//!   CASE    case name (recorded only; every case runs the same work)
//!   SIZES   comma-separated top-level entry counts, e.g. 2048,4096,8192
//!   SEED    seed text (performance-profile passes 128-bit hex), hashed to the generator's u64 seed
const std = @import("std");
const builtin = @import("builtin");
const core = @import("c0_core");

const posix = std.posix;
const Value = core.Value;
const Entry = core.Entry;

/// Native code with no JIT: one untimed round trip per size settles caches and the allocator.
const warmup_runs = 1;
const samples_per_size = 5;
const max_string_len = 32;
const max_element_len = 16;
const max_key_suffix_len = 8;
const array_len = 3;
const nested_entries = 2;

/// Wraps an allocator and records live, peak and total requested bytes and the allocation count:
/// the heap the encoder and decoder ask for (the generated source tree is not counted).
const CountingAllocator = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,
    total: usize = 0,
    count: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn grew(self: *CountingAllocator, old: usize, new: usize) void {
        self.live = self.live - old + new;
        if (new > old) self.total += new - old;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ret) orelse return null;
        self.count += 1;
        self.grew(0, len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret)) return false;
        self.grew(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ret) orelse return null;
        self.grew(memory.len, new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret);
        self.grew(memory.len, 0);
    }
};

/// True when `s` is raw text that smart encoding (SPECIFICATION.md §13) passes through as if it
/// were already printable-binary encoded, so decoding returns different bytes. Owner decision
/// c0-smart-encoding-roundtrip is pending on whether the format should stay lossy for these; until
/// it is answered the fixture leaves them out. Allocation failure counts as a lookalike.
pub fn isEncodedLookalike(allocator: std.mem.Allocator, s: []const u8) bool {
    if (core.encoding.needsEncoding(s, .{})) return false;
    if (!core.encoding.isAlreadyEncoded(s)) return false;
    const decoded = core.decodePayload(allocator, s) catch return true;
    defer allocator.free(decoded);
    return !std.mem.eql(u8, decoded, s);
}

/// Appends 0xFF (invalid UTF-8, so the payload must be encoded) to a lookalike string.
fn avoidLookalike(allocator: std.mem.Allocator, s: []u8) ![]u8 {
    if (!isEncodedLookalike(allocator, s)) return s;
    const forced = try allocator.realloc(s, s.len + 1);
    forced[s.len] = 0xff;
    return forced;
}

fn randomBytes(allocator: std.mem.Allocator, rand: std.Random, max_len: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, rand.uintAtMost(usize, max_len));
    rand.bytes(bytes);
    return avoidLookalike(allocator, bytes);
}

/// Seeded fixture generator: an object of `entries` entries whose values rotate through a random
/// byte string, a three-element array of random strings and a two-entry nested object. Arrays
/// never hold exactly one empty string, the format's one documented ambiguity (SPECIFICATION.md §8),
/// and no string is an encoded lookalike (see isEncodedLookalike).
pub fn generate(allocator: std.mem.Allocator, entries: usize, seed: u64) !Value {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    const top = try allocator.alloc(Entry, entries);
    for (top, 0..) |*e, i| {
        const suffix = try randomBytes(allocator, rand, max_key_suffix_len);
        e.key = try avoidLookalike(allocator, try std.fmt.allocPrint(allocator, "k{d}{s}", .{ i, suffix }));
        e.value = switch (i % 3) {
            0 => .{ .string = try randomBytes(allocator, rand, max_string_len) },
            1 => blk: {
                const items = try allocator.alloc(Value, array_len);
                for (items) |*item| item.* = .{ .string = try randomBytes(allocator, rand, max_element_len) };
                break :blk .{ .array = items };
            },
            else => blk: {
                const inner = try allocator.alloc(Entry, nested_entries);
                for (inner) |*n| n.* = .{
                    .key = try randomBytes(allocator, rand, max_key_suffix_len),
                    .value = .{ .string = try randomBytes(allocator, rand, max_element_len) },
                };
                break :blk .{ .object = inner };
            },
        };
    }
    return .{ .object = top };
}

/// Maps seed text to the generator's 64-bit seed with Wyhash, so the engine's 128-bit hex seeds
/// (or any other token) select a deterministic fixture. Null for empty text or bytes outside
/// [0-9A-Za-z_-], which keeps the seed safe to echo into the JSON output unescaped.
pub fn seedFromText(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    for (text) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return null;
    return std.hash.Wyhash.hash(0, text);
}

/// The decoded tree must equal the generated source exactly.
pub fn workVerified(source: Value, decoded: Value) bool {
    return source.eql(decoded);
}

/// A clock reading in nanoseconds. Errors propagate: a failed clock is never read as zero.
fn clockNs(id: posix.clockid_t) error{ClockFailed}!u64 {
    var ts: posix.timespec = undefined;
    if (posix.errno(posix.system.clock_gettime(id, &ts)) != .SUCCESS) return error.ClockFailed;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Sample = struct {
    cpu_ns: u64,
    wall_ns: u64,
    peak_bytes: usize,
    total_bytes: usize,
    allocation_count: usize,
    residual_bytes: usize,
    encoded_bytes: usize,
    verified: bool,
};

/// One timed encode-decode round trip of `source` with its heap use; verification and cleanup
/// happen inside the timed interval because a real round trip pays for both.
pub fn roundtripOnce(child: std.mem.Allocator, source: Value) !Sample {
    var counting = CountingAllocator{ .child = child };
    const a = counting.allocator();
    const cpu0 = try clockNs(.PROCESS_CPUTIME_ID);
    const wall0 = try clockNs(.MONOTONIC);
    const encoded = try core.encode(a, source);
    const decoded = core.decode(a, encoded) catch |e| {
        a.free(encoded);
        return e;
    };
    const verified = workVerified(source, decoded);
    const encoded_bytes = encoded.len;
    core.deinit(a, decoded);
    a.free(encoded);
    const wall1 = try clockNs(.MONOTONIC);
    const cpu1 = try clockNs(.PROCESS_CPUTIME_ID);
    return .{
        .cpu_ns = cpu1 - cpu0,
        .wall_ns = wall1 - wall0,
        .peak_bytes = counting.peak,
        .total_bytes = counting.total,
        .allocation_count = counting.count,
        .residual_bytes = counting.live,
        .encoded_bytes = encoded_bytes,
        .verified = verified,
    };
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("c0-bench: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    if (builtin.mode != .ReleaseFast) fail("built {s}; benchmarks need ReleaseFast (zig build bench -Doptimize=ReleaseFast)", .{@tagName(builtin.mode)});
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) fail("usage: c0-bench CASE SIZES SEED", .{});
    const case = args[1];
    const seed_text = args[3];
    const seed = seedFromText(seed_text) orelse fail("bad seed [{s}]: need non-empty [0-9A-Za-z_-]", .{seed_text});
    var sizes: std.ArrayListUnmanaged(usize) = .empty;
    var it = std.mem.tokenizeScalar(u8, args[2], ',');
    while (it.next()) |t| {
        const n = std.fmt.parseInt(usize, t, 10) catch fail("bad size {s}", .{t});
        if (n == 0) fail("bad size {s}", .{t});
        try sizes.append(arena, n);
    }
    if (sizes.items.len == 0) fail("no sizes", .{});

    const child = std.heap.c_allocator;
    var out_buf: [1 << 16]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &out_buf);
    const out = &w.interface;
    try out.print("{{\"schema\":\"performance-measurement/v1\",\"correct\":true,\"build_mode\":\"{s}\",", .{@tagName(builtin.mode)});
    try out.writeAll("\"allocator_coverage\":\"every allocation of core.encode and core.decode, including the encoded buffer and decoded tree (std.heap.c_allocator through a counting wrapper); the generated source tree is excluded\",");
    try out.writeAll("\"domain\":\"seeded random-byte payloads excluding raw strings that smart encoding passes through and decodes differently (known defect, owner decision c0-smart-encoding-roundtrip pending); measures this subset only and makes no general round-trip correctness claim\",");
    try out.print("\"case\":\"{s}\",\"seed\":\"{s}\",\"seed_u64\":{d},", .{ case, seed_text, seed });
    try out.print("\"clocks\":\"cpu_ns: CLOCK_PROCESS_CPUTIME_ID; wall_ns: CLOCK_MONOTONIC; one encode+decode+verify+free round trip per sample, after {d} untimed warmup runs per size\",\"rows\":[", .{warmup_runs});
    for (sizes.items, 0..) |n, row| {
        var fixture = std.heap.ArenaAllocator.init(child);
        defer fixture.deinit();
        const source = try generate(fixture.allocator(), n, seed);
        for (0..warmup_runs) |_| _ = try roundtripOnce(child, source);
        var samples: [samples_per_size]Sample = undefined;
        for (&samples) |*smp| {
            smp.* = try roundtripOnce(child, source);
            if (!smp.verified) fail("size {d}: decoded tree differs from the generated source", .{n});
        }
        if (row > 0) try out.writeAll(",");
        try out.print("{{\"size\":{d},\"encoded_bytes\":{d},\"samples\":{{", .{ n, samples[0].encoded_bytes });
        inline for (.{ "cpu_ns", "wall_ns", "peak_bytes", "total_bytes", "allocation_count" }, 0..) |field, f| {
            if (f > 0) try out.writeAll(",");
            try out.print("\"{s}\":[", .{field});
            for (samples, 0..) |smp, k| try out.print("{s}{d}", .{ if (k > 0) "," else "", @field(smp, field) });
            try out.writeAll("]");
        }
        try out.writeAll("},\"residual_bytes\":[");
        for (samples, 0..) |smp, k| try out.print("{s}{d}", .{ if (k > 0) "," else "", smp.residual_bytes });
        try out.writeAll("]}");
    }
    try out.writeAll("]}\n");
    try out.flush();
}


test "the fixture is deterministic for a seed and differs across seeds" {
    var arena_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_a.deinit();
    var arena_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_b.deinit();
    const a = try generate(arena_a.allocator(), 64, 7);
    const b = try generate(arena_b.allocator(), 64, 7);
    const c = try generate(arena_b.allocator(), 64, 8);
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expectEqual(@as(usize, 64), a.object.len);
}

test "the fixture exercises every structural delimiter and non-ASCII byte in payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try generate(arena.allocator(), 256, 1);
    var seen = [_]bool{false} ** 256;
    markBytes(v, &seen);
    for ("{}[],: \t\n\x00\x1c\xff") |byte| try std.testing.expect(seen[byte]);
}

fn markBytes(v: Value, seen: *[256]bool) void {
    switch (v) {
        .string => |s| for (s) |byte| {
            seen[byte] = true;
        },
        .array => |items| for (items) |item| markBytes(item, seen),
        .object => |entries| for (entries) |e| {
            for (e.key) |byte| seen[byte] = true;
            markBytes(e.value, seen);
        },
    }
}

test "a round trip of the fixture verifies and leaves no residual heap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try generate(arena.allocator(), 512, 3);
    const s = try roundtripOnce(std.testing.allocator, v);
    try std.testing.expect(s.verified);
    try std.testing.expectEqual(@as(usize, 0), s.residual_bytes);
    try std.testing.expect(s.encoded_bytes > 0);
    try std.testing.expect(s.peak_bytes > 0);
}

test "the work check rejects a decoded tree that differs from the source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try generate(arena.allocator(), 32, 5);
    try std.testing.expect(workVerified(v, v));
    const entries = try arena.allocator().dupe(core.Entry, v.object);
    const wrong_value: Value = .{ .object = entries[0 .. entries.len - 1] };
    try std.testing.expect(!workVerified(v, wrong_value));
    entries[0].value = .{ .string = "tampered" };
    try std.testing.expect(!workVerified(v, .{ .object = entries }));
}

fn expectNoLookalikes(v: Value) !void {
    switch (v) {
        .string => |s| try std.testing.expect(!isEncodedLookalike(std.testing.allocator, s)),
        .array => |items| for (items) |item| try expectNoLookalikes(item),
        .object => |entries| for (entries) |e| {
            try std.testing.expect(!isEncodedLookalike(std.testing.allocator, e.key));
            try expectNoLookalikes(e.value);
        },
    }
}

test "the fixture avoids raw strings that smart encoding would corrupt (decision c0-smart-encoding-roundtrip)" {
    try std.testing.expect(isEncodedLookalike(std.testing.allocator, "\xc2\xa7"));
    try std.testing.expect(!isEncodedLookalike(std.testing.allocator, "plain ascii"));
    try std.testing.expect(!isEncodedLookalike(std.testing.allocator, "\x00\xc2\xa7"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectNoLookalikes(try generate(arena.allocator(), 4096, 3));
}

test "seed text maps deterministically and rejects empty or unsafe text" {
    const a = seedFromText("780c6954f07ad243ede1e7d63b406489").?;
    try std.testing.expectEqual(a, seedFromText("780c6954f07ad243ede1e7d63b406489").?);
    try std.testing.expect(a != seedFromText("a3d4de67ddb6ca23ca7b4e788b7f0377").?);
    try std.testing.expectEqual(@as(?u64, null), seedFromText(""));
    try std.testing.expectEqual(@as(?u64, null), seedFromText("bad\"seed"));
    try std.testing.expectEqual(@as(?u64, null), seedFromText("a b"));
}
