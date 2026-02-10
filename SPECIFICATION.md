# C0 (JSON-PB)
## A Hierarchical Data Format: JSON Without Quotes, With Printable-Binary Encoding
## Canonical Specification (v2)

---

## 1. Overview

C0 is a byte-oriented serialization format for structured data equivalent to a strict subset of JSON. It looks like JSON with the quotes removed and printable-binary encoding replacing escape sequences.

Supported value types:

- **String** (arbitrary bytes, including binary)
- **Array** (ordered list of values)
- **Object** (ordered mapping from string keys to values)

All values may be nested arbitrarily.

The format uses six printable ASCII characters as structural delimiters. All payload data is encoded using printable-binary (see sibling project `../printable-binary`), which escapes exactly these six characters. This guarantees zero ambiguity between structure and content.

### Example

JSON:
```json
{"name":"Tav","level":5,"items":["sword","shield"]}
```

C0:
```
{name:Tav,level:5,items:[sword,shield]}
```

With binary or special data, printable-binary encoding kicks in:
```json
{"key:with:colons":"value{with}braces"}
```

C0:
```
{key꞉with꞉colons:value❴with❵braces}
```

The visually similar Unicode replacements (`꞉` for `:`, `❴❵` for `{}`, etc.) are produced by printable-binary encoding and are unambiguously not structural.

---

## 2. Structural Bytes

Six printable ASCII characters are reserved as structural delimiters:

| Byte | Character | Name | Purpose |
|------|-----------|------|---------|
| 0x7B | `{` | OBJECT_OPEN | Begins an object |
| 0x7D | `}` | OBJECT_CLOSE | Ends an object |
| 0x5B | `[` | ARRAY_OPEN | Begins an array |
| 0x5D | `]` | ARRAY_CLOSE | Ends an array |
| 0x2C | `,` | COMMA | Separates entries/elements |
| 0x3A | `:` | COLON | Separates key from value |

These six bytes are referred to collectively as **structural bytes**.

---

## 3. Payload Encoding Invariant

**Invariant (Critical):**

The payload encoding MUST NOT emit any of the six structural bytes (`{`, `}`, `[`, `]`, `,`, `:`) under any circumstances.

All string data (including object keys and string values) MUST be encoded using printable-binary encoding, whose output alphabet excludes these bytes via the following substitutions:

| Structural | Replacement | Unicode Name |
|------------|-------------|--------------|
| `{` | `❴` (U+2774) | MEDIUM LEFT CURLY BRACKET ORNAMENT |
| `}` | `❵` (U+2775) | MEDIUM RIGHT CURLY BRACKET ORNAMENT |
| `[` | `⟦` (U+27E6) | MATHEMATICAL LEFT WHITE SQUARE BRACKET |
| `]` | `⟧` (U+27E7) | MATHEMATICAL RIGHT WHITE SQUARE BRACKET |
| `,` | `٫` (U+066B) | ARABIC DECIMAL SEPARATOR |
| `:` | `꞉` (U+A789) | MODIFIER LETTER COLON |

Because these replacements are multi-byte UTF-8 sequences and structural bytes are single ASCII bytes, a structural byte in the stream is always unambiguously structural.

---

## 4. Whitespace

**Spaces** (0x20) are significant content and are never stripped.

**Tabs** (0x09), **newlines** (0x0A), and **carriage returns** (0x0D) are **insignificant whitespace** — they are stripped during parsing and carry no semantic meaning.

This enables pretty-printed output that round-trips identically to compact output:

Compact:
```
{name:Tav,items:[sword,shield]}
```

Pretty-printed (round-trips to the same Value):
```
{
	name:Tav,
	items:[
		sword,
		shield
	]
}
```

---

## 5. Data Model

A **Value** is one of:

- **String** — arbitrary byte sequence (encoded via printable-binary)
- **Array** — ordered sequence of Values
- **Object** — ordered sequence of (key, value) entries where keys are Strings

The top-level document is exactly one Value.

---

## 6. Grammar

### 6.1 Strings

A String is a (possibly empty) run of bytes that are neither structural bytes nor insignificant whitespace. The bytes are decoded from printable-binary encoding to recover the original data.

String boundaries are determined by surrounding structural context — strings end when a structural byte or end-of-input is reached.

### 6.2 Arrays

```
Array = '[' ']'                          (empty)
      | '[' Value (',' Value)* ']'       (non-empty)
```

- `[` opens the array.
- `]` closes the array.
- Elements are separated by `,`.
- Insignificant whitespace may appear between any tokens.

### 6.3 Objects

```
Object = '{' '}'                                      (empty)
       | '{' Key ':' Value (',' Key ':' Value)* '}'   (non-empty)
```

- `{` opens the object.
- `}` closes the object.
- Each entry is `Key : Value`.
- Entries are separated by `,`.
- Key is a String (parsed until `:` is reached).
- Insignificant whitespace may appear between any tokens.

### 6.4 Value

```
Value = Object | Array | String
```

Dispatch: if the next non-whitespace byte is `{`, parse Object. If `[`, parse Array. Otherwise, parse String.

---

## 7. Parsing Algorithm

Parsing is performed in a single left-to-right pass. At each step, insignificant whitespace is skipped, then:

1. **At top level**: Parse one Value. Skip trailing whitespace. Reject if input remains.

2. **Value dispatch**: Peek at next byte.
   - `{` → parse Object
   - `[` → parse Array
   - Otherwise → parse String (until structural byte or end)

3. **Array parsing**: Consume `[`. Skip ws. If `]`, done. Else loop: parse Value, skip ws, expect `]` (done) or `,` (continue). Any other byte is an error.

4. **Object parsing**: Consume `{`. Skip ws. If `}`, done. Else loop: parse String (key), skip ws, expect `:`, parse Value, skip ws, expect `}` (done) or `,` (continue). Any other byte is an error.

---

## 8. Empty String Ambiguity

An empty string between two structural delimiters is indistinguishable from "no value." This creates exactly one known ambiguity:

- `[""]` (array containing one empty string) encodes as `[]` — identical to an empty array.

Arrays with **two or more** empty strings round-trip correctly:
- `["",""]` → `[,]` (the comma proves two elements exist)
- `["","",""]` → `[,,]`

Object entries with empty keys or values also work:
- `{"":""}` → `{:}` (one entry: empty key, empty value)

This single-empty-string ambiguity is a known, accepted limitation.

---

## 9. JSON Mapping

### 9.1 JSON to C0

- JSON string → printable-binary encoded string (quotes removed)
- JSON array → `[` + values separated by `,` + `]`
- JSON object → `{` + key `:` value entries separated by `,` + `}`

JSON numbers, booleans, and null are encoded as their string representations. C0 does not distinguish types at the format level — type information is the concern of higher-level schemas.

### 9.2 C0 to JSON

- String → JSON string (with standard JSON escaping)
- Array → JSON array
- Object → JSON object

Key order is preserved.

---

## 10. Error Conditions

An implementation MUST reject:

- Unexpected end of input inside an array or object
- Missing closing delimiter (`]` or `}`)
- Unexpected byte where `,`, `]`, or `}` was expected
- Trailing non-whitespace data after the top-level value

---

## 11. Comparison with JSON

| Property | JSON | C0 |
|----------|------|----|
| String delimiters | `"..."` with `\` escapes | None — printable-binary encoding |
| Binary data | Requires base64 | Native (printable-binary) |
| Structural chars | `{ } [ ] , :` | Same six characters |
| Whitespace | Insignificant | Spaces significant; tabs/newlines insignificant |
| Human-readable | Yes | Yes (more compact) |
| Streaming | Needs lookahead | Single-pass, left-to-right |

---

## 12. Design Guarantees

This format guarantees:

- **No escaping logic** — printable-binary handles all encoding
- **No length prefixes** — boundaries are delimiter-based
- **Explicit closing delimiters** — `]` and `}` close containers
- **Unambiguous nesting** — structural bytes cannot appear in payloads
- **Insignificant whitespace** — tabs/newlines enable pretty-printing without affecting data
- **Streaming-safe parsing** — single left-to-right pass
- **UTF-8 compatible** — all output is valid UTF-8
- **Deterministic round-tripping** — with JSON subset (modulo the single-empty-string ambiguity)
- **Binary-native** — arbitrary byte payloads without base64

---

## 13. Smart Encoding

Implementations SHOULD use smart encoding: only apply printable-binary encoding to payloads that actually need it (contain structural bytes, control characters, or invalid UTF-8). Data that is already safe passes through unchanged. Data that is already printable-binary encoded is not double-encoded.

---

## 14. End of Specification
