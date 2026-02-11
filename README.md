# C0

A hierarchical binary data stream format designed for human-readable UTF-8 environments.

C0 builds on [**printable-binary**](https://github.com/pmarreck/printable-binary), a separate encoding that transforms arbitrary bytes into readable UTF-8 glyphs. While printable-binary handles the byte-to-glyph mapping, C0 adds hierarchical structure (arrays and objects) on top.

**C0 is format-agnostic.** It doesn't care what your binary data represents - it merely provides a human-readable, editor-compatible, terminal-friendly representation of structured data containing arbitrary binary values. Your data could be images, executables, network packets, or anything else. C0 just makes it visible and organizable.

### Why "C0"?

The name "C0" is a historical nod to the [C0 control codes](https://en.wikipedia.org/wiki/C0_and_C1_control_codes) (bytes 0x00-0x1F in ASCII), which include characters like File Separator (FS), Group Separator (GS), Record Separator (RS), and Unit Separator (US). Early versions of this format actually used these control codes as structural delimiters.

However, raw control codes cause problems: they're invisible in editors, break terminal output, and can't be safely copy-pasted. So we switched to printable ASCII delimiters (`{`, `}`, `[`, `]`, `,`, `:`) — the same six characters JSON uses — that printable-binary escapes when they appear in data. The result is essentially **JSON without quotes, with printable-binary encoding instead of escape sequences**. The name stuck as a reminder of the format's origins and its purpose: structured data with clear separation.

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
C0:       {data:Hello٫ Worldǃ·¯«}              (readable!)
```

The ASCII text "Hello, World!" remains visible in C0 output, while special bytes become recognizable Unicode glyphs. The comma becomes `٫` because it's a structural delimiter, and the exclamation mark becomes `ǃ` because printable-binary escapes symbols that are commonly overloaded in programming contexts.

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

# Expand a binary file to human-readable C0 text
c0 expand image.png > image.c0

# Collapse C0 text back to the original binary format
c0 collapse image.c0 > roundtrip.png

# Editable mode (omits derived fields like CRC, recalculates on collapse)
c0 expand --editable image.png | c0 collapse --editable > edited.png

# List available codecs
c0 codecs

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
- **Codec** (`src/codec/`) - Plugin system for binary format expansion/collapse
- **FFI** (`ffi/`) - Arena-based C API for external consumers
- **CLI** (`cli/`) - C command-line tool using FFI

### Data Types

C0 supports three value types:
- **String** - Arbitrary binary data (encoded via printable_binary)
- **Array** - Ordered sequence of values
- **Object** - Ordered key-value pairs (keys are strings)

### Structural Delimiters

C0 uses the same six printable ASCII characters as JSON for structure:

| Delimiter | Character | Purpose |
|-----------|-----------|---------|
| `{` | Open brace | Begins object |
| `}` | Close brace | Ends object |
| `[` | Open bracket | Begins array |
| `]` | Close bracket | Ends array |
| `,` | Comma | Separates entries/elements |
| `:` | Colon | Separates key from value |

These characters are **escaped by printable_binary** when they appear in payload data:
- `{` → `❴` (U+2774), `}` → `❵` (U+2775)
- `[` → `⟦` (U+27E6), `]` → `⟧` (U+27E7)
- `,` → `٫` (U+066B)
- `:` → `꞉` (U+A789)

This ensures no ambiguity: delimiters in data get escaped, structural delimiters don't.

### Whitespace

**Spaces** are significant content. **Tabs and newlines** are insignificant — stripped during parsing. This enables pretty-printed output that round-trips identically to compact output.

### Smart Encoding

C0 uses intelligent encoding to avoid double-encoding:
- Data that doesn't need encoding (no structural bytes, valid UTF-8) passes through unchanged
- Data that's already printable_binary encoded is detected and not re-encoded
- Only data requiring encoding (contains structural bytes, control chars, or invalid UTF-8) gets encoded
- Space encoding is configurable (disabled by default for readability)

### Examples

**Simple array:**
```
["hello", "world"]  →  [hello,world]
```

**Object:**
```
{"key": "value"}  →  {key:value}
```

**Nested structure:**
```
{"arr": ["x", "y"]}  →  {arr:[x,y]}
```

**Pretty-printed** (same data, with insignificant whitespace):
```
{
	arr:[
		x,
		y
	]
}
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
6. **Test suites** - Include binary snippets directly in test fixtures as readable text, assert on binary outputs, or provide binary inputs to processes — no more hex dumps or base64 blobs in your test data
7. **UTF-8 debugging** - Make normally-invisible characters visible using printable-binary encoding — control characters, zero-width spaces, directional overrides, and other non-printing codepoints become distinct readable glyphs

## Codec System

C0 includes a codec plugin architecture that transforms binary file formats into human-readable, editable C0 text — and back again with lossless round-trips.

### Built-in Codecs

| Codec | Extensions | Modes | Description |
|-------|-----------|-------|-------------|
| `png` | `.png` | faithful, editable | PNG image format (lossless chunk destructuring) |
| `bg3` | `.lsv`, `.pak`, `.lsf` | faithful | Baldur's Gate 3 save files (LSPK packages and LSF data) |
| `json` | `.json` | faithful, editable | JSON format (bidirectional with type-prefixed scalars) |

### Expand / Collapse

**Expand** converts a binary file into pretty-printed C0 text:
```bash
c0 expand image.png
# Output:
# {
# 	format:png,
# 	signature:ɃPNG⏎¶Ƶ¶,
# 	chunks:[
# 		{type:IHDR,data:...},
# 		...
# 	]
# }
```

**Expand** also works for text formats like JSON, using type prefixes instead of printable-binary encoding:
```bash
c0 expand data.json
# Output:
# {
# 	format:json,
# 	value:{
# 		name:˵Alice,
# 		age:i30,
# 		scores:[i100,f95.5],
# 		active:bT,
# 		notes:n
# 	}
# }
```

Type prefixes: `"` = string, `i` = integer, `f` = float, `bT`/`bF` = boolean, `n` = null.

**Collapse** converts C0 text back to the native format:
```bash
c0 expand image.png | c0 collapse > roundtrip.png
# roundtrip.png is byte-identical to image.png
```

Use `--compact` for single-line output (e.g., for piping or storage):
```bash
c0 expand --compact image.png
```

Every codec embeds a `format` key in its C0 output, making the data self-describing. On collapse, the codec is inferred from this field automatically.

### Faithful vs Editable Mode

- **Faithful** (default): Preserves all fields for bit-perfect round-trips. CRCs, checksums, and derived fields are stored as-is.
- **Editable** (`--editable`): Omits derived fields (like CRC). On collapse, they are recalculated. This lets you edit chunk data without manually fixing checksums.

```bash
# Edit a PNG: expand in editable mode, modify the C0 text, collapse back
c0 expand --editable image.png > image.c0
# ... edit image.c0 ...
c0 collapse --editable image.c0 > modified.png
```

### Auto-Detection

Codecs are matched by magic bytes first, then by file extension:
```bash
c0 expand myfile.png          # auto-detected from magic bytes
c0 expand --codec png myfile  # explicit codec selection
```

### Query & Transform (`get`, `set`, `to-json`)

**`c0 get`** extracts values by jq-style path — strings are printed raw, structures as compact C0:
```bash
c0 expand data.json | c0 get .value.name
# Alice

c0 expand data.json | c0 get .value.scores[0]
# i100

c0 expand data.json | c0 get .format
# json
```

**`c0 set`** replaces a value at a path and emits the updated C0:
```bash
c0 expand data.json | c0 set .value.name Bob > updated.c0
c0 expand data.json | c0 set .value.scores[0] i999 | c0 collapse > modified.json
```

**`c0 to-json`** converts any C0 data to JSON for interop with tools like `jq`. This is a **naive one-way conversion** — all C0 strings become JSON strings with no type interpretation:
```bash
c0 expand image.png | c0 to-json | jq '.chunks[0].type'
# "IHDR"

c0 expand data.json | c0 to-json
# {"format": "json", "value": {"name": "\"Alice", "age": "i30", ...}}
#                                       ^--- type prefix is literal
```

> **`to-json` vs JSON codec**: The `json` codec (`c0 expand/collapse`) does type-preserving round-trips using prefixes (`"` = string, `i` = int, `f` = float, `bT`/`bF` = bool, `n` = null). The `to-json` command is a dumb pipe — it turns any C0 into valid JSON for external tools, but doesn't interpret or strip type prefixes. Use the codec for JSON editing, `to-json` for interop.

### External Codecs (Subprocess Protocol)

You can extend C0 with your own codecs. Place an executable named `c0-codec-<name>` in `~/.c0/codecs/` or anywhere on your `PATH`. It must support three subcommands:

```bash
c0-codec-myformat info                 # Print codec metadata as C0 to stdout
c0-codec-myformat expand [--editable]  # stdin: raw bytes -> stdout: C0 text
c0-codec-myformat collapse [--editable] # stdin: C0 text -> stdout: raw bytes
```

The `info` subcommand outputs C0-formatted metadata:
```
{name:myformat,description:My custom format,extensions:[.myf],supports_faithful:true,supports_editable:true}
```

Built-in codecs always take priority over subprocess codecs with the same name. Subprocess codecs are discovered automatically and listed by `c0 codecs`.

### Future Codecs

Interesting candidates for built-in or community codecs:

- **PDF** - Document structure, page objects, embedded fonts/images
- **JPEG XL** - Next-gen image format with rich metadata and progressive layers
- **Dead Cells** (save files) - Roguelike game save data editing
- **SQLite** - Database file format with tables, indexes, and pages
- **WASM** - WebAssembly module structure (sections, functions, imports)
- **Protocol Buffers** - Binary-encoded protobuf messages with schema-aware expansion

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

2. Content-aware C0 encoded:
{jumbf:{c2pa.manifest.nikon:{status:preserved˗from˗camera},c2pa.manifest.cloudflare:{claim_generator:Cloudflare Images,assertions:[{label:c2pa.actions,data:{actions:[{action:c2pa.resized,when:©¦SGż⁎8·,softwareAgent:Cloudflare Images,parameters:{originalDimensions:{width:8256,height:5504},newDimensions:{width:800,height:533}}}]}}],signature_info:{issuer:Cloudflare٫ Inc,time:©¦SGż⁎8·,cert_fingerprint:żŗĴȸvT2Ɣ},claim_metadata:{claim_id:cf_resize_123,parent_claim_id:nikon_z9_123}}}}

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
   C0 output:
   {png_header:ɃPNG⏎¶Ƶ¶·¯«»Hello·World,description:PNG file with null bytes embeddedǃ}

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
C0 encoded:
{header:[⌦ELF,«,¯···],payload:This is the payload data...}

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
{signature:ɃPNG⏎¶Ƶ¶,chunks:[{type:IHDR,data:··¯b···W⌫¡···,crc:˃ȡOǑ},{type:iCCP,data:ICC Profile··...

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
- All six C0 structural characters are escaped: `{→❴`, `}→❵`, `[→⟦`, `]→⟧`, `,→٫`, `:→꞉`
- Fully reversible - decode always recovers the original bytes

## Documentation

See `docs/plans/` for design documentation.

## License

MIT
