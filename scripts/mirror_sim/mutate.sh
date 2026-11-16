#!/bin/sh
# Mirror-sim mutation helper (shim-court protocol support).
#   mutate.sh court <test_path>   run a repo court against the SCRATCH lib
#                                 (cwd = scratch root, env MIRROR_REPO_ROOT)
#   mutate.sh selfcheck           prove sha256 restore detection is not vacuous
# Never touches the real lib/: the scratch root owns its own lib/ and _build.
set -eu

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

case "${1:-}" in
  court)
    TEST="${2:?test path required}"
    : "${MIRROR_REPO_ROOT:?MIRROR_REPO_ROOT required}"
    # Link every top-level repo entry except lib/ (the scratch owns lib/) and build/scratch dirs.
    for path in "$MIRROR_REPO_ROOT"/* "$MIRROR_REPO_ROOT"/.formatter.exs; do
      f="$(basename "$path")"
      case "$f" in
        lib|_build*|tmp*|erl_crash.dump|*.tar|checkpoints|receipts|bench|doc) continue ;;
      esac
      if [ -e "$path" ] && [ ! -e "$f" ]; then ln -s "$path" "$f"; fi
    done
    # Path dep ../pm4exunit resolves relative to the scratch root's parent.
    PM4="$(dirname "$PWD")/pm4exunit"
    if [ ! -e "$PM4" ] && [ -d "$MIRROR_REPO_ROOT/../pm4exunit" ]; then
      ln -s "$MIRROR_REPO_ROOT/../pm4exunit" "$PM4"
    fi
    # Seed compiled deps (APFS clones) so only ash_pplan recompiles against the shim.
    SEED="${MIRROR_SEED_BUILD:-$MIRROR_REPO_ROOT/_build-mirror/test/lib}"
    if [ -d "$SEED" ] && [ ! -d _build/test/lib ]; then
      mkdir -p _build/test/lib
      for d in "$SEED"/*; do
        [ "$(basename "$d")" = ash_pplan ] && continue
        cp -Rc "$d" _build/test/lib/ 2>/dev/null || cp -R "$d" _build/test/lib/
      done
    fi
    MIX_BUILD_ROOT="$PWD/_build" MIX_ENV=test mix test "$TEST"
    ;;
  selfcheck)
    d="$(mktemp -d -t mirror_mut_sc)"
    trap 'rm -rf "$d"' EXIT
    printf 'def a(x), do: x == 1\n' > "$d/f.ex"
    base="$(sha "$d/f.ex")"
    printf 'def a(x), do: x != 1 # SHIM-COURT: flip_comparison\n' > "$d/f.ex"
    [ "$(sha "$d/f.ex")" != "$base" ] || { echo "VACUOUS: shim undetected"; exit 1; }
    printf 'def a(x), do: x == 1\n' > "$d/f.ex"
    [ "$(sha "$d/f.ex")" = "$base" ] || { echo "restore not byte-exact"; exit 1; }
    printf 'def a(x), do: x == 1\n ' > "$d/f.ex"
    [ "$(sha "$d/f.ex")" != "$base" ] || { echo "VACUOUS: corrupt restore undetected"; exit 1; }
    echo "selfcheck ok"
    ;;
  *)
    echo "usage: mutate.sh court <test_path> | selfcheck" >&2
    exit 2
    ;;
esac
