# PLAN

Completed items retire to `docs/PLAN_LOG.md`. Spec: `SPECIFICATION.md`.

## Now
- [x] Ignore Zig 0.16 local package cache `zig-pkg/` and commit relative reference-doc symlinks (done 2026-10-14 15:05 EDT)
- [x] Benchmark baseline: `./cg` `./mg` gate core encode/decode round trips through performance-profile, with approved anchors; domain excludes smart-encoding lookalikes (done 2026-10-14 17:45 EDT) (context: docs/BENCHMARKS.md)
- [ ] Review and approve `./bm` fixed-workload anchors (16384-entry round trip, 1c and 12c)

## Next
- [ ] Codec plugins: move every codec out of libc0 into `c0-codec-<name>` executables over protocol c0-codec/1 (context: docs/plan_context/codec_plugins.md)
	- [x] Move codecs to `codecs/` with vendored C under `codecs/vendor/` (done 2026-10-15 14:00 EDT, 54d1ffd)
	- [x] Plugin ABI, info serialization and C plugin host; build six plugin executables with conformance tests (done 2026-10-15 14:50 EDT)
	- [x] CLI host: cross-platform discovery (C0_CODEC_PATH, bundled dir, ~/.c0/codecs, PATH), info parsing, detection, deadlock-free spawning (done 2026-10-15 14:50 EDT)
	- [x] Remove codec exports and C dependencies from libc0 and the FFI (done 2026-10-15 14:50 EDT)
	- [x] Windows: plugin discovery and CreateProcess spawning; cross-compiles for five targets; Wine smoke test in ./test (done 2026-10-15 14:50 EDT)
	- [x] Real Windows 10 22H2 run of the plugin host over SSH: 16 checks pass (tests/windows/remote-smoke) (done 2026-10-15 18:45 EDT)
	- [ ] Decide whether ./test should fail or pass with a notice on hosts without Wine (aarch64 macOS has no Nix Wine) (blocked: owner decision)
	- [x] Verify the Nix package installs the plugin executables beside c0; sandboxed test check passes (done 2026-10-15 15:05 EDT)
- [ ] Resolve smart-encoding data loss per owner decision c0-smart-encoding-roundtrip: raw glyph-only text (e.g. a lone `§`) decodes to different bytes, contradicting SPECIFICATION.md §12 (blocked: owner decision pending) (context: docs/plan_context/smart_encoding_defect.md)
- [ ] bg3 "faithful" collapse is not byte-exact: the 17,019,462-byte fixture collapses to 9,135,255 bytes that re-expand identically (pre-existing; recompression)
- [ ] png expand silently drops bytes after the signature when no valid chunk follows (`\x89PNG\r\n\x1a\ntruncated` expands to zero chunks; pre-existing)
- [ ] Migrate `PROJECT_OVERVIEW.md` into `INTENT.md` (gather-project-intentions skill)
- [ ] Streaming API: incremental parse/encode for large inputs; design the event/pull shape first
- [ ] Compare against `std.json` on a UTF-8-only fixture shared by both cases (JSON cannot carry raw binary)
- [ ] Extend benchmarks to MessagePack once a pinned Zig or C implementation is chosen

## Deferred
- [ ] Language bindings beyond the C FFI (e.g. Rust, LuaJIT); wait for a concrete consumer, no Python/Go

## Recently completed
- [x] Empty-string ambiguity accepted as a documented limitation, SPECIFICATION.md §8 (done 2026-02-10, 27d19cc)
