#!/usr/bin/env bash
# Shared helper for the bin/manufacture* fleet (lane V4).
#
# MANIFEST ROOT (repo-wide orphan detection):
#   Every recipe now records into ONE shared reconciliation manifest root,
#   ${MANUFACTURE_MANIFEST_ROOT:-tmp/mf}, instead of per-recipe
#   tmp/mf-<lane>-<name> directories. The manifest is keyed by recipe_key
#   ("<template> => <out>") INSIDE that one .ggen_igniter/manifest.json, so a
#   rename/removal upstream is visible repo-wide instead of being invisible
#   behind a per-recipe manifest (the structural orphan-detection gap the
#   per-recipe roots had: each recipe's manifest only knew its own outputs).
#   Other lanes override via MANUFACTURE_MANIFEST_ROOT (e.g. tmp/mf-v4) --
#   honored here and in every script that sources this lib.
#
# DRY RUN (drift preview):
#   With MANUFACTURE_DRY_RUN=1 every sync runs with --dry-run (zero writes,
#   zero receipts) and mix format is skipped; bin/ggen-replay-court
#   --dry-run-preview drives this and fails on any "planned: write|inject|
#   prune" line (see that wrapper). Default is a real run.
#
# RECEIPTS AND mix format (phantom-drift limitation, DISCLOSED):
#   The sync's receipt post_run_hash finalizes inside the sync (Reactor
#   :finalize_evidence step, after :actuate), BEFORE this script's trailing
#   `mix format`. Today every generated file is already format-stable (mix
#   format is a verified byte-level no-op on the whole generated tree), so
#   receipts match disk. If a template regression ever emits unformatted
#   output, the receipt would cover pre-format bytes. Reordering format
#   before receipt finalize is NOT possible without an upstream change
#   (sh_after: frontmatter hooks are per-template static commands refused
#   without --allow-sh; the hash finalizes inside the sync). Honest fallback:
#   a small upstream ggen_igniter fix records a whitespace-normalized twin of
#   post_run_hash in receipt metadata (post_run_ws_hash; applied at
#   deps/ggen_igniter and mirrored in ~/ggen_igniter, unpushed), and
#   bin/ggen-replay-court treats post_run_hash drift as format-only (and only
#   format-only) when the current bytes match that recorded ws-hash under
#   whitespace normalization. Any non-whitespace difference FAILS. See
#   bin/ggen-replay-court's header for the same disclosure.

MANUFACTURE_MANIFEST_ROOT="${MANUFACTURE_MANIFEST_ROOT:-tmp/mf}"
MF_ROOT="$MANUFACTURE_MANIFEST_ROOT"
MF_DRY_RUN="${MANUFACTURE_DRY_RUN:-0}"

# One shared sync entrypoint: mf_sync NAME -- <mix ggen_igniter.sync args...>
# Appends the shared --manifest-dir and (dry-run mode) --dry-run.
mf_sync() {
  local name="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local extra=()
  [ "$MF_DRY_RUN" = "1" ] && extra+=(--dry-run)
  mix ggen_igniter.sync "$@" --manifest-dir "$MF_ROOT" --verify-cwd "${VERIFY_CWD:-$PWD}" "${extra[@]}"
}

# VERIFY-CWD: the Reactor :verify step (mix compile) runs in --verify-cwd, which
# defaults to --manifest-dir; with the shared root that is tmp/mf, not a Mix
# project. mf_sync pins it to the repo root (VERIFY_CWD overridable) in ONE
# place for every recipe.
