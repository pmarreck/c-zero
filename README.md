# C0

A hierarchical binary data stream format designed for human-readable UTF-8 environments.

## Why C0?

**C0 solves the "binary in text" problem differently:**

| Approach | Binary Data | Readability | Size Overhead |
|----------|-------------|-------------|---------------|
| JSON + Base64 | Encoded to ASCII gibberish | Poor | ~33% |
| MessagePack | Raw binary | None (binary format) | Minimal |
| C0 | Encoded to readable UTF-8 | Good - ASCII stays readable | ~15-40% |

**Example:** Embedding `"Hello, World!\x00\x01\x02"` in a structure:

```
JSON:     {"data": "SGVsbG8sIFdvcmxkIQABAg=="}  (base64 - unreadable)
C0:       {data:Hello٫␣Worldǃ·¯«,              (readable!)
```

The ASCII text "Hello, World!" remains visible in C0 output, while special bytes become recognizable Unicode glyphs.

## Features

- **Human-readable binary** - ASCII text stays readable; binary becomes recognizable glyphs
- **No escaping needed** - Structural delimiters never appear in payloads (printable_binary encoding)
- **Streaming-safe** - Parse in a single left-to-right pass without backtracking
- **UTF-8 native** - Output is always valid UTF-8
- **Deterministic** - Same input always produces same output

## Quick Start

```bash
# Build
./build

# Encode a string
echo "hello world" | ./zig-out/bin/c0 encode

# Decode back
echo "hello world" | ./zig-out/bin/c0 encode | ./zig-out/bin/c0 decode
# Output: "hello world"

# Run the demos
zig build run-json-demo      # JSON <-> C0 conversion
zig build run-binary-demo    # Binary data container demo
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

### Structural Delimiters

C0 uses printable ASCII characters as structural delimiters:

| Delimiter | Character | Purpose |
|-----------|-----------|---------|
| `{` | Open brace | Begins object |
| `[` | Open bracket | Begins array |
| `,` | Comma | Terminates object entry |
| `:` | Colon | Terminates array element / separates key from value |

These characters are **escaped by printable_binary** when they appear in payload data:
- `{` → `❴` (U+2774)
- `[` → `⟦` (U+27E6)
- `,` → `٫` (U+066B)
- `:` → `꞉` (U+A789)

This ensures no ambiguity: delimiters in data get escaped, structural delimiters don't.

### Smart Encoding

C0 uses intelligent encoding to avoid double-encoding:
- Data that doesn't need encoding (no structural bytes, valid UTF-8) passes through unchanged
- Data that's already printable_binary encoded is detected and not re-encoded
- Only data requiring encoding (contains structural bytes, control chars, or invalid UTF-8) gets encoded

### Examples

**Simple array:**
```
["hello", "world"]  →  [hello:world:
```

**Object:**
```
{"key": "value"}  →  {key:value,
```

**Nested structure:**
```
{"arr": ["x", "y"]}  →  {arr:[x:y:,
```

**Binary data with visible ASCII:**
```
Input:  \x89PNG\r\n + "Hello from binary!"
Output: ɃPNG⏎¶Hello␣from␣binaryǃ
```

The "PNG" and "Hello from binary!" parts remain readable, while control bytes become distinctive glyphs.

## Use Cases

1. **Log files** - Embed binary payloads in text logs that remain grep-able
2. **Configuration** - Store binary blobs alongside text config
3. **Network debugging** - Capture packets in human-readable format
4. **Data archives** - Bundle files with readable metadata
5. **JSON alternative** - When you need binary support without base64

## Demos

### JSON Demo
Shows bidirectional JSON ↔ C0 conversion with all JSON types preserved:
```bash
zig build run-json-demo
```

### Binary Demo
Shows C0 as a container for arbitrary binary data:
```bash
zig build run-binary-demo
```

Sample output:
```
--- Demo 2: Structured Binary Message ---
C0 encoded (129 bytes):
{header:[⌦ELF:«:¯···:,payload:This␣is␣the␣payload...

--- Demo 4: Size Comparison with Base64 ---
Data Type              Original         C0    Base64*
ASCII text                   39         53         52
Binary blob                  16         36         24
Mixed data                   32         48         44
```

## Documentation

See `docs/plans/` for design documentation.

## License

MIT
