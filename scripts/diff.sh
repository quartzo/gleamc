#!/usr/bin/env bash
# Differential harness: runs every diffs/*.gleam through both gleamc (this
# project) and the official Gleam toolchain, and compares stdout.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
for f in "$root"/diffs/*.gleam; do
  name="$(basename "$f" .gleam)"

  ours="$(cd "$root" && gleam run -- --quiet "$f" --run 2>/dev/null)"
  rm -f "$root/diffs/$name.c" "$root/diffs/$name"

  proj="$tmp/$name"
  mkdir -p "$proj/src"
  cat > "$proj/gleam.toml" <<EOF
name = "diff_$name"
version = "1.0.0"

[dependencies]
gleam_stdlib = ">= 1.0.0 and < 2.0.0"
EOF
  cp "$f" "$proj/src/diff.gleam"
  theirs="$(cd "$proj" && gleam run -m diff 2>/dev/null)"

  if [ "$ours" = "$theirs" ]; then
    echo "OK   $name"
  else
    echo "DIFF $name"
    echo "--- gleamc ---"
    echo "$ours"
    echo "--- gleam ---"
    echo "$theirs"
    fail=1
  fi
done

exit $fail
