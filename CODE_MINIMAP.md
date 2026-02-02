# C0 Code Minimap

## src/core/

### mod.zig
Public API entry point. Re-exports all core types and functions.
- `Value`, `Entry` - data types
- `encode()` - Value -> C0 bytes
- `decode()` - C0 bytes -> Value
- `deinit()` - free decoded Value
- `FS`, `GS`, `RS`, `US` - structural byte constants

### value.zig
Value type definitions.
- `Value` - tagged union (string/array/object)
- `Entry` - key-value pair for objects
- `eql()` - deep equality comparison

### encoding.zig
Low-level encoding utilities.
- `FS`, `GS`, `RS`, `US` - structural byte constants (0x1C-0x1F)
- `isStructural()` - check if byte is delimiter
- `encodePayload()` - wrap printable_binary encode
- `decodePayload()` - wrap printable_binary decode

### encoder.zig
Encoder implementation.
- `encode()` - convert Value to C0 binary format
- Handles strings, arrays, objects, and nested structures
- Uses printable_binary to escape payload bytes

### decoder.zig
Decoder implementation.
- `decode()` - parse C0 binary to Value
- `deinitValue()` - recursive free for decoded values
- `DecodeError` - error types (TrailingData, MissingUnitSeparator, etc.)

### roundtrip_test.zig
Comprehensive round-trip tests.
- Tests for strings, arrays, objects
- Tests for nested structures
- Tests for special bytes and edge cases
- Documents known format limitations

## ffi/

### c_api.zig
C ABI exports with arena-based memory management.
- `C0Arena` - opaque arena type for bulk allocation
- `C0Value` - mutable value wrapper for building structures
- Value constructors: `c0_string()`, `c0_array()`, `c0_object()`
- Array ops: `c0_array_push()`, `c0_array_len()`, `c0_array_get()`
- Object ops: `c0_object_set()`, `c0_object_len()`, `c0_object_key()`, `c0_object_value()`
- Inspection: `c0_is_string()`, `c0_is_array()`, `c0_is_object()`, `c0_string_data()`
- Encode/decode: `c0_encode()`, `c0_decode()`

### c0.h
C header file for FFI consumers.
- Opaque types: `C0Arena`, `C0Value`
- Error codes: `C0_OK`, `C0_ERR_NULL_ARG`, `C0_ERR_OUT_OF_MEMORY`, etc.
- Function declarations for all FFI exports
- C++ compatibility with extern "C"

## cli/

### main.c
C CLI implementation using the FFI layer.
- `encode` command - read text from stdin, encode as C0 string, write binary to stdout
- `decode` command - read C0 binary from stdin, pretty-print as JSON-like structure
- Handles arbitrary binary data with proper escaping
- Dynamic buffer growth for large inputs
