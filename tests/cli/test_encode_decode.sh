#!/usr/bin/env bash
# CLI tests for C0 encode/decode functionality

set -euo pipefail

# Find project root (directory containing build.zig)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
C0_BIN="$PROJECT_ROOT/zig-out/bin/c0"

# Track failures
failures=0

# Colors for output (if terminal supports it)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    NC=''
fi

# Test helper: compare expected vs actual output
# Usage: assert_eq "test name" "expected" "actual"
assert_eq() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}PASS${NC}: $name"
        return 0
    else
        echo -e "${RED}FAIL${NC}: $name"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        ((failures++)) || true
        return 1
    fi
}

# Test helper: check exit code
# Usage: assert_exit_code "test name" expected_code command [args...]
assert_exit_code() {
    local name="$1"
    local expected_code="$2"
    shift 2

    set +e
    "$@" >/dev/null 2>&1
    local actual_code=$?
    set -e

    if [[ "$expected_code" -eq "$actual_code" ]]; then
        echo -e "${GREEN}PASS${NC}: $name"
        return 0
    else
        echo -e "${RED}FAIL${NC}: $name"
        echo "  Expected exit code: $expected_code"
        echo "  Actual exit code:   $actual_code"
        ((failures++)) || true
        return 1
    fi
}

# Test helper: check exit code is non-zero
# Usage: assert_fails "test name" command [args...]
assert_fails() {
    local name="$1"
    shift

    set +e
    "$@" >/dev/null 2>&1
    local actual_code=$?
    set -e

    if [[ "$actual_code" -ne 0 ]]; then
        echo -e "${GREEN}PASS${NC}: $name"
        return 0
    else
        echo -e "${RED}FAIL${NC}: $name (expected non-zero exit code, got 0)"
        ((failures++)) || true
        return 1
    fi
}

echo "=== C0 CLI Tests ==="
echo "Using binary: $C0_BIN"

# Verify binary exists
if [[ ! -x "$C0_BIN" ]]; then
    echo "ERROR: c0 binary not found at $C0_BIN"
    exit 1
fi

# --- Test: Simple string encode/decode round-trip ---
echo ""
echo "--- Round-trip tests ---"

result=$(echo "hello" | "$C0_BIN" encode | "$C0_BIN" decode)
assert_eq "Simple string round-trip (echo 'hello')" '"hello"' "$result"

result=$(echo -n "hello" | "$C0_BIN" encode | "$C0_BIN" decode)
assert_eq "Simple string round-trip (echo -n 'hello')" '"hello"' "$result"

result=$(echo "Hello, World!" | "$C0_BIN" encode | "$C0_BIN" decode)
assert_eq "String with punctuation round-trip" '"Hello, World!"' "$result"

# --- Test: Empty string round-trip ---
echo ""
echo "--- Empty input tests ---"

# Empty input to encode produces empty output
empty_encoded=$(printf '' | "$C0_BIN" encode)
assert_eq "Empty input encodes to empty output" "" "$empty_encoded"

# Empty input to decode should fail
assert_fails "Decode empty input fails" bash -c "printf '' | '$C0_BIN' decode"

# --- Test: Help flag ---
echo ""
echo "--- Help and error handling tests ---"

assert_exit_code "Help flag (-h) exits with 0" 0 "$C0_BIN" -h
assert_exit_code "Help flag (--help) exits with 0" 0 "$C0_BIN" --help

# --- Test: Unknown command fails ---
assert_fails "Unknown command fails" "$C0_BIN" unknowncommand
assert_fails "No arguments shows help and fails" "$C0_BIN"

# --- Summary ---
echo ""
echo "=== CLI Tests Complete ==="
if [[ $failures -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
else
    echo -e "${RED}$failures test(s) failed${NC}"
fi

exit $failures
