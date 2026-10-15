#!/usr/bin/env bash
# Codec plugin host tests (protocol c0-codec/1, docs/plan_context/codec_plugins.md).
# Fake plugins written in Bash exercise the c0 host independently of the Zig plugins;
# the real plugins are then checked for protocol conformance and round trips.
set -u

root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
c0="$root/zig-out/bin/c0"
bin="$root/zig-out/bin"
failures=0
passes=0
pass() { passes=$((passes+1)); }
fail() { failures=$((failures+1)); printf 'FAIL: %s\n' "$*" >&2; }
expect_eq() { if [[ "${2-}" == "${3-}" ]]; then pass; else fail "$1: expected [${2-}], got [${3-}]"; fi; }
expect_contains() { if [[ "${2-}" == *"${3-}"* ]]; then pass; else fail "$1: [${2-}] lacks [${3-}]"; fi; }
expect_not_contains() { if [[ "${2-}" != *"${3-}"* ]]; then pass; else fail "$1: [${2-}] unexpectedly contains [${3-}]"; fi; }
scratch=$(mktemp -d "${TMPDIR:-/tmp}/c0-codec-test.XXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT
capture() { # sets cap_out, cap_err, rc (names chosen to avoid stdenv exports such as $out); stdin is inherited
	"$@" >"$scratch/out" 2>"$scratch/err"; rc=$?
	cap_out=$(<"$scratch/out"); cap_err=$(<"$scratch/err")
}

# A fake plugin. $1 dir, $2 codec name, $3 info override (optional), $4 expand body (optional).
make_fake() {
	local dir=$1 name=$2 info=${3:-} body=${4:-}
	mkdir -p "$dir"
	[[ -n $info ]] || info="{protocol:c0-codec/1,name:$name,description:Fake codec $name in $dir,extensions:[.fk],magic:[{offset:1,hex:464b}],format_names:[$name,$name-old],faithful:true,editable:true,help:Fake help,args:[{name:tag,value_name:TEXT,description:A tag}]}"
	[[ -n $body ]] || body='printf "{format:%s,args:%s,size:%s}" "$NAME" "$*" "$(wc -c | tr -d " ")"'
	cat >"$dir/c0-codec-$name" <<-EOF
	#!/usr/bin/env bash
	NAME=$name
	printf '%s\n' "\$*" >>"$scratch/calls-$name"
	cmd=\$1; shift
	case \$cmd in
	info) printf '%s' '$info' ;;
	expand) $body ;;
	collapse) cat >/dev/null; printf 'native:%s' "\$*" ;;
	*) exit 2 ;;
	esac
	EOF
	chmod +x "$dir/c0-codec-$name"
}

export C0_CODEC_PATH="$scratch/a"
make_fake "$scratch/a" fake

# --- discovery -------------------------------------------------------------
capture "$c0" codecs
expect_eq "codecs exit" 0 "$rc"
expect_contains "codecs lists fake" "$cap_out" "fake"
expect_contains "codecs shows description" "$cap_out" "Fake codec fake in $scratch/a"
expect_contains "codecs shows modes" "$cap_out" "[faithful, editable]"

C0_CODEC_PATH="$scratch/empty" capture "$c0" codecs
expect_contains "no plugins listed as none" "$cap_out" "(none)"

make_fake "$scratch/b" fake
make_fake "$scratch/b" other
C0_CODEC_PATH="$scratch/a:$scratch/b" capture "$c0" codecs
expect_contains "first directory wins" "$cap_out" "Fake codec fake in $scratch/a"
expect_not_contains "shadowed plugin hidden" "$cap_out" "Fake codec fake in $scratch/b"
expect_contains "second directory still searched" "$cap_out" "Fake codec other in $scratch/b"

mkdir -p "$scratch/c"
printf '#!/bin/sh\n' >"$scratch/c/c0-codec-noexec"
cp "$scratch/a/c0-codec-fake" "$scratch/c/c0-codec-bad.name"
C0_CODEC_PATH="$scratch/c" capture "$c0" codecs
expect_not_contains "non-executable skipped" "$cap_out" "noexec"
expect_not_contains "invalid name skipped" "$cap_out" "bad.name"

capture "$c0" codecs fake
expect_eq "codec help exit" 0 "$rc"
expect_contains "codec help option" "$cap_out" "--tag TEXT"
expect_contains "codec help text" "$cap_out" "Fake help"
capture "$c0" codecs nosuch
expect_eq "unknown codec help exit" 1 "$rc"
expect_contains "unknown codec help message" "$cap_err" "Unknown codec 'nosuch'"

# --- expand ---------------------------------------------------------------
printf 'xFKdata' >"$scratch/magic.bin"
: >"$scratch/calls-fake"
capture "$c0" expand --codec fake --editable --compact --tag one --tag two "$scratch/magic.bin"
expect_eq "expand exit" 0 "$rc"
expect_eq "expand passes plugin output through" "{format:fake,args:--editable --compact --tag two,size:7}" "$cap_out"
expect_eq "expand argv (later --tag overrides)" "expand --editable --compact --tag two" "$(tail -n1 "$scratch/calls-fake")"

capture "$c0" expand "$scratch/magic.bin"
expect_eq "detect by magic exit" 0 "$rc"
expect_contains "detect by magic" "$cap_out" "format:fake"

printf 'plain' >"$scratch/data.FK"
capture "$c0" expand "$scratch/data.FK"
expect_contains "detect by extension, case-insensitive" "$cap_out" "format:fake"

printf 'plain' >"$scratch/data.unknown"
capture "$c0" expand "$scratch/data.unknown"
expect_eq "undetectable exit" 1 "$rc"
expect_contains "undetectable message" "$cap_err" "No codec found"

: >"$scratch/calls-fake"
capture "$c0" expand --codec fake --bogus 1 "$scratch/magic.bin"
expect_eq "undeclared option exit" 1 "$rc"
expect_contains "undeclared option message" "$cap_err" "codec 'fake' has no option --bogus"
# Validation needs the declared args from `info`, but expand itself must never start.
expect_not_contains "undeclared option never spawns expand" "$(<"$scratch/calls-fake")" "expand"

capture "$c0" expand --codec nosuch "$scratch/magic.bin"
expect_eq "missing codec exit" 1 "$rc"
expect_contains "missing codec message" "$cap_err" "codec 'nosuch' not found"

capture "$c0" expand --codec fake - <"$scratch/magic.bin"
expect_eq "expand from stdin (-)" "{format:fake,args:,size:7}" "$cap_out"
capture "$c0" expand --codec fake @stdin <"$scratch/magic.bin"
expect_eq "expand from stdin (@stdin)" "{format:fake,args:,size:7}" "$cap_out"

cp "$scratch/magic.bin" "$scratch/with space.bin"
capture "$c0" expand --codec fake "$scratch/with space.bin"
expect_eq "path with spaces" "{format:fake,args:,size:7}" "$cap_out"

# --- collapse ---------------------------------------------------------------
printf '{format:fake-old,x:1}' >"$scratch/doc.c0"
capture "$c0" collapse --tag t "$scratch/doc.c0"
expect_eq "collapse by format_names" "native:--tag t" "$cap_out"
capture "$c0" collapse --editable - <"$scratch/doc.c0"
expect_eq "collapse from stdin with --editable" "native:--editable" "$cap_out"
printf '{format:other,x:1}' >"$scratch/doc2.c0"
C0_CODEC_PATH="$scratch/a:$scratch/b" capture "$c0" collapse "$scratch/doc2.c0"
expect_eq "collapse by codec name" "native:" "$cap_out"
printf '{format:zzz}' >"$scratch/doc3.c0"
capture "$c0" collapse "$scratch/doc3.c0"
expect_eq "unknown format exit" 1 "$rc"
expect_contains "unknown format message" "$cap_err" "No codec handles format 'zzz'"
printf '{x:1}' >"$scratch/doc4.c0"
capture "$c0" collapse "$scratch/doc4.c0"
expect_eq "missing format exit" 1 "$rc"
expect_contains "missing format message" "$cap_err" "no top-level 'format' field"

# --- plugin failures and broken metadata -------------------------------------
make_fake "$scratch/d" failing "" 'echo "failing: bad input" >&2; exit 3'
C0_CODEC_PATH="$scratch/d" capture "$c0" expand --codec failing "$scratch/magic.bin"
expect_eq "plugin failure exit" 1 "$rc"
expect_contains "plugin stderr passes through" "$cap_err" "failing: bad input"
expect_contains "plugin failure summary" "$cap_err" "codec 'failing' failed (exit 3)"
expect_eq "plugin failure stdout empty" "" "$cap_out"

make_fake "$scratch/e" oldproto '{protocol:c0-codec/0,name:oldproto}'
make_fake "$scratch/e" misnamed '{protocol:c0-codec/1,name:someoneelse,faithful:true,editable:true}'
make_fake "$scratch/e" garbage 'not c0 at all {'
C0_CODEC_PATH="$scratch/e" capture "$c0" codecs
expect_contains "wrong protocol listed unavailable" "$cap_out" "unsupported protocol 'c0-codec/0'"
expect_contains "name mismatch listed unavailable" "$cap_out" "does not match its executable name"
expect_contains "garbage info listed unavailable" "$cap_out" "did not print a C0 object"
C0_CODEC_PATH="$scratch/e" capture "$c0" expand --codec oldproto "$scratch/magic.bin"
expect_eq "unusable codec exit" 1 "$rc"
expect_contains "unusable codec message" "$cap_err" "codec 'oldproto' is unusable"

# --- streaming: plugin writes while c0 is still writing its input ------------
make_fake "$scratch/f" cat "" 'cat'
head -c 8388608 /dev/zero | tr '\0' 'z' >"$scratch/big.bin"
C0_CODEC_PATH="$scratch/f" capture "$c0" expand --codec cat "$scratch/big.bin"
expect_eq "8 MiB streams through without deadlock" "8388608" "$(wc -c <"$scratch/out" | tr -d ' ')"
expect_eq "streamed bytes intact" "$(cksum <"$scratch/big.bin")" "$(cksum <"$scratch/out")"

# --- bundled plugins beside the c0 executable --------------------------------
mkdir -p "$scratch/bundle"
cp "$c0" "$scratch/bundle/c0"
make_fake "$scratch/bundle" bundled
(unset C0_CODEC_PATH; HOME="$scratch/nohome" PATH="/usr/bin:/bin" capture "$scratch/bundle/c0" codecs; printf '%s' "$cap_out" >"$scratch/bundle.out")
expect_contains "bundled directory searched" "$(<"$scratch/bundle.out")" "bundled"

# --- real plugins -------------------------------------------------------------
export C0_CODEC_PATH="$bin"
capture "$c0" codecs
for codec in png bg3 json jpeg tiff pdf; do
	expect_contains "real plugin $codec listed" "$cap_out" "  $codec"
	info=$("$bin/c0-codec-$codec" info)
	expect_eq "c0-codec-$codec info protocol" "c0-codec/1" "$(printf '%s' "$info" | "$c0" get .protocol)"
	expect_eq "c0-codec-$codec info name" "$codec" "$(printf '%s' "$info" | "$c0" get .name)"
	expect_contains "c0-codec-$codec --about" "$("$bin/c0-codec-$codec" --about)" "c0-codec-$codec: C0 codec plugin (c0-codec/1)"
done
expect_not_contains "no unavailable real plugins" "$cap_out" "unavailable"

capture "$c0" codecs pdf
expect_contains "pdf declares --pages" "$cap_out" "--pages RANGE"

# Smallest valid PNG: 1x1 grayscale, one zlib-compressed scanline.
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x00\x00\x00\x00\x3a\x7e\x9b\x55\x00\x00\x00\x0aIDATx\x9cc\x60\x00\x00\x00\x02\x00\x01\x48\xaf\xa4\x71\x00\x00\x00\x00IEND\xaeB`\x82' >"$scratch/one.png"
capture "$c0" expand "$scratch/one.png"
expect_eq "png expand exit" 0 "$rc"
expect_contains "png expand detected by magic" "$cap_out" "format"
"$c0" expand "$scratch/one.png" | "$c0" collapse >"$scratch/one.out.png"
expect_eq "png faithful round trip" "$(cksum <"$scratch/one.png")" "$(cksum <"$scratch/one.out.png")"
"$c0" expand --editable "$scratch/one.png" | "$c0" collapse --editable >"$scratch/one.ed.png"
expect_eq "png editable round trip" "$(cksum <"$scratch/one.png")" "$(cksum <"$scratch/one.ed.png")"

# bg3 and json round trips are semantic: collapse is not byte-exact for these codecs (bg3
# recompresses; json pretty-prints), matching the behavior of the former built-in codecs.
bg3="$root/tests/fixtures/bg3_save.lsv"
"$c0" expand "$bg3" >"$scratch/bg3.c0"
"$c0" collapse "$scratch/bg3.c0" | "$c0" expand --codec bg3 - >"$scratch/bg3.re.c0"
expect_eq "bg3 fixture semantic round trip" "$(cksum <"$scratch/bg3.c0")" "$(cksum <"$scratch/bg3.re.c0")"

printf '{"a":[1,"two",null,true]}' >"$scratch/doc.json"
capture "$c0" expand "$scratch/doc.json"
expect_eq "json expand exit" 0 "$rc"
"$c0" expand "$scratch/doc.json" >"$scratch/doc.c0"
"$c0" collapse "$scratch/doc.c0" | "$c0" expand --codec json - >"$scratch/doc.re.c0"
expect_eq "json semantic round trip" "$(cksum <"$scratch/doc.c0")" "$(cksum <"$scratch/doc.re.c0")"

printf '{"a":' >"$scratch/bad.json"
capture "$c0" expand "$scratch/bad.json"
expect_eq "real plugin failure exit" 1 "$rc"
expect_eq "real plugin failure stdout" "" "$cap_out"
expect_contains "real plugin failure message" "$cap_err" "c0-codec-json: json: expand failed: InvalidFormat"
expect_contains "real plugin failure summary" "$cap_err" "codec 'json' failed (exit 1)"

printf '=== Codec plugin tests: %d passed, %d failed ===\n' "$passes" "$failures"
exit $((failures > 0))
