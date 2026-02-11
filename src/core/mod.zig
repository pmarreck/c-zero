//! C0 Core - Hierarchical binary data stream encoding/decoding
//!
//! This module provides the pure encoding/decoding logic with no I/O.

pub const value = @import("value.zig");
pub const Value = value.Value;
pub const Entry = value.Entry;

pub const encoding = @import("encoding.zig");
pub const OBJECT_OPEN = encoding.OBJECT_OPEN;
pub const OBJECT_CLOSE = encoding.OBJECT_CLOSE;
pub const ARRAY_OPEN = encoding.ARRAY_OPEN;
pub const ARRAY_CLOSE = encoding.ARRAY_CLOSE;
pub const COMMA = encoding.COMMA;
pub const COLON = encoding.COLON;
/// Legacy aliases (deprecated)
pub const FS = encoding.FS;
pub const GS = encoding.GS;
pub const RS = encoding.RS;
pub const US = encoding.US;
pub const encodePayload = encoding.encodePayload;
pub const decodePayload = encoding.decodePayload;

pub const encoder = @import("encoder.zig");
pub const encode = encoder.encode;
pub const encodeWithOptions = encoder.encodeWithOptions;
pub const EncodeOptions = encoder.EncodeOptions;
pub const encodeRaw = encoder.encodeRaw;

pub const decoder = @import("decoder.zig");
pub const decode = decoder.decode;
pub const deinit = decoder.deinitValue;
pub const DecodeError = decoder.DecodeError;

pub const json_content = @import("json_content.zig");
pub const JsonValue = json_content.JsonValue;
pub const JsonEntry = json_content.JsonEntry;
pub const valueToJson = json_content.valueToJson;

pub const query = @import("query.zig");
pub const queryValue = query.queryValue;
pub const parsePath = query.parsePath;

pub const interpret = @import("interpret.zig");
pub const TypeSpec = interpret.TypeSpec;
pub const parseTypeName = interpret.parseTypeName;

test {
    _ = value;
    _ = encoding;
    _ = encoder;
    _ = decoder;
    _ = json_content;
    _ = query;
    _ = interpret;
    _ = @import("roundtrip_test.zig");
}
