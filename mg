#!/usr/bin/env bash
# ./mg: memory gates: per-doubling peak heap ratios of the round trip, with zero residual heap after cleanup,
# checked by performance-profile against this project's external history. Cases are in
# profiling.json; the adapter is tests/benchmark/c0_bench.zig. Extra arguments go to
# performance-profile (for example --case NAME). Run inside the dev shell: nix develop -c ./mg
# History goes to $PERFORMANCE_HISTORY_URL (default file://$HOME/.local/state/performance-history).
exec "$(dirname "${BASH_SOURCE[0]}")/tests/benchmark/engine" run --mode mg "$@"
