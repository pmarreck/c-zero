//! C0 Core - Hierarchical binary data stream encoding/decoding
//!
//! This module provides the pure encoding/decoding logic with no I/O.

pub const value = @import("value.zig");
pub const Value = value.Value;
pub const Entry = value.Entry;

test {
    _ = value;
}
