# PLAN

Completed items retire to `docs/PLAN_LOG.md`. Spec: `SPECIFICATION.md`.

## Now
- [x] Ignore Zig 0.16 local package cache `zig-pkg/` and commit relative reference-doc symlinks (done 2026-10-14 15:05 EDT)
- [ ] Benchmark baseline: `./bm` measuring core encode/decode throughput against `std.json` on matched fixtures (performance-profiling skill)

## Next
- [ ] Migrate `PROJECT_OVERVIEW.md` into `INTENT.md` (gather-project-intentions skill)
- [ ] Streaming API: incremental parse/encode for large inputs; design the event/pull shape first
- [ ] Extend benchmarks to MessagePack once a pinned Zig or C implementation is chosen

## Deferred
- [ ] Language bindings beyond the C FFI (e.g. Rust, LuaJIT); wait for a concrete consumer, no Python/Go

## Recently completed
- [x] JSON subset <-> C0 demo `examples/json_demo.zig` (done 2026-02-02, b731915)
- [x] Empty-string ambiguity accepted as a documented limitation, SPECIFICATION.md §8 (done 2026-02-10, 27d19cc)
- [x] C CLI (done 2026-02-02)
- [x] CLI bash tests (done 2026-02-02)
- [x] Documentation (done 2026-02-02)
