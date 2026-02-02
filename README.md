# C0

A hierarchical binary data stream format designed for human-readable UTF-8 environments.

## Features

- **No escaping** - Structural bytes never appear in payloads thanks to printable_binary encoding
- **Streaming-safe** - Parse in a single left-to-right pass without backtracking
- **UTF-8 compatible** - Human-readable when printed; control characters serve as delimiters
- **Deterministic** - Same input always produces same output; canonical encoding

## Quick Start

```bash
# Build
./build

# Encode a string
echo "hello world" | ./zig-out/bin/c0 encode

# Decode back
echo "hello world" | ./zig-out/bin/c0 encode | ./zig-out/bin/c0 decode
# Output: "hello world"
```

## Building

Requires Nix with flakes enabled:

```bash
# Debug build (via wrapper script)
./build

# Or directly with Nix
nix develop -c zig build

# Release build
nix develop -c zig build -Doptimize=ReleaseFast
```

## Testing

```bash
# Run all tests (Zig unit tests + CLI bash tests)
./test
```

## Architecture

C0 uses a hexagonal architecture:

- **Core** (`src/core/`) - Pure Zig encode/decode logic with no I/O
- **FFI** (`ffi/`) - Arena-based C API for external consumers
- **CLI** (`cli/`) - C command-line tool using FFI

### Data Types

C0 supports three value types:
- **String** - Arbitrary binary data (encoded via printable_binary)
- **Array** - Ordered sequence of values
- **Object** - Ordered key-value pairs (keys are strings)

### Structural Bytes

C0 uses ASCII C0 control characters as delimiters:
- `FS` (0x1C) - File Separator: begins object
- `GS` (0x1D) - Group Separator: begins array
- `RS` (0x1E) - Record Separator: terminates object entry
- `US` (0x1F) - Unit Separator: terminates array element / separates key from value

See `docs/plans/2026-02-02-c0-design.md` for full design documentation.

## License

MIT
