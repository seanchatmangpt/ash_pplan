#!/usr/bin/env bash
# Runs every mirror-sim court as a real mix subprocess and writes receipts/mirror-sim-<sha>.md.
# test/support is compiled in MIX_ENV=test, so the Runner module is already loaded.
# Exit 1 unless the receipt Standing is ALIVE, PASS, or PARTIAL_ALIVE.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 2
export MIX_ENV=test
mix run --no-start \
  -e '{:ok, path, _} = AshPPlan.MirrorSim.Runner.run(root: File.cwd!()); IO.puts(path)' \
  9>&-
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "run_all: runner exit $rc" >&2
  exit "$rc"
fi
receipt="$(ls -t receipts/mirror-sim-*.md | head -1)"
standing="$(grep -m1 '^Standing:' "$receipt")"
echo "receipt: $receipt"
echo "$standing"
case "$standing" in
  "Standing: ALIVE" | "Standing: PASS" | "Standing: PARTIAL_ALIVE") exit 0 ;;
  *) exit 1 ;;
esac
