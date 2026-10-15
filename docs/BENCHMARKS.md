# Benchmarks and performance gates

C0 uses the shared `performance-profile` engine (flake input `performance-profiling`) to gate
encode/decode cost against an external, append-only measurement history. Run the commands
inside the dev shell:

| Command | What it checks |
| --- | --- |
| `./cg` | CPU time per doubling of input size, on 1 core and on 12 cores |
| `./mg` | Peak heap per doubling of input size, and zero residual heap after cleanup |
| `./bm` | CPU time of one fixed 16384-entry round trip, on 1 core and on 12 cores |

`./test` runs the adapter contract test, `./cg` and `./mg`. History defaults to
`file://$HOME/.local/state/performance-history`; set `PERFORMANCE_HISTORY_URL` to override it.
A first run on new hardware reports UNBASELINED until a reviewed observation is accepted with
`performance-profile accept --run ID --reason TEXT`. Never accept a regression to make a gate pass.

## Workload

`tests/benchmark/c0_bench.zig` generates a seeded object of N entries. Values rotate through a
random byte string, a three-element array of random strings, and a two-entry nested object. Every
sample encodes the tree, decodes it, compares the result with the generated source, and frees
everything. A mismatch fails the run, so a measurement cannot come from wrong or skipped work. The
engine supplies a 128-bit hex seed per run; the adapter hashes it to the generator's 64-bit seed.

## Domain limitation

The generator leaves out raw strings that smart encoding (SPECIFICATION.md §13) passes through
unencoded and decodes to different bytes. That is a known defect awaiting an owner decision; see
`docs/plan_context/smart_encoding_defect.md`. Measurements cover only the remaining domain and are
no claim that general round trips are correct.

## Declared shape bounds

The bounds classify complexity; the history comparison catches smaller regressions.

- CPU growth `[1.8, 2.25]` per doubling over 8192 to 65536 entries (about 10 to 80 ms per
  sample): linear work gives 2.0. An n log n algorithm at these sizes would drift toward the upper
  bound; quadratic work gives 4. The first definition started at 2048 entries (about 2.4 ms),
  which proved too short to time on a loaded shared host: the smallest size alone ran up to 40%
  slow and failed the shape check while the measured binary was byte-identical to a passing run.
- Peak heap `[1.5, 2.6]` per doubling: linear on average, but the encoder's output buffer grows in
  1.5x capacity steps and every run uses a fresh seed, so single doublings jitter around 2. The
  first observation measured 2.07, 2.07 and 1.86 (geometric mean 1.996). Quadratic growth gives 4.
- Residual heap must be exactly 0 after every sample.
