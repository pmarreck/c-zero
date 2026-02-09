# C0

A hierarchical binary data stream format designed for human-readable UTF-8 environments.

C0 builds on [**printable-binary**](https://github.com/pmarreck/printable-binary), a separate encoding that transforms arbitrary bytes into readable UTF-8 glyphs. While printable-binary handles the byte-to-glyph mapping, C0 adds hierarchical structure (arrays and objects) on top.

**C0 is format-agnostic.** It doesn't care what your binary data represents - it merely provides a human-readable, editor-compatible, terminal-friendly representation of structured data containing arbitrary binary values. Your data could be images, executables, network packets, or anything else. C0 just makes it visible and organizable.

### Why "C0"?

The name "C0" is a historical nod to the [C0 control codes](https://en.wikipedia.org/wiki/C0_and_C1_control_codes) (bytes 0x00-0x1F in ASCII), which include characters like File Separator (FS), Group Separator (GS), Record Separator (RS), and Unit Separator (US). Early versions of this format actually used these control codes as structural delimiters.

However, raw control codes cause problems: they're invisible in editors, break terminal output, and can't be safely copy-pasted. So we switched to printable ASCII delimiters (`{`, `[`, `,`, `:`) that printable-binary escapes when they appear in data. The name stuck as a reminder of the format's origins and its purpose: structured data with clear separation.

## Why C0?

**C0 solves the "binary in text" problem differently:**

| Approach | Binary Data | Readability | Size Overhead |
|----------|-------------|-------------|---------------|
| JSON + Base64 | Encoded to ASCII gibberish | Poor | ~33% |
| MessagePack | Raw binary | None (binary format) | Minimal |
| C0 | Encoded to readable UTF-8 | Good - ASCII text stays readable | ~5-40%* |

*Text-heavy data can be smaller than base64; pure binary has higher overhead

**Example:** Embedding `"Hello, World!\x00\x01\x02"` in a structure:

```
JSON:     {"data": "SGVsbG8sIFdvcmxkIQABAg=="}  (base64 - unreadable)
C0:       {data:Hello٫ Worldǃ·¯«,              (readable!)
```

The ASCII text "Hello, World!" remains visible in C0 output, while special bytes become recognizable Unicode glyphs. Only the comma and exclamation mark are encoded (`٫` and `ǃ`) because they're structural delimiters.

## Features

- **Human-readable binary** - ASCII text stays readable; binary becomes recognizable glyphs
- **Space-efficient** - Often smaller than base64 for text-heavy data
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
- Space encoding is configurable (disabled by default for readability)

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
Output: ɃPNG⏎¶Hello from binaryǃ
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

The JSON demo shows **content-aware** JSON ↔ C0 conversion using a real-world [C2PA manifest](https://blog.cloudflare.com/preserve-content-credentials-with-cloudflare-images/) as input. C0 doesn't prescribe content semantics - the demo shows what an application-specific encoder might look like, with field-specific transforms for timestamps (→ 8-byte nanosecond-epoch binary) and cert fingerprints (→ raw binary), while keeping dimensions as readable numbers.

```bash
zig build run-json-demo
```

Full output:
```
=== C0 Content-Aware JSON Demo ===

NOTE: C0 doesn't prescribe content semantics - this demo shows what
an application-specific encoder might look like.

1. Input JSON - C2PA manifest (629 bytes):
{"jumbf": {"c2pa.manifest.nikon": {"status": "preserved-from-camera"}, "c2pa.manifest.cloudflare": {"claim_generator": "Cloudflare Images", "assertions": [{"label": "c2pa.actions", "data": {"actions": [{"action": "c2pa.resized", "when": "2025-01-10T12:05:00Z", "softwareAgent": "Cloudflare Images", "parameters": {"originalDimensions": {"width": 8256, "height": 5504}, "newDimensions": {"width": 800, "height": 533}}}]}}], "signature_info": {"issuer": "Cloudflare, Inc", "time": "2025-01-10T12:05:00Z", "cert_fingerprint": "fedcba9876543210"}, "claim_metadata": {"claim_id": "cf_resize_123", "parent_claim_id": "nikon_z9_123"}}}}

2. Content-aware C0 encoded (503 bytes):
{jumbf:{c2pa.manifest.nikon:{status:preserved˗from˗camera,,c2pa.manifest.cloudflare:{claim_generator:Cloudflare Images,assertions:[{label:c2pa.actions,data:{actions:[{action:c2pa.resized,when:©¦SGż⁎8·,softwareAgent:Cloudflare Images,parameters:{originalDimensions:{width:8256,height:5504,,newDimensions:{width:800,height:533,,,:,,:,signature_info:{issuer:Cloudflare٫ Inc,time:©¦SGż⁎8·,cert_fingerprint:żŗĴȸvT2Ɣ,,claim_metadata:{claim_id:cf_resize_123,parent_claim_id:nikon_z9_123,,,,

   Transformations applied:
   - Timestamps -> 8-byte nanosecond-epoch binary (pb-encoded)
   - Cert fingerprint -> raw binary (pb-encoded)
   - Dimensions -> kept as readable numbers

3. Decoded back to JSON (629 bytes):
{"jumbf": {"c2pa.manifest.nikon": {"status": "preserved-from-camera"}, "c2pa.manifest.cloudflare": {"claim_generator": "Cloudflare Images", "assertions": [{"label": "c2pa.actions", "data": {"actions": [{"action": "c2pa.resized", "when": "2025-01-10T12:05:00Z", "softwareAgent": "Cloudflare Images", "parameters": {"originalDimensions": {"width": 8256, "height": 5504}, "newDimensions": {"width": 800, "height": 533}}}]}}], "signature_info": {"issuer": "Cloudflare, Inc", "time": "2025-01-10T12:05:00Z", "cert_fingerprint": "fedcba9876543210"}, "claim_metadata": {"claim_id": "cf_resize_123", "parent_claim_id": "nikon_z9_123"}}}}

   Note: Timestamps decoded with second resolution (nanosecond precision stored)

=== Size: JSON 629 bytes -> C0 503 bytes (80.0%) ===

=== Bonus: Printable-Binary Encoding Demo ===

5. Raw binary (23 bytes):
   \x89PNG\x0d\x0a\x1a\x0a\x00\x01\x02\x03Hello\x00World

6. Printable-binary encoded (34 bytes):
   ɃPNG⏎¶Ƶ¶·¯«»Hello·World

7. Embedding binary in JSON via C0:
   C0 output (95 bytes):
   {png_header:ɃPNG⏎¶Ƶ¶·¯«»Hello·World,description:PNG file with null bytes embeddedǃ,

   Note: The binary data remains readable as printable-binary glyphs!
   'PNG' is visible, control bytes become distinct Unicode characters.

8. Embedded JSON - The Antidote to Escaping Hell:

   TRADITIONAL JSON (escaping hell):
   {"data": "{\"inner\": [1, 2, 3], \"nested\": true}"}

   WITH PRINTABLE-BINARY (no escaping needed!):
   {"data": "❴˵inner˵꞉ ⟦1٫ 2٫ 3⟧٫ ˵nested˵꞉ true❵"}

   The pb-encoded JSON uses different Unicode delimiters:
     { -> ❴    [ -> ⟦    , -> ٫    : -> ꞉    " -> ˵
   So you can embed it directly in a JSON string without backslash escaping!

   Round-trip proof - decode the pb-encoded JSON:
   Decoded: {"inner": [1, 2, 3], "nested": true}

9. Binary-in-JSON: Inspectable Data Pipeline
   ...
```

Notice how the C0 output remains readable: `preserved˗from˗camera`, `Cloudflare٫ Inc`. Hyphens and commas in string content become distinctive Unicode glyphs (`˗`, `٫`) while structural delimiters (`{`, `[`, `,`, `:`) remain as ASCII. C0 is format-agnostic — type inference is handled by the JSON content layer on decode. The content-aware transforms compress timestamps like `"2025-01-10T12:05:00Z"` (20 chars) into `©¦SGż⁎8·` (8 glyphs, 14 UTF-8 bytes encoding 8 bytes of nanosecond-epoch binary) — smaller, still copy-pastable, and actually *more* precise than the original ISO 8601 string, if you're willing to trade human-readability for compactness. Hex fingerprints similarly become raw binary glyphs.

### Binary Demo
Shows C0 as a container for arbitrary binary data:
```bash
zig build run-binary-demo
```

Sample output:
```
--- Demo 2: Structured Binary Message ---
C0 encoded (113 bytes):
{header:[⌦ELF:«:¯···:,payload:This is the payload data...

--- Demo 4: Size Comparison with Base64 ---
Data Type              Original         C0    Base64*
ASCII text                   39         41         52
Binary blob                  16         36         24
Mixed data                   32         44         44
```

### PNG Destructuring Demo
Proves C0 can losslessly destructure and reconstruct a real binary file format:
```bash
zig build run-png-demo -- path/to/image.png
```

Sample output:
```
=== C0 PNG Destructuring Demo ===

File: new_record_1h39m.png
Size: 13838 bytes
Chunks: 6

Chunk layout:
  IHDR      13 bytes
  iCCP     330 bytes
  eXIf      86 bytes
  iTXt     469 bytes
  IDAT   12860 bytes
  IEND       0 bytes

IHDR: 354x87, 8-bit RGBA

C0 snippet (first 200 bytes):
{signature:ɃPNG⏎¶Ƶ¶,chunks:[{type:IHDR,data:··¯b···W⌫¡···,crc:˃ȡOǑ,:{type:iCCP,data:ICC Profile··...

=== Round-Trip Verification ===
Original:    13838 bytes
Reassembled: 13838 bytes
Byte-for-byte match: true
```

The PNG is destructured into its chunks as a C0 object. Chunk type names (`IHDR`, `iCCP`, `IDAT`, etc.) remain readable as ASCII, while binary payloads become printable-binary glyphs. The entire C0 text is valid UTF-8 that can be stored in text fields, logged, or piped through text tools. Decoding and reassembling produces the identical PNG byte-for-byte.

## Dependencies

### printable-binary

C0 uses [printable-binary](https://github.com/pmarreck/printable-binary) for encoding arbitrary bytes into readable UTF-8 glyphs. This is a **separate, independent project** that can be used standalone for any binary-to-text encoding needs.

Key features of printable-binary:
- Every byte (0x00-0xFF) maps to a distinct, visually recognizable UTF-8 glyph
- ASCII text passes through unchanged (including spaces by default)
- Structural delimiters used by C0 are escaped: `{→❴`, `[→⟦`, `,→٫`, `:→꞉`
- Fully reversible - decode always recovers the original bytes

## Documentation

See `docs/plans/` for design documentation.

## License

MIT
