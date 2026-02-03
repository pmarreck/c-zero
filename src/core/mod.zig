//! C0 Core - Hierarchical binary data stream encoding/decoding
//!
//! This module provides the pure encoding/decoding logic with no I/O.

pub const value = @import("value.zig");
pub const Value = value.Value;
pub const Entry = value.Entry;

pub const encoding = @import("encoding.zig");
pub const FS = encoding.FS;
pub const GS = encoding.GS;
pub const RS = encoding.RS;
pub const US = encoding.US;

pub const encoder = @import("encoder.zig");
pub const encode = encoder.encode;

pub const decoder = @import("decoder.zig");
pub const decode = decoder.decode;
pub const deinit = decoder.deinitValue;
pub const DecodeError = decoder.DecodeError;

pub const json_content = @import("json_content.zig");
pub const JsonValue = json_content.JsonValue;
pub const JsonEntry = json_content.JsonEntry;

test {
    _ = value;
    _ = encoding;
    _ = encoder;
    _ = decoder;
    _ = json_content;
    _ = @import("roundtrip_test.zig");
}
