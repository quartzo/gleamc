#!/usr/bin/env bash
# Compare the same gleamc compiler in two execution substrates, compiling the
# same input and emitting identical LLVM IR:
#
#   native : src/selfhost, the compiler compiled by gleamc to a native binary
#   beam   : `gleam run`,  the compiler compiled by the official Gleam to Erlang
#
# `--cc=/bin/true` makes the compiler stop after emitting the `.ll`, so the
# measurement is the compiler itself (not clang/linking, which is identical on
# both sides but would add its own fixed cost).
#
# Usage: bench/compare.sh [hello mixloop compiler ...]
#   hello     small program
#   mixloop   tail-recursive 200M-iteration loop
#   compiler  the compiler's own source (src/selfhost.gleam); slow
#
# Env: N   runs per measurement (default 7; the `compiler` input always uses 1)
#
# Note: this is a *native vs BEAM substrate* comparison of the compiler. The
# runtimes of the programs they produce are a separate benchmark. For the
# `compiler` input the two `.ll` outputs are semantically identical but the
# order of `%__frame_*` type declarations differs (the compiler iterates a
# hash map when emitting them).
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
N="${N:-7}"
measure="bench/measure.py"

if [ ! -x src/selfhost ]; then
  echo "building the native compiler (src/selfhost)..." >&2
  gleam run -- src/selfhost.gleam --quiet >/dev/null 2>&1 \
    || { echo "failed to build src/selfhost" >&2; exit 1; }
fi
# `gleam run` needs the project built by the official toolchain.
gleam build >/dev/null 2>&1 || true

inputs=("$@")
[ ${#inputs[@]} -eq 0 ] && inputs=(hello mixloop)

source_of() {
  case "$1" in
    hello) echo "bench/hello.gleam" ;;
    mixloop) echo "bench/mixloop.gleam" ;;
    compiler) echo "src/selfhost.gleam" ;;
    *) echo "$1" ;;
  esac
}

row() { # name native_cmd... -- beam_cmd...
  local name="$1"; shift
  local n="$N"
  [ "$name" = "compiler" ] && n=1
  local native_cmd=("$@")
  local native_out
  native_out="$(python3 "$measure" -n "$n" "${native_cmd[@]}")" || exit 1
  local beam_out
  beam_out="$(python3 "$measure" -n "$n" gleam run -- "${native_cmd[@]:1}")" || exit 1
  printf '%-10s | %-26s | %s\n' "$name" "$native_out" "$beam_out"
}

echo "compiler substrate comparison (--cc=/bin/true, identical .ll), n=$N"
echo
printf '%-10s | %-26s | %s\n' "input" "native (src/selfhost)" "BEAM (gleam run)"
printf '%s\n' "-----------+----------------------------+---------------------------"

printf '%-10s | %-26s | %s\n' \
  "startup" \
  "$(python3 "$measure" -n "$N" ./src/selfhost --version)" \
  "$(python3 "$measure" -n "$N" gleam run -- --version)"

for input in "${inputs[@]}"; do
  src="$(source_of "$input")"
  row "$input" ./src/selfhost "$src" --cc=/bin/true --quiet
done
