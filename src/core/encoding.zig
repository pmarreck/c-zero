//! C0 encoding constants and utilities

const std = @import("std");
const pb = @import("printable_binary");

/// Structural byte constants (ASCII C0 control characters)
pub const FS: u8 = 0x1C; // File Separator - begins object
pub const GS: u8 = 0x1D; // Group Separator - begins array
pub const RS: u8 = 0x1E; // Record Separator - terminates object entry
pub const US: u8 = 0x1F; // Unit Separator - terminates array element / separates key from value

/// Check if a byte is a structural delimiter
pub fn isStructural(byte: u8) bool {
	return byte == FS or byte == GS or byte == RS or byte == US;
}

/// Encode a string payload using printable_binary
/// Caller owns returned slice
pub fn encodePayload(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
	return pb.encode(allocator, data, .{});
}

/// Decode a string payload using printable_binary
/// Caller owns returned slice
pub fn decodePayload(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
	return pb.decode(allocator, encoded, .{});
}

test "structural byte detection" {
	try std.testing.expect(isStructural(FS));
	try std.testing.expect(isStructural(GS));
	try std.testing.expect(isStructural(RS));
	try std.testing.expect(isStructural(US));
	try std.testing.expect(!isStructural('a'));
	try std.testing.expect(!isStructural(0x00));
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
