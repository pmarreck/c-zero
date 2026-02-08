//! Content-Aware JSON <-> C0 Demo
//!
//! Demonstrates C0 used not as a naive JSON encoder, but with an application-specific
//! content layer that decides how to represent certain fields more efficiently in binary.
//! This shows that C0 is format-agnostic - users design their own semantics on top.
//!
//! Content encoding scheme (standard JSON layer):
//!   strings: pb-encoded content (type inferred on decode by exclusion)
//!   numbers: bare decimal/scientific notation
//!   true/false/null: literal keywords
//!   empty string: empty payload
//!
//! Content-aware transforms (application layer - NOT in core):
//!   timestamps ("when", "time"): ISO 8601 string -> 8-byte nanosecond epoch (pb-encoded)
//!   cert fingerprints ("cert_fingerprint"): hex string -> raw bytes (pb-encoded)
//!   everything else: standard JSON content encoding
//!
//! Also demonstrates:
//!   - Printable-binary encoded binary data (showcasing the pb encoding)
//!   - Embedded JSON in string values (delimiters get escaped, remains readable)
//!
//! Run with: zig build run-json-demo

const std = @import("std");
const core = @import("c0_core");
const json = core.json_content;

const JsonValue = json.JsonValue;
const JsonEntry = json.JsonEntry;
const Value = core.Value;
const Entry = core.Entry;
const epoch = std.time.epoch;

// ============================================================================
// Content-Aware Helpers (application-layer semantics, NOT in core)
// ============================================================================

/// Parse "YYYY-MM-DDTHH:MM:SSZ" -> nanoseconds since Unix epoch (u64).
/// Only handles UTC ('Z' suffix). Returns null if format doesn't match.
fn parseIso8601ToNanos(iso: []const u8) ?u64 {
    // Must be exactly "YYYY-MM-DDTHH:MM:SSZ" = 20 chars
    if (iso.len != 20) return null;
    if (iso[4] != '-' or iso[7] != '-' or iso[10] != 'T') return null;
    if (iso[13] != ':' or iso[16] != ':' or iso[19] != 'Z') return null;

    const year = std.fmt.parseUnsigned(u16, iso[0..4], 10) catch return null;
    const month_num = std.fmt.parseUnsigned(u4, iso[5..7], 10) catch return null;
    const day = std.fmt.parseUnsigned(u5, iso[8..10], 10) catch return null;
    const hour = std.fmt.parseUnsigned(u5, iso[11..13], 10) catch return null;
    const minute = std.fmt.parseUnsigned(u6, iso[14..16], 10) catch return null;
    const second = std.fmt.parseUnsigned(u6, iso[17..19], 10) catch return null;

    if (month_num < 1 or month_num > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    // Compute days from epoch (1970-01-01) to target date
    var total_days: u64 = 0;
    // Add days for complete years
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        total_days += epoch.getDaysInYear(y);
    }
    // Add days for complete months in target year
    const month: epoch.Month = @enumFromInt(month_num);
    var m_num: u4 = 1;
    while (m_num < month_num) : (m_num += 1) {
        const m: epoch.Month = @enumFromInt(m_num);
        total_days += epoch.getDaysInMonth(year, m);
    }
    _ = month;
    // Add days within month (day is 1-based)
    total_days += day - 1;

    const total_secs: u64 = total_days * 86400 + @as(u64, hour) * 3600 + @as(u64, minute) * 60 + @as(u64, second);
    return total_secs * 1_000_000_000;
}

/// Nanoseconds since Unix epoch -> "YYYY-MM-DDTHH:MM:SSZ" (second resolution).
/// Writes into the provided 20-byte buffer and returns the slice.
fn nanosToIso8601(buf: *[20]u8, nanos: u64) []const u8 {
    const secs = nanos / 1_000_000_000;
    const es = epoch.EpochSeconds{ .secs = secs };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();

    const year = year_day.year;
    const month_num = month_day.month.numeric();
    const day_num: u8 = month_day.day_index + 1; // 0-indexed -> 1-indexed
    const hour = day_secs.getHoursIntoDay();
    const minute = day_secs.getMinutesIntoHour();
    const second = day_secs.getSecondsIntoMinute();

    // Format: YYYY-MM-DDTHH:MM:SSZ
    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year, month_num, day_num, hour, minute, second,
    }) catch unreachable;

    return buf[0..20];
}

/// Returns true if the key indicates a timestamp field that should get binary encoding.
fn isTimestampKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "when") or std.mem.eql(u8, key, "time");
}

/// Returns true if the key indicates a hex fingerprint field.
fn isFingerprintKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "cert_fingerprint");
}

/// Returns true if a string looks like ISO 8601 UTC: "YYYY-MM-DDTHH:MM:SSZ"
fn looksLikeIso8601(s: []const u8) bool {
    return parseIso8601ToNanos(s) != null;
}

/// Returns true if a string looks like a hex-encoded fingerprint (even length, all hex chars).
fn looksLikeHex(s: []const u8) bool {
    if (s.len == 0 or s.len % 2 != 0) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

// ============================================================================
// Content-Aware Encode: JSON -> C0 with field-specific transforms
// ============================================================================

/// Convert a JsonValue to a C0 Value, applying content-aware transforms based on key context.
/// - Timestamps (key "when"/"time" + ISO 8601 string) -> 8-byte nanos binary (pb-encoded)
/// - Cert fingerprints (key "cert_fingerprint" + hex string) -> raw bytes (pb-encoded)
/// - Everything else -> standard JSON content encoding via json.toC0Value()
fn contentAwareJsonToC0(allocator: std.mem.Allocator, jval: JsonValue, key_context: ?[]const u8) !Value {
    // Check for field-specific transforms on string values
    if (key_context) |key| {
        if (jval == .string) {
            const s = jval.string;

            // Timestamp transform: ISO 8601 -> 8-byte nanos binary
            if (isTimestampKey(key) and looksLikeIso8601(s)) {
                const nanos = parseIso8601ToNanos(s).?;
                var nanos_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &nanos_bytes, nanos, .big);
                // pb-encode the 8 raw bytes, store directly as C0 string (no " prefix)
                const pb_encoded = try core.encodePayload(allocator, &nanos_bytes);
                return Value{ .string = pb_encoded };
            }

            // Fingerprint transform: hex string -> raw bytes binary
            if (isFingerprintKey(key) and looksLikeHex(s)) {
                var raw_buf: [256]u8 = undefined;
                const raw = std.fmt.hexToBytes(&raw_buf, s) catch
                    return json.toC0Value(allocator, jval);
                const pb_encoded = try core.encodePayload(allocator, raw);
                return Value{ .string = pb_encoded };
            }
        }
    }

    // For objects and arrays, recurse with key context
    switch (jval) {
        .object => |obj| {
            const entries = try allocator.alloc(Entry, obj.len);
            errdefer allocator.free(entries);
            for (obj, 0..) |entry, i| {
                const key_enc = try core.encodePayload(allocator, entry.key);
                entries[i] = .{
                    .key = key_enc,
                    .value = try contentAwareJsonToC0(allocator, entry.value, entry.key),
                };
            }
            return Value{ .object = entries };
        },
        .array => |arr| {
            const items = try allocator.alloc(Value, arr.len);
            errdefer allocator.free(items);
            for (arr, 0..) |item, i| {
                items[i] = try contentAwareJsonToC0(allocator, item, key_context);
            }
            return Value{ .array = items };
        },
        // Scalars without special key context: delegate to standard encoding
        else => return json.toC0Value(allocator, jval),
    }
}

// ============================================================================
// Content-Aware Decode: C0 -> JSON with field-specific transforms
// ============================================================================

/// Convert a C0 Value back to JsonValue, applying content-aware reverse transforms.
/// - Timestamps (key "when"/"time") -> pb-decode -> 8 bytes -> nanos -> ISO 8601
/// - Cert fingerprints (key "cert_fingerprint") -> pb-decode -> raw bytes -> hex string
/// - Everything else -> standard JSON content decoding via json.fromC0Value()
fn contentAwareC0ToJson(allocator: std.mem.Allocator, c0val: Value, key_context: ?[]const u8) !JsonValue {
    // Check for field-specific reverse transforms on string values
    if (key_context) |key| {
        if (c0val == .string) {
            const payload = c0val.string;

            // Timestamp reverse: pb-decode -> 8 bytes -> nanos -> ISO 8601
            if (isTimestampKey(key)) {
                // No " prefix - this is raw pb-encoded binary
                const raw = try core.decodePayload(allocator, payload);
                defer allocator.free(raw);
                if (raw.len == 8) {
                    const nanos = std.mem.readInt(u64, raw[0..8], .big);
                    var iso_buf: [20]u8 = undefined;
                    const iso_str = nanosToIso8601(&iso_buf, nanos);
                    return JsonValue{ .string = try allocator.dupe(u8, iso_str) };
                }
                // Fallback if not 8 bytes: standard decode
                return json.fromC0Value(allocator, c0val);
            }

            // Fingerprint reverse: pb-decode -> raw bytes -> hex string
            if (isFingerprintKey(key)) {
                const raw = try core.decodePayload(allocator, payload);
                defer allocator.free(raw);
                // Convert raw bytes to lowercase hex string
                const hex_len = raw.len * 2;
                const hex_str = try allocator.alloc(u8, hex_len);
                for (raw, 0..) |byte, i| {
                    const hex_chars = "0123456789abcdef";
                    hex_str[i * 2] = hex_chars[byte >> 4];
                    hex_str[i * 2 + 1] = hex_chars[byte & 0x0f];
                }
                return JsonValue{ .string = hex_str };
            }
        }
    }

    // For objects and arrays, recurse with key context
    switch (c0val) {
        .object => |obj| {
            const entries = try allocator.alloc(JsonEntry, obj.len);
            errdefer allocator.free(entries);
            for (obj, 0..) |entry, i| {
                // Decode key (may be pb-encoded)
                const decoded_key = try core.decodePayload(allocator, entry.key);
                entries[i] = .{
                    .key = decoded_key,
                    .value = try contentAwareC0ToJson(allocator, entry.value, decoded_key),
                };
            }
            return JsonValue{ .object = entries };
        },
        .array => |arr| {
            const items = try allocator.alloc(JsonValue, arr.len);
            errdefer allocator.free(items);
            for (arr, 0..) |item, i| {
                items[i] = try contentAwareC0ToJson(allocator, item, key_context);
            }
            return JsonValue{ .array = items };
        },
        // Scalars without special key context: standard decode
        else => return json.fromC0Value(allocator, c0val),
    }
}

/// Free a C0 Value tree (all allocations).
fn freeContentAwareC0Value(allocator: std.mem.Allocator, val: Value) void {
    switch (val) {
        .string => |s| allocator.free(s),
        .array => |arr| {
            for (arr) |item| freeContentAwareC0Value(allocator, item);
            allocator.free(arr);
        },
        .object => |obj| {
            for (obj) |entry| {
                allocator.free(entry.key);
                freeContentAwareC0Value(allocator, entry.value);
            }
            allocator.free(obj);
        },
    }
}

// ============================================================================
// Demo
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Set up stdout writer (Zig 0.15 API)
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    // C2PA manifest JSON - based on Cloudflare's blog post about content credentials
    // https://blog.cloudflare.com/preserve-content-credentials-with-cloudflare-images/
    const json_input =
        \\{"jumbf": {"c2pa.manifest.nikon": {"status": "preserved-from-camera"}, "c2pa.manifest.cloudflare": {"claim_generator": "Cloudflare Images", "assertions": [{"label": "c2pa.actions", "data": {"actions": [{"action": "c2pa.resized", "when": "2025-01-10T12:05:00Z", "softwareAgent": "Cloudflare Images", "parameters": {"originalDimensions": {"width": 8256, "height": 5504}, "newDimensions": {"width": 800, "height": 533}}}]}}], "signature_info": {"issuer": "Cloudflare, Inc", "time": "2025-01-10T12:05:00Z", "cert_fingerprint": "fedcba9876543210"}, "claim_metadata": {"claim_id": "cf_resize_123", "parent_claim_id": "nikon_z9_123"}}}}
    ;

    try stdout.print("=== C0 Content-Aware JSON Demo ===\n\n", .{});

    try stdout.print("NOTE: C0 doesn't prescribe content semantics - this demo shows what\n", .{});
    try stdout.print("an application-specific encoder might look like.\n\n", .{});

    // Step 1: Show input JSON
    try stdout.print("1. Input JSON - C2PA manifest ({d} bytes):\n", .{json_input.len});
    // Pretty-print the JSON for display
    const parsed = json.parseJson(allocator, json_input) catch |err| {
        try stdout.print("JSON parse error: {any}\n", .{err});
        return;
    };
    defer json.freeJsonValue(allocator, parsed);

    const pretty_json = try json.stringify(allocator, parsed);
    defer allocator.free(pretty_json);
    try stdout.print("{s}\n\n", .{pretty_json});

    // Step 2: Content-aware encode to C0
    const c0_value = try contentAwareJsonToC0(allocator, parsed, null);
    defer freeContentAwareC0Value(allocator, c0_value);

    const c0_encoded = try core.encodeRaw(allocator, c0_value);
    defer allocator.free(c0_encoded);

    try stdout.print("2. Content-aware C0 encoded ({d} bytes):\n", .{c0_encoded.len});
    try stdout.print("{s}\n\n", .{c0_encoded});

    try stdout.print("   Transformations applied:\n", .{});
    try stdout.print("   - Timestamps -> 8-byte nanosecond-epoch binary (pb-encoded)\n", .{});
    try stdout.print("   - Cert fingerprint -> raw binary (pb-encoded)\n", .{});
    try stdout.print("   - Dimensions -> kept as readable numbers\n\n", .{});

    // Step 3: Decode back to JSON
    const decoded_c0 = try core.decode(allocator, c0_encoded);
    defer core.deinit(allocator, decoded_c0);

    const decoded_json = try contentAwareC0ToJson(allocator, decoded_c0, null);
    defer json.freeJsonValue(allocator, decoded_json);

    const json_output = try json.stringify(allocator, decoded_json);
    defer allocator.free(json_output);

    try stdout.print("3. Decoded back to JSON ({d} bytes):\n", .{json_output.len});
    try stdout.print("{s}\n\n", .{json_output});

    try stdout.print("   Note: Timestamps decoded with second resolution (nanosecond precision stored)\n\n", .{});

    // Show compression ratio
    const ratio = @as(f64, @floatFromInt(c0_encoded.len)) / @as(f64, @floatFromInt(json_input.len)) * 100.0;
    try stdout.print("=== Size: JSON {d} bytes -> C0 {d} bytes ({d:.1}%) ===\n\n", .{
        json_input.len,
        c0_encoded.len,
        ratio,
    });

    // =========================================================================
    // Bonus: Demonstrate printable-binary encoding directly
    // =========================================================================
    try stdout.print("=== Bonus: Printable-Binary Encoding Demo ===\n\n", .{});

    // Show how binary data looks when encoded with printable-binary
    const binary_data = "\x89PNG\r\n\x1a\n\x00\x01\x02\x03Hello\x00World";
    const pb_encoded = try core.encodePayload(allocator, binary_data);
    defer allocator.free(pb_encoded);

    try stdout.print("5. Raw binary ({d} bytes):\n", .{binary_data.len});
    try stdout.print("   ", .{});
    for (binary_data) |b| {
        if (b >= 0x20 and b < 0x7f) {
            try stdout.print("{c}", .{b});
        } else {
            try stdout.print("\\x{x:0>2}", .{b});
        }
    }
    try stdout.print("\n\n", .{});

    try stdout.print("6. Printable-binary encoded ({d} bytes):\n", .{pb_encoded.len});
    try stdout.print("   {s}\n\n", .{pb_encoded});

    // Show this binary data embedded in a JSON string via C0
    try stdout.print("7. Embedding binary in JSON via C0:\n", .{});
    // We'll show what the C0 output looks like with actual binary in the string
    var binary_entries = [_]core.Entry{
        .{ .key = "png_header", .value = .{ .string = pb_encoded } },
        .{ .key = "description", .value = .{ .string = "PNG file with null bytes embedded!" } },
    };
    const binary_obj = Value{ .object = &binary_entries };
    const binary_c0 = try core.encode(allocator, binary_obj);
    defer allocator.free(binary_c0);

    try stdout.print("   C0 output ({d} bytes):\n   {s}\n\n", .{ binary_c0.len, binary_c0 });
    try stdout.print("   Note: The binary data remains readable as printable-binary glyphs!\n", .{});
    try stdout.print("   'PNG' is visible, control bytes become distinct Unicode characters.\n\n", .{});

    // Show embedded JSON - the ANTIDOTE to escaping hell!
    try stdout.print("8. Embedded JSON - The Antidote to Escaping Hell:\n\n", .{});

    const inner_json = "{\"inner\": [1, 2, 3], \"nested\": true}";
    const pb_json = try core.encodePayload(allocator, inner_json);
    defer allocator.free(pb_json);

    try stdout.print("   TRADITIONAL JSON (escaping hell):\n", .{});
    try stdout.print("   {{\"data\": \"{{\\\"inner\\\": [1, 2, 3], \\\"nested\\\": true}}\"}}\n\n", .{});

    try stdout.print("   WITH PRINTABLE-BINARY (no escaping needed!):\n", .{});
    try stdout.print("   {{\"data\": \"{s}\"}}\n\n", .{pb_json});

    try stdout.print("   The pb-encoded JSON uses different Unicode delimiters:\n", .{});
    try stdout.print("     {{ -> ❴    [ -> ⟦    , -> ٫    : -> ꞉    \" -> ˵\n", .{});
    try stdout.print("   So you can embed it directly in a JSON string without backslash escaping!\n\n", .{});

    try stdout.print("   Round-trip proof - decode the pb-encoded JSON:\n", .{});
    const decoded_inner = try core.decodePayload(allocator, pb_json);
    defer allocator.free(decoded_inner);
    try stdout.print("   Decoded: {s}\n\n", .{decoded_inner});

    // =========================================================================
    // Demo 9: Binary-in-JSON via C0 - Inspectable Data on the Wire
    // =========================================================================
    try stdout.print("9. Binary-in-JSON: Inspectable Data Pipeline\n\n", .{});
    try stdout.print("   C0 lets you embed binary in structured data that remains human-readable.\n", .{});
    try stdout.print("   Add compression (gzip/zstd) for wire efficiency - decompress to inspect!\n\n", .{});

    // Simulate a PNG-like payload with metadata
    const png_signature = "\x89PNG\r\n\x1a\n";
    const ihdr_chunk = "\x00\x00\x00\x0dIHDR\x00\x00\x00\x80\x00\x00\x00\x60\x08\x06\x00\x00\x00";
    const fake_image_data = "IDAT" ++ ("\x00" ** 50) ++ "compressed pixel data here" ++ ("\xFF" ** 30);
    const png_data = png_signature ++ ihdr_chunk ++ fake_image_data;

    // Create a JSON structure with binary + metadata
    const metadata_json =
        \\{"filename": "avatar.png", "width": 128, "height": 96, "format": "RGBA"}
    ;

    // Parse and convert metadata to C0
    const meta_parsed = json.parseJson(allocator, metadata_json) catch |err| {
        try stdout.print("JSON parse error: {any}\n", .{err});
        return;
    };
    defer json.freeJsonValue(allocator, meta_parsed);

    // Encode PNG data with printable-binary
    const pb_png = try core.encodePayload(allocator, png_data);
    defer allocator.free(pb_png);

    // Build C0 structure: {metadata:{...}, image_data: <pb-encoded PNG>}
    const meta_c0 = try json.toC0Value(allocator, meta_parsed);
    defer json.freeC0Value(allocator, meta_c0);

    var image_msg_entries = [_]core.Entry{
        .{ .key = "metadata", .value = meta_c0 },
        .{ .key = "image_data", .value = .{ .string = pb_png } },
    };
    const image_msg = core.Value{ .object = &image_msg_entries };
    const c0_image = try core.encode(allocator, image_msg);
    defer allocator.free(c0_image);

    try stdout.print("   a) Raw PNG binary: {d} bytes\n", .{png_data.len});
    try stdout.print("   b) C0 with metadata: {d} bytes\n", .{c0_image.len});
    try stdout.print("      Overhead: {d} bytes for structure + readability\n\n", .{c0_image.len - png_data.len});

    // Show the full C0 output - it's inspectable!
    try stdout.print("   C0 output (human-readable!):\n   {s}\n\n", .{c0_image});

    try stdout.print("   Notice: 'PNG', 'IHDR', 'IDAT' markers visible! Metadata is structured!\n\n", .{});

    // Decode it back to prove round-trip
    const decoded_image = try core.decode(allocator, c0_image);
    defer core.deinit(allocator, decoded_image);

    try stdout.print("   Round-trip verification:\n", .{});
    if (decoded_image == .object) {
        for (decoded_image.object) |entry| {
            if (std.mem.eql(u8, entry.key, "metadata")) {
                try stdout.print("   - metadata: (structured object with filename, dimensions)\n", .{});
            }
            if (std.mem.eql(u8, entry.key, "image_data")) {
                if (entry.value == .string) {
                    const recovered_png = try core.decodePayload(allocator, entry.value.string);
                    defer allocator.free(recovered_png);
                    try stdout.print("   - image_data decoded: {} ({d} bytes)\n", .{
                        std.mem.eql(u8, recovered_png, png_data),
                        recovered_png.len,
                    });
                }
            }
        }
    }

    try stdout.print("\n   Recommended pipeline for production:\n", .{});
    try stdout.print("   1. Build structured message with C0 (inspectable at rest)\n", .{});
    try stdout.print("   2. Compress with gzip/zstd before sending (efficient on wire)\n", .{});
    try stdout.print("   3. Decompress on receive -> instantly readable for debugging!\n", .{});
}

// ============================================================================
// Tests
// ============================================================================

test "JSON parse and stringify string" {
    const allocator = std.testing.allocator;
    const result = try json.parseJson(allocator, "\"hello\"");
    defer json.freeJsonValue(allocator, result);

    try std.testing.expect(result == .string);
    try std.testing.expectEqualStrings("hello", result.string);
}

test "JSON parse and stringify number" {
    const allocator = std.testing.allocator;
    const result = try json.parseJson(allocator, "42.5");
    defer json.freeJsonValue(allocator, result);

    try std.testing.expect(result == .number);
    try std.testing.expectEqualStrings("42.5", result.number);
}

test "JSON parse and stringify boolean" {
    const allocator = std.testing.allocator;

    const t = try json.parseJson(allocator, "true");
    defer json.freeJsonValue(allocator, t);
    try std.testing.expect(t == .boolean);
    try std.testing.expect(t.boolean == true);

    const f = try json.parseJson(allocator, "false");
    defer json.freeJsonValue(allocator, f);
    try std.testing.expect(f == .boolean);
    try std.testing.expect(f.boolean == false);
}

test "JSON parse and stringify null" {
    const allocator = std.testing.allocator;
    const result = try json.parseJson(allocator, "null");
    defer json.freeJsonValue(allocator, result);

    try std.testing.expect(result == .null);
}

test "JSON parse array with mixed types" {
    const allocator = std.testing.allocator;
    const result = try json.parseJson(allocator, "[1, \"two\", true, null]");
    defer json.freeJsonValue(allocator, result);

    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 4), result.array.len);
    try std.testing.expect(result.array[0] == .number);
    try std.testing.expect(result.array[1] == .string);
    try std.testing.expect(result.array[2] == .boolean);
    try std.testing.expect(result.array[3] == .null);
}

test "JSON parse object" {
    const allocator = std.testing.allocator;
    const result = try json.parseJson(allocator, "{\"key\": \"value\", \"num\": 42}");
    defer json.freeJsonValue(allocator, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 2), result.object.len);
}

test "JSON -> C0 -> JSON round-trip preserves types" {
    const allocator = std.testing.allocator;

    const input = "{\"s\": \"text\", \"n\": 42, \"b\": true, \"nil\": null}";

    // Parse
    const parsed = try json.parseJson(allocator, input);
    defer json.freeJsonValue(allocator, parsed);

    // To C0 Value
    const c0_val = try json.toC0Value(allocator, parsed);
    defer json.freeC0Value(allocator, c0_val);

    // Encode
    const encoded = try core.encodeRaw(allocator, c0_val);
    defer allocator.free(encoded);

    // Decode
    const decoded_c0 = try core.decode(allocator, encoded);
    defer core.deinit(allocator, decoded_c0);

    // From C0 Value
    const decoded = try json.fromC0Value(allocator, decoded_c0);
    defer json.freeJsonValue(allocator, decoded);

    // Verify types
    try std.testing.expect(decoded == .object);
    for (decoded.object) |entry| {
        if (std.mem.eql(u8, entry.key, "s")) {
            try std.testing.expect(entry.value == .string);
        } else if (std.mem.eql(u8, entry.key, "n")) {
            try std.testing.expect(entry.value == .number);
        } else if (std.mem.eql(u8, entry.key, "b")) {
            try std.testing.expect(entry.value == .boolean);
        } else if (std.mem.eql(u8, entry.key, "nil")) {
            try std.testing.expect(entry.value == .null);
        }
    }
}

test "empty string as object value round-trip" {
    const allocator = std.testing.allocator;

    // Empty strings in object values round-trip correctly
    const input = "{\"key\": \"\"}";

    const parsed = try json.parseJson(allocator, input);
    defer json.freeJsonValue(allocator, parsed);

    const c0_val = try json.toC0Value(allocator, parsed);
    defer json.freeC0Value(allocator, c0_val);

    const encoded = try core.encodeRaw(allocator, c0_val);
    defer allocator.free(encoded);

    const decoded_c0 = try core.decode(allocator, encoded);
    defer core.deinit(allocator, decoded_c0);

    const decoded = try json.fromC0Value(allocator, decoded_c0);
    defer json.freeJsonValue(allocator, decoded);

    // Verify: object with key "key" and empty string value
    try std.testing.expect(decoded == .object);
    try std.testing.expectEqual(@as(usize, 1), decoded.object.len);
    try std.testing.expectEqualStrings("key", decoded.object[0].key);
    try std.testing.expect(decoded.object[0].value == .string);
    try std.testing.expectEqualStrings("", decoded.object[0].value.string);
}

// NOTE: [""] (array containing empty string) does NOT round-trip through C0.
// See json_content.zig for details on this known C0 format limitation.

test "nested arrays round-trip" {
    const allocator = std.testing.allocator;

    const input = "[[1, 2], [3, 4]]";

    const parsed = try json.parseJson(allocator, input);
    defer json.freeJsonValue(allocator, parsed);

    const c0_val = try json.toC0Value(allocator, parsed);
    defer json.freeC0Value(allocator, c0_val);

    const encoded = try core.encodeRaw(allocator, c0_val);
    defer allocator.free(encoded);

    const decoded_c0 = try core.decode(allocator, encoded);
    defer core.deinit(allocator, decoded_c0);

    const decoded = try json.fromC0Value(allocator, decoded_c0);
    defer json.freeJsonValue(allocator, decoded);

    // Verify structure
    try std.testing.expect(decoded == .array);
    try std.testing.expectEqual(@as(usize, 2), decoded.array.len);
    try std.testing.expect(decoded.array[0] == .array);
    try std.testing.expect(decoded.array[1] == .array);
    try std.testing.expectEqual(@as(usize, 2), decoded.array[0].array.len);
    try std.testing.expectEqual(@as(usize, 2), decoded.array[1].array.len);
}

test "JSON -> C0 -> JSON full round-trip structural equivalence" {
    const allocator = std.testing.allocator;

    // Complex JSON with all types, spaces, embedded JSON, and nested structures
    const input =
        \\{
        \\  "project": "c0",
        \\  "description": "A human-readable binary format!",
        \\  "version": "0.1.0",
        \\  "stable": false,
        \\  "downloads": 42,
        \\  "rating": 4.5,
        \\  "deprecated": null,
        \\  "keywords": ["binary", "format", "streaming", "human readable"],
        \\  "empty_string_test": "",
        \\  "empty_array_test": [],
        \\  "embedded_json": "{\"nested\": true, \"array\": [1, 2, 3]}",
        \\  "config": {
        \\    "debug": true,
        \\    "timeout_ms": 30000,
        \\    "ratio": 1.5e-3,
        \\    "message": "Hello, World!",
        \\    "features": {
        \\      "escaping": false,
        \\      "utf8": true,
        \\      "nested_arrays": [[1, 2], [3, 4]],
        \\      "mixed": [null, true, "text with spaces", -42]
        \\    }
        \\  }
        \\}
    ;

    // Parse original JSON
    const original_parsed = try json.parseJson(allocator, input);
    defer json.freeJsonValue(allocator, original_parsed);

    // Serialize original to canonical form
    const original_canonical = try json.stringify(allocator, original_parsed);
    defer allocator.free(original_canonical);

    // Round-trip through C0
    const c0_val = try json.toC0Value(allocator, original_parsed);
    defer json.freeC0Value(allocator, c0_val);

    const encoded = try core.encodeRaw(allocator, c0_val);
    defer allocator.free(encoded);

    const decoded_c0 = try core.decode(allocator, encoded);
    defer core.deinit(allocator, decoded_c0);

    const round_trip_parsed = try json.fromC0Value(allocator, decoded_c0);
    defer json.freeJsonValue(allocator, round_trip_parsed);

    // Serialize round-tripped to canonical form
    const round_trip_canonical = try json.stringify(allocator, round_trip_parsed);
    defer allocator.free(round_trip_canonical);

    // Canonical forms must match - this proves structural equivalence
    try std.testing.expectEqualStrings(original_canonical, round_trip_canonical);
}

test "JSON with spaces in strings round-trip" {
    const allocator = std.testing.allocator;

    const input = "{\"greeting\": \"Hello, World! How are you today?\"}";

    const parsed = try json.parseJson(allocator, input);
    defer json.freeJsonValue(allocator, parsed);

    const c0_val = try json.toC0Value(allocator, parsed);
    defer json.freeC0Value(allocator, c0_val);

    const encoded = try core.encodeRaw(allocator, c0_val);
    defer allocator.free(encoded);

    const decoded_c0 = try core.decode(allocator, encoded);
    defer core.deinit(allocator, decoded_c0);

    const decoded = try json.fromC0Value(allocator, decoded_c0);
    defer json.freeJsonValue(allocator, decoded);

    // Verify the string with spaces is preserved exactly
    try std.testing.expect(decoded == .object);
    try std.testing.expectEqual(@as(usize, 1), decoded.object.len);
    try std.testing.expectEqualStrings("greeting", decoded.object[0].key);
    try std.testing.expect(decoded.object[0].value == .string);
    try std.testing.expectEqualStrings("Hello, World! How are you today?", decoded.object[0].value.string);
}

test "string with C0 structural delimiters round-trip" {
    const allocator = std.testing.allocator;

    // A string containing C0's structural delimiters: { [ , :
    // C0 handles these transparently via printable-binary encoding
    const tricky_string = "config={debug:true}, items=[a,b,c]";

    // Create a JSON object with this tricky string as a value
    const input = "{\"data\": \"config={debug:true}, items=[a,b,c]\"}";

    const parsed = try json.parseJson(allocator, input);
    defer json.freeJsonValue(allocator, parsed);

    const c0_val = try json.toC0Value(allocator, parsed);
    defer json.freeC0Value(allocator, c0_val);

    const encoded = try core.encodeRaw(allocator, c0_val);
    defer allocator.free(encoded);

    const decoded_c0 = try core.decode(allocator, encoded);
    defer core.deinit(allocator, decoded_c0);

    const decoded = try json.fromC0Value(allocator, decoded_c0);
    defer json.freeJsonValue(allocator, decoded);

    // Verify the string with structural delimiters round-trips perfectly
    try std.testing.expect(decoded == .object);
    try std.testing.expectEqualStrings("data", decoded.object[0].key);
    try std.testing.expect(decoded.object[0].value == .string);
    // The original string is preserved exactly - C0 handles the encoding transparently!
    try std.testing.expectEqualStrings(tricky_string, decoded.object[0].value.string);
}

test "content-aware ISO 8601 timestamp round-trip" {
    const nanos = parseIso8601ToNanos("2025-01-10T12:05:00Z").?;
    var buf: [20]u8 = undefined;
    const recovered = nanosToIso8601(&buf, nanos);
    try std.testing.expectEqualStrings("2025-01-10T12:05:00Z", recovered);
}

test "content-aware C2PA round-trip" {
    const allocator = std.testing.allocator;

    const input =
        \\{"time": "2025-01-10T12:05:00Z", "cert_fingerprint": "fedcba9876543210", "name": "test"}
    ;

    const parsed = try json.parseJson(allocator, input);
    defer json.freeJsonValue(allocator, parsed);

    // Content-aware encode
    const c0_val = try contentAwareJsonToC0(allocator, parsed, null);
    defer freeContentAwareC0Value(allocator, c0_val);

    const encoded = try core.encodeRaw(allocator, c0_val);
    defer allocator.free(encoded);

    // Decode C0
    const decoded_c0 = try core.decode(allocator, encoded);
    defer core.deinit(allocator, decoded_c0);

    // Content-aware decode
    const decoded = try contentAwareC0ToJson(allocator, decoded_c0, null);
    defer json.freeJsonValue(allocator, decoded);

    // Verify round-trip
    try std.testing.expect(decoded == .object);
    for (decoded.object) |entry| {
        if (std.mem.eql(u8, entry.key, "time")) {
            try std.testing.expect(entry.value == .string);
            try std.testing.expectEqualStrings("2025-01-10T12:05:00Z", entry.value.string);
        } else if (std.mem.eql(u8, entry.key, "cert_fingerprint")) {
            try std.testing.expect(entry.value == .string);
            try std.testing.expectEqualStrings("fedcba9876543210", entry.value.string);
        } else if (std.mem.eql(u8, entry.key, "name")) {
            try std.testing.expect(entry.value == .string);
            try std.testing.expectEqualStrings("test", entry.value.string);
        }
    }
}
