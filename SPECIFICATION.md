# C0
## A Hierarchical Binary Data Stream Designed for Human-Readable UTF-8 Environments
## Canonical Specification (v1)

⸻

## 1. Overview

This specification defines a byte-oriented, streaming-friendly serialization format for structured data equivalent to a strict subset of JSON.

Supported value types:

- String
- Array (ordered list of values)
- Object (mapping from string keys to values)

All values may be nested arbitrarily.

The format uses four ASCII C0 control characters as structural tokens and a disjoint printable-binary encoding (see sibling project ../printable-binary for details) for all payload data. Payload bytes are guaranteed never to conflict with structural bytes.

⸻

## 2. Structural Bytes

The following ASCII control bytes are reserved and have structural meaning:

- FS (File Separator): 0x1C — begins an object
- GS (Group Separator): 0x1D — begins an array
- RS (Record Separator): 0x1E — terminates an object entry
- US (Unit Separator): 0x1F — terminates an array element and separates object key/value

These four bytes are referred to collectively as structural bytes.

## 3. Payload Encoding Invariant

**Invariant (Critical):**

The payload encoding MUST NOT emit bytes 0x1C, 0x1D, 0x1E, or 0x1F under any circumstances.

All string data (including object keys and string values) MUST be encoded using a reversible printable-binary encoding whose output alphabet excludes these bytes.

Because UTF-8 is byte-oriented, structural bytes can never appear implicitly inside multibyte sequences. If a structural byte appears in the input stream, it is unambiguously structural.

⸻

## 4. Data Model

A Value is one of:

- String
- Array of Values
- Object mapping Strings to Values

The top-level document is exactly one Value.

⸻

## 5. Grammar (Informal but Complete)

This grammar is defined operationally, not via regex or ABNF, to avoid ambiguity.

5.1 Strings

A String is a sequence of payload bytes decoded from printable-binary encoding.

String boundaries are determined entirely by surrounding structural context.

Empty strings are allowed.

⸻

5.2 Objects

An Object begins with FS (0x1C) and ends implicitly after its final RS.

Object rules:

- Each object entry consists of:
Key US Value RS

- US separates the key from the value.
- RS terminates the entry.

**Mandatory trailing rule:**

Every object MUST end with an RS, including the final entry.

**Empty object encoding:**

FS RS

5.3 Arrays

An Array begins with GS (0x1D) and ends implicitly after its final US.

Array rules:

- Each array element consists of:
Value US

- US terminates the element.

**Mandatory trailing rule:**

Every array MUST end with a US, including the final element.

**Empty array encoding:**

GS US

## 6. Parsing Algorithm (Normative)

Parsing is performed in a single left-to-right pass using a stack.

Each stack frame is either:

- Object context
- Array context

6.1 General Rules

- Structural bytes are never payload.
- Payload bytes are never structural.
- Parsing decisions are made solely from the current context and the next structural byte.

⸻

6.2 Parsing Objects

When FS is encountered:
	1.	Push an Object context.
	2.	Expect either:
- a key (payload string), or
- RS (empty object).

While in Object context:

- Read key (payload string).
- Expect US.
- Parse Value.
- Expect RS.

After consuming an RS:

- If the next byte can begin a key (payload byte), continue object.
- Otherwise, the object has ended; pop the Object context.

⸻

6.3 Parsing Arrays

When GS is encountered:
	1.	Push an Array context.
	2.	Expect either:
- a Value, or
- US (empty array).

While in Array context:

- Parse Value.
- Expect US.

After consuming a US:

- If the next byte can begin a Value, continue array.
- Otherwise, the array has ended; pop the Array context.

⸻

6.4 Value Parsing

A Value is parsed as follows:

- If the next byte is FS, parse Object.
- Else if the next byte is GS, parse Array.
- Else parse String until a structural byte valid in the current context is encountered.

## 7. Termination and Disambiguation

Because:

- Objects MUST end with RS, and
- Arrays MUST end with US, and
- Payload bytes can never equal structural bytes,

container termination is unambiguous.

Consecutive structural bytes indicate successive container closures. Each structural byte is consumed by the innermost compatible context; otherwise, it signals that context has ended.

⸻

## 8. JSON Mapping

8.1 JSON → This Format

- JSON string → printable-binary encoded string
- JSON array → GS + (value US)* + US
- JSON object → FS + (key US value RS)* + RS

JSON numbers, booleans, and null are out of scope for this version.

⸻

8.2 This Format → JSON

- String → JSON string
- Array → JSON array
- Object → JSON object

Key order MAY be preserved but MUST NOT be relied upon.

⸻

## 9. Error Conditions (MUST Reject)

An implementation MUST reject:

- Structural bytes appearing in payload decoding
- Object entry missing US or RS
- Array element missing US
- Unterminated object or array
- Structural byte illegal in current context
- Trailing payload after full document parse

⸻

## 10. Reserved Bytes

The following bytes are reserved and MUST NOT appear in payload:

- 0x1C FS
- 0x1D GS
- 0x1E RS
- 0x1F US

Optional future reservation:

- 0x1B ESC (currently unused)

⸻

## 11. Design Guarantees

This format guarantees:

- No escaping logic
- No length prefixes
- No explicit closing tags
- Unambiguous nesting
- Streaming-safe parsing
- UTF-8 compatibility
- Deterministic round-tripping with JSON subset

⸻

## 12. End of Specification

We will build this in Zig and control dependencies with a combination of Zig packages and Nix. We will use TDD for all new features, and build things step by step.
