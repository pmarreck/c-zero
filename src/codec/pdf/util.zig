//! Shared PDF lexical helpers.
//!
//! Small character-classification utilities used across the PDF parser, filter
//! decoders, and xref parser. Factored here so the PDF whitespace set and
//! hex-digit decoding have a single source of truth.

/// Decode a single ASCII hex digit (0-9, A-F, a-f) into its 4-bit value.
/// Returns null for non-hex bytes.
pub fn hexToNibble(ch: u8) ?u4 {
    return switch (ch) {
        '0'...'9' => @intCast(ch - '0'),
        'A'...'F' => @intCast(ch - 'A' + 10),
        'a'...'f' => @intCast(ch - 'a' + 10),
        else => null,
    };
}

/// True for the six bytes the PDF spec (ISO 32000-1, Table 1) classifies as
/// whitespace: NUL, TAB, LF, FF, CR, and SPACE.
pub fn isWhitespace(ch: u8) bool {
    return switch (ch) {
        ' ', '\t', '\n', '\r', '\x0c', '\x00' => true,
        else => false,
    };
}
