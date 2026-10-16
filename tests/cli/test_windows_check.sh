#!/usr/bin/env bash
# tests/windows/check picks the Windows plugin-host check: the Wine smoke test when wine is
# installed, otherwise tests/windows/remote-smoke against $C0_WINDOWS_HOST, otherwise it fails with
# a message naming both options. Classified over every combination of wine presence and host
# setting, using stand-in smoke scripts that report which one ran.
set -u
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
failures=0
passes=0
fail() { failures=$((failures+1)); printf 'FAIL: %s\n' "$*" >&2; }
expect_eq() { if [[ "${2-}" == "${3-}" ]]; then passes=$((passes+1)); else fail "$1: expected [${2-}], got [${3-}]"; fi; }
expect_contains() { if [[ "${2-}" == *"${3-}"* ]]; then passes=$((passes+1)); else fail "$1: [${2-}] lacks [${3-}]"; fi; }
scratch=$(mktemp -d "${TMPDIR:-/tmp}/c0-windows-check.XXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT

mkdir -p "$scratch/tree/tests/windows" "$scratch/withwine" "$scratch/nowine"
cp "$root/tests/windows/check" "$scratch/tree/tests/windows/check"
printf '#!/usr/bin/env bash\necho "ran wine smoke"\nexit "${STUB_RC:-0}"\n' >"$scratch/tree/tests/windows/smoke"
printf '#!/usr/bin/env bash\necho "ran remote smoke on $1"\nexit "${STUB_RC:-0}"\n' >"$scratch/tree/tests/windows/remote-smoke"
printf '#!/bin/sh\nexit 0\n' >"$scratch/withwine/wine"
chmod +x "$scratch/tree/tests/windows/"* "$scratch/withwine/wine"
bash_dir=$(dirname "$(command -v bash)")
check="$scratch/tree/tests/windows/check"

run() { # $1 path prefix, rest env assignments; sets cap_out, cap_err, rc
	local prefix=$1; shift
	env -u C0_WINDOWS_HOST "$@" PATH="$prefix:$bash_dir:/usr/bin:/bin" "$check" >"$scratch/out" 2>"$scratch/err"; rc=$?
	cap_out=$(<"$scratch/out"); cap_err=$(<"$scratch/err")
}

run "$scratch/withwine"
expect_eq "wine, no host: runs wine smoke" "ran wine smoke" "$cap_out"
expect_eq "wine, no host: exit" 0 "$rc"

run "$scratch/withwine" C0_WINDOWS_HOST=winbox
expect_eq "wine and host: wine first" "ran wine smoke" "$cap_out"

run "$scratch/nowine" C0_WINDOWS_HOST=winbox
expect_eq "no wine, host: falls back to real Windows" "ran remote smoke on winbox" "$cap_out"
expect_eq "no wine, host: exit" 0 "$rc"

run "$scratch/nowine"
expect_eq "neither: exit" 1 "$rc"
expect_eq "neither: no stdout" "" "$cap_out"
expect_contains "neither: names wine" "$cap_err" "NOT RUN"
expect_contains "neither: names the host variable" "$cap_err" "C0_WINDOWS_HOST"

run "$scratch/nowine" C0_WINDOWS_HOST=
expect_eq "empty host counts as unset" 1 "$rc"

run "$scratch/withwine" STUB_RC=1
expect_eq "wine smoke failure propagates" 1 "$rc"
run "$scratch/nowine" C0_WINDOWS_HOST=winbox STUB_RC=1
expect_eq "remote smoke failure propagates" 1 "$rc"

printf '=== Windows check selection: %d passed, %d failed ===\n' "$passes" "$failures"
exit $((failures > 0))
