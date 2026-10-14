# Smart-encoding round-trip defect

## Finding (2026-10-14)

SPECIFICATION.md §13 (smart encoding) passes a payload through unencoded when it is valid UTF-8,
has no structural or control bytes, and every glyph is in printable-binary's output set. The
decoder cannot tell such raw text from genuinely encoded text, so it decodes it to different
bytes. A lone section sign `§` decodes to 0x0C, `©` to 0x18 and `¶` to 0x0A. An exhaustive sweep
of all 1,920 two-byte UTF-8 sequences finds 162 corrupted; single bytes and whitespace are
unaffected. This contradicts §12's deterministic round-trip and binary-native guarantees.

Found by the benchmark adapter's round-trip work check (`tests/benchmark/c0_bench.zig`).

## Status

The BDFN (Benevolent Dictator For Now) has an open decision, id `c0-smart-encoding-roundtrip`
revision 1, with these options: lossless (pass through only payloads printable-binary would leave
unchanged; recommended), document-limit, explicit-marker, or defer.

## Constraints until the decision is answered

- The §13 behavior is a pending design choice, not a satisfied contract. Do not rewrite §12 or
  other accepted intent to match the defect.
- No migration or destructive data change.
- The defect stays mechanically visible. `src/core/roundtrip_test.zig` holds a known-defect ledger:
  an exhaustive two-byte sweep pinned to the observed defect set (count, cause and the narration
  examples). A fix or a regression changes the set and fails the ledger until it is updated
  deliberately alongside the decision.
- The benchmark measures only the unaffected subset. Its generator appends 0xFF to lookalike
  strings, its JSON `domain` field states the exclusion, and approved baselines make no general
  round-trip correctness claim.
