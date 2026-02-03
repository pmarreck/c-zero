//! C0 encoding constants and utilities
//!
//! Smart encoding heuristic:
//! - On encode: Only apply printable-binary if the data needs it (contains structural
//!   delimiters, control characters, or isn't already printable-binary encoded)
//! - On decode: By default decode printable-binary; with keep_printable=true, leave
//!   already-encoded data as-is (useful for JSON output)

const std = @import("std");
const pb = @import("printable_binary");

/// Structural delimiter constants (printable ASCII characters)
/// These characters are ALL escaped by printable_binary when they appear in payload data:
///   { → ❴, [ → ⟦, , → ٫, : → ꞉
/// This ensures no ambiguity: delimiters in data get escaped, structural delimiters don't.
pub const FS: u8 = '{'; // begins object
pub const GS: u8 = '['; // begins array
pub const RS: u8 = ','; // terminates object entry
pub const US: u8 = ':'; // terminates array element / separates key from value

/// Check if a byte is a structural delimiter
pub fn isStructural(byte: u8) bool {
    return byte == FS or byte == GS or byte == RS or byte == US;
}

/// Options for smart payload encoding
pub const EncodePayloadOptions = struct {
    /// Allow literal spaces in output (don't force encoding for spaces)
    /// Default true: spaces pass through unchanged for better readability
    allow_spaces: bool = true,
    /// Allow literal tabs in output (don't force encoding for tabs)
    allow_tabs: bool = false,
};

/// Options for smart payload decoding
pub const DecodePayloadOptions = struct {
    /// If true and data appears to be printable-binary encoded, leave it as-is
    /// Useful for JSON output where we want readable strings
    keep_printable: bool = false,
    /// Treat literal spaces as data (decode them to space bytes)
    /// Default true: matches the encoding default
    allow_spaces: bool = true,
};

/// Check if a byte is a control character that always requires encoding
/// This includes C0 control chars (0x00-0x1F) except optionally space/tab,
/// and DEL (0x7F)
fn isControlChar(byte: u8, options: EncodePayloadOptions) bool {
    // DEL
    if (byte == 0x7F) return true;
    // C0 control characters
    if (byte < 0x20) {
        // Newlines and carriage returns always require encoding
        if (byte == '\n' or byte == '\r') return true;
        // Space (0x20 isn't < 0x20 so this is actually tab check)
        if (byte == '\t') return !options.allow_tabs;
        // All other control chars require encoding
        return true;
    }
    // Space check (0x20)
    if (byte == ' ') return !options.allow_spaces;
    return false;
}

/// Check if data needs printable-binary encoding
/// Returns true if:
/// - Contains structural delimiters ({, [, ,, :)
/// - Contains control characters or required whitespace
/// - Is not valid UTF-8
pub fn needsEncoding(data: []const u8, options: EncodePayloadOptions) bool {
    // Check for structural delimiters and control chars in a single pass
    for (data) |byte| {
        if (isStructural(byte)) return true;
        if (isControlChar(byte, options)) return true;
    }

    // Must be valid UTF-8
    if (!std.unicode.utf8ValidateSlice(data)) return true;

    return false;
}

/// Check if data appears to be already printable-binary encoded
/// Returns true if every UTF-8 glyph is in the printable-binary target set
/// The options parameter controls which whitespace characters are allowed
pub fn isAlreadyEncoded(data: []const u8) bool {
    return isAlreadyEncodedWithOptions(data, .{});
}

/// Check if data appears to be already printable-binary encoded with custom options
pub fn isAlreadyEncodedWithOptions(data: []const u8, options: EncodePayloadOptions) bool {
    // Build whitespace flags based on options
    var ws_flags: c_uint = 0;
    if (options.allow_spaces) {
        ws_flags |= @intFromEnum(pb.WhitespaceFlags.allow_space);
    }
    if (options.allow_tabs) {
        ws_flags |= @intFromEnum(pb.WhitespaceFlags.allow_tab);
    }
    const result = pb.validate(data, ws_flags);
    return result.is_valid != 0;
}

/// Smart encode: only apply printable-binary if needed
/// If data is already printable-binary encoded, pass through unchanged
/// Caller owns returned slice
pub fn encodePayloadSmart(allocator: std.mem.Allocator, data: []const u8, options: EncodePayloadOptions) ![]u8 {
    // First check if it needs encoding at all
    if (!needsEncoding(data, options)) {
        // Check if it's already encoded (all glyphs in target set)
        if (isAlreadyEncodedWithOptions(data, options)) {
            // Already encoded, pass through
            return allocator.dupe(u8, data);
        }
    }

    // Needs encoding - apply printable-binary
    return pb.encode(allocator, data, .{
        .spaces = options.allow_spaces,
        .tabs = options.allow_tabs,
        .crlf = false, // Never preserve newlines
    });
}

/// Smart decode: optionally keep printable-binary encoded data as-is
/// Caller owns returned slice
pub fn decodePayloadSmart(allocator: std.mem.Allocator, data: []const u8, options: DecodePayloadOptions) ![]u8 {
    if (options.keep_printable) {
        // Check if data is all printable-binary glyphs (with space allowance matching options)
        if (isAlreadyEncodedWithOptions(data, .{ .allow_spaces = options.allow_spaces })) {
            // Keep as-is for readability
            return allocator.dupe(u8, data);
        }
    }

    // Decode normally - pass spaces option to treat literal spaces as data
    return pb.decode(allocator, data, .{ .spaces = options.allow_spaces });
}

/// Encode a string payload using printable_binary (always encodes)
/// Spaces pass through unchanged by default
/// Caller owns returned slice
pub fn encodePayload(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    return pb.encode(allocator, data, .{ .spaces = true });
}

/// Decode a string payload using printable_binary (always decodes)
/// Treats literal spaces as data (space passthrough)
/// Caller owns returned slice
pub fn decodePayload(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    return pb.decode(allocator, encoded, .{ .spaces = true });
}

test "structural byte detection" {
    try std.testing.expect(isStructural(FS));
    try std.testing.expect(isStructural(GS));
    try std.testing.expect(isStructural(RS));
    try std.testing.expect(isStructural(US));
    try std.testing.expect(isStructural('{'));
    try std.testing.expect(isStructural('['));
    try std.testing.expect(isStructural(','));
    try std.testing.expect(isStructural(':'));
    try std.testing.expect(!isStructural('a'));
    try std.testing.expect(!isStructural(0x00));
    try std.testing.expect(!isStructural('}'));
    try std.testing.expect(!isStructural(']'));
    try std.testing.expect(!isStructural(';'));
}

test "encodePayload never produces structural bytes" {
    const allocator = std.testing.allocator;

    // Test all possible single bytes
    var buf: [1]u8 = undefined;
    for (0..256) |i| {
        buf[0] = @intCast(i);
        const encoded = try encodePayload(allocator, &buf);
        defer allocator.free(encoded);

        // Verify no structural bytes in output
        for (encoded) |b| {
            try std.testing.expect(!isStructural(b));
        }
    }

    // Also test that the delimiter characters themselves get encoded safely
    const delimiter_bytes = [_]u8{ FS, GS, RS, US };
    const encoded = try encodePayload(allocator, &delimiter_bytes);
    defer allocator.free(encoded);

    // The encoded output should not contain any structural bytes
    for (encoded) |b| {
        try std.testing.expect(!isStructural(b));
    }
}

test "payload round-trip" {
    const allocator = std.testing.allocator;
    const original = "hello world \x00\x1c\x1d\x1e\x1f binary";

    const encoded = try encodePayload(allocator, original);
    defer allocator.free(encoded);

    const decoded = try decodePayload(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}

test "needsEncoding detects structural delimiters" {
    try std.testing.expect(needsEncoding("{hello}", .{}));
    try std.testing.expect(needsEncoding("[array]", .{}));
    try std.testing.expect(needsEncoding("a,b,c", .{}));
    try std.testing.expect(needsEncoding("key:value", .{}));
    try std.testing.expect(!needsEncoding("hello world", .{ .allow_spaces = true }));
}

test "needsEncoding detects control characters" {
    try std.testing.expect(needsEncoding("hello\x00world", .{}));
    try std.testing.expect(needsEncoding("line\nbreak", .{}));
    try std.testing.expect(needsEncoding("carriage\rreturn", .{}));
    try std.testing.expect(needsEncoding("has\ttab", .{}));
    try std.testing.expect(!needsEncoding("has\ttab", .{ .allow_tabs = true }));
}

test "needsEncoding detects invalid UTF-8" {
    try std.testing.expect(needsEncoding(&[_]u8{ 0x80, 0x81 }, .{})); // Invalid UTF-8
    try std.testing.expect(needsEncoding(&[_]u8{ 0xFF, 0xFE }, .{})); // Invalid UTF-8
}

test "isAlreadyEncoded recognizes printable-binary output" {
    const allocator = std.testing.allocator;

    // Encode something and check it's recognized as already encoded
    const encoded = try encodePayload(allocator, "hello{world}");
    defer allocator.free(encoded);

    try std.testing.expect(isAlreadyEncoded(encoded));

    // Plain ASCII that happens to be in the target set
    try std.testing.expect(isAlreadyEncoded("hello"));
    try std.testing.expect(isAlreadyEncoded("ABC123"));

    // With default allow_spaces=true, spaces are accepted
    try std.testing.expect(isAlreadyEncoded("hello world")); // space allowed by default

    // Newlines are never allowed
    try std.testing.expect(!isAlreadyEncoded("hello\nworld")); // newline not in target

    // With explicit allow_spaces=false, spaces are rejected
    try std.testing.expect(!isAlreadyEncodedWithOptions("hello world", .{ .allow_spaces = false }));
}

test "encodePayloadSmart avoids double-encoding" {
    const allocator = std.testing.allocator;

    // First encode some data with structural chars
    const original = "key{value}";
    const encoded_once = try encodePayload(allocator, original);
    defer allocator.free(encoded_once);

    // Smart encode the already-encoded data - should pass through
    const encoded_smart = try encodePayloadSmart(allocator, encoded_once, .{});
    defer allocator.free(encoded_smart);

    // Should be the same (not double-encoded)
    try std.testing.expectEqualStrings(encoded_once, encoded_smart);

    // Decode should give us back the original
    const decoded = try decodePayload(allocator, encoded_smart);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}

test "encodePayloadSmart encodes when needed" {
    const allocator = std.testing.allocator;

    // Data with structural delimiter needs encoding
    const with_delim = "hello{world";
    const encoded = try encodePayloadSmart(allocator, with_delim, .{});
    defer allocator.free(encoded);

    // Should be different (was encoded)
    try std.testing.expect(!std.mem.eql(u8, with_delim, encoded));

    // Decode should give us back the original
    const decoded = try decodePayload(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(with_delim, decoded);
}

test "decodePayloadSmart with keep_printable" {
    const allocator = std.testing.allocator;

    // Encode something
    const original = "test{data}";
    const encoded = try encodePayload(allocator, original);
    defer allocator.free(encoded);

    // With keep_printable=true, should stay encoded
    const kept = try decodePayloadSmart(allocator, encoded, .{ .keep_printable = true });
    defer allocator.free(kept);
    try std.testing.expectEqualStrings(encoded, kept);

    // With keep_printable=false (default), should decode
    const decoded = try decodePayloadSmart(allocator, encoded, .{});
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(original, decoded);
}
