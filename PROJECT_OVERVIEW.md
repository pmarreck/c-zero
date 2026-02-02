# C0 - Hierarchical Binary Data Stream Format

C0 is a byte-oriented, streaming-friendly serialization format for structured data (strings, arrays, objects). It uses ASCII C0 control characters as structural delimiters and printable_binary encoding for payloads.

## Key Properties

- **No escaping logic** - structural bytes can never appear in payloads
- **No length prefixes** - streaming-safe parsing
- **UTF-8 compatible** - human-readable when viewed as text
- **Deterministic** - same input always produces same output

## Terminology

- **Structural bytes**: FS (0x1C), GS (0x1D), RS (0x1E), US (0x1F)
- **Payload**: String data encoded via printable_binary
- **Value**: A string, array, or object
- **Entry**: A key-value pair in an object

## Architecture

Hexagonal design with three layers:
1. **Core** (pure Zig): Value types, encode/decode, no I/O
2. **FFI** (C ABI): Arena-based memory, exposes core to C consumers
3. **CLI** (C): Command-line interface consuming FFI

See `docs/plans/2026-02-02-c0-design.md` for full design.
