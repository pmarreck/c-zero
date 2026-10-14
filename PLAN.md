# PLAN

Completed items retire to `docs/PLAN_LOG.md`. Spec: `SPECIFICATION.md`.

## Now
- [x] Ignore Zig 0.16 local package cache `zig-pkg/` and commit relative reference-doc symlinks (done 2026-10-14 15:05 EDT)
- [x] Benchmark baseline: `./cg` `./mg` gate core encode/decode round trips through performance-profile, with approved anchors; domain excludes smart-encoding lookalikes (done 2026-10-14 17:45 EDT) (context: docs/BENCHMARKS.md)
- [ ] Review and approve `./bm` fixed-workload anchors (16384-entry round trip, 1c and 12c)

## Next
- [ ] Resolve smart-encoding data loss per owner decision c0-smart-encoding-roundtrip: raw glyph-only text (e.g. a lone `§`) decodes to different bytes, contradicting SPECIFICATION.md §12 (blocked: owner decision pending) (context: docs/plan_context/smart_encoding_defect.md)
- [ ] Migrate `PROJECT_OVERVIEW.md` into `INTENT.md` (gather-project-intentions skill)
- [ ] Streaming API: incremental parse/encode for large inputs; design the event/pull shape first
- [ ] Compare against `std.json` on a UTF-8-only fixture shared by both cases (JSON cannot carry raw binary)
- [ ] Extend benchmarks to MessagePack once a pinned Zig or C implementation is chosen

## Deferred
- [ ] Language bindings beyond the C FFI (e.g. Rust, LuaJIT); wait for a concrete consumer, no Python/Go

## Recently completed
- [x] JSON subset <-> C0 demo `examples/json_demo.zig` (done 2026-02-02, b731915)
- [x] Empty-string ambiguity accepted as a documented limitation, SPECIFICATION.md §8 (done 2026-02-10, 27d19cc)
- [x] C CLI (done 2026-02-02)
- [x] CLI bash tests (done 2026-02-02)
- [x] Documentation (done 2026-02-02)
