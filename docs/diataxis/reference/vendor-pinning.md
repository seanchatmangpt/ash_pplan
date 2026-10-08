# Vendor pinning

How `priv/ggen/vendor/` pins the ggen-marketplace packs ash_pplan consumes:
what is vendored, how the pin gate refuses un-acknowledged marketplace moves,
and what a lawful re-pin looks like end to end.

## What is vendored, and why

ash_pplan renders its generated surfaces from ggen-marketplace packs rather
than reaching into the marketplace tree at build time. Vendoring the packs at
file level with a sha256 lock makes every render reproducible from committed
bytes: the same pack bytes plus the same source git sha give a byte-identical
lock, so a silent upstream move cannot change what ash_pplan manufactures.

Nine packs are locked, in two shapes:

- **Eight whole-vendored packs** (`priv/ggen/vendor/sync.sh:45`): each pack's
  `ontology.ttl`, `pack.toml`, gates, templates, queries, tests, verify/,
  fixtures, witnesses and qualification trees are copied under
  `priv/ggen/vendor/<pack>/` with a per-file sha256 (`sync.sh:88-140`).
- **One runtime-integration pack** (`ash-runtime-integration-contract-pack`)
  is not copied whole: its templates, gates and queries are vendored into the
  consumer overlay `priv/ggen/ash-pplan-runtime-overlay/` with three
  deterministic consumer patches applied at vendor time (`sync.sh:142-448`).
  Its `ontology.ttl` is consumer-authored and not vendored.

Two more consumer-local packs (`ash-pplan-durable-chaos-pack`,
`ash-pplan-store-conformance-pack`) are recorded as **specimens** — sha-pinned
but not vendored, local wins (`sync.sh:612-665`).

`priv/ggen/vendor/PACKS.lock.json` records every file's sha256 plus the
marketplace `source_git_sha`; `provenance.ttl` mirrors the same facts as RDF
(`sync.sh:517-672`). Both are generated — never hand-edit.

## The pin gate

Every `sync.sh` run reads the marketplace repo's HEAD and compares it to
`rt_expected_sha` (`priv/ggen/vendor/sync.sh:74,82-86`):

```bash
head_sha="$(git -C "$market" rev-parse HEAD)"
if [ "$head_sha" != "$rt_expected_sha" ] && [ "${RTI_ALLOW_MOVED_MARKETPLACE:-0}" != "1" ]; then
  echo "sync.sh: marketplace HEAD $head_sha != pinned $rt_expected_sha" >&2
  echo "sync.sh: refusing; re-pin rt_expected_sha (or set RTI_ALLOW_MOVED_MARKETPLACE=1)"
  exit 3
fi
```

This is a **typed refusal** (exit 3): a silent `ba21c22a..HEAD` move on the
marketplace side is made loud instead of invisible (`sync.sh:78-80`). The lock
always records the real HEAD; the refusal only forces the move to be seen.
`RTI_ALLOW_MOVED_MARKETPLACE=1` is an escape hatch, not a lawful path — the
lawful path is a re-pin (below).

Two courts hold the same law independently:

- `test/courts/provenance_baseline_court_test.exs:56-59` requires
  `PACKS.lock.json` `source_git_sha` == marketplace HEAD, failing with the
  typed `RE-PIN NEEDED` message naming both shas and the recovery
  (`provenance_baseline_court_test.exs:169-187`).
- `test/courts/pack_gate_witness_court_test.exs:35,55,63` pins
  `@pinned_marketplace_sha` and asserts both marketplace HEAD and the lock
  equal it.

## verify_lock.sh — read-only lock check

`priv/ggen/vendor/verify_lock.sh` is the read-only counterpart, run any time
and inside the render driver before rendering:

1. Every vendored file's sha256 must still match `PACKS.lock.json`; any
   mismatch or missing file is a hard fail (`verify_lock.sh:30-47`).
2. The pinned `source_git_sha` must exist in the marketplace repo, else the
   lock references an un-checkoutable subject — hard fail
   (`verify_lock.sh:61-65`).
3. Marketplace HEAD != pin is a **loud warn** (exit 0; `VERIFY_LOCK_STRICT=1`
   escalates to fail) naming `sync.sh` re-pin as the recovery
   (`verify_lock.sh:67-74`). `sync.sh`'s gate polices the move at sync time;
   verify_lock only surfaces drift between syncs.

## The lawful re-pin procedure

The marketplace repo moves independently of ash_pplan. When the pin gate or a
court refuses, the recovery is:

1. **Witness the refusal.** Record what refused (gate exit 3 / typed
   `RE-PIN NEEDED` court failure) and the two shas: old pin -> new HEAD.
2. **Prove the move is a fast-forward.** In the marketplace repo,
   `git merge-base --is-ancestor <old-pin> <new-head>` must hold. A
   non-ancestor move (rewritten history) is a different, more serious
   situation and is not a re-pin.
3. **Re-pin `rt_expected_sha`** in `priv/ggen/vendor/sync.sh` and add a dated
   re-pin receipt comment next to it (`sync.sh:51-73` — one comment per move,
   naming old->new shas, the branch, and what refused).
4. **Re-run `sync.sh`** at the new pin. It re-vendors the packs, re-applies
   the deterministic consumer patches, and regenerates `PACKS.lock.json` +
   `provenance.ttl` deterministically.
5. **Re-pin the witness court** `@pinned_marketplace_sha`
   (`test/courts/pack_gate_witness_court_test.exs:35`).
6. **Run the courts**: `verify_lock.sh` (expect `OK (9 packs, ...)`), the
   provenance-baseline and pack-gate-witness courts, and the release
   contract.

### Worked example: a39971f (2026-10-08)

Commit `a39971fc998890c66492078e9a495b879f95c73b` re-pinned the marketplace
`ba21c22a` -> `29c579082aefe57eda5695d13cd4edb76cb82b31` (the v26.10.8 bump on
`feat/aaif-gcp-roadmap-v26.10.5`; fast-forward — `ba21c22a` is a merge-base
ancestor of HEAD). Witnessed by the pin gate refusing (exit 3) and typed
`RE-PIN NEEDED` failures in the provenance-baseline and pack-gate-witness
courts.

- `sync.sh`: `rt_expected_sha` re-pinned, 2026-10-08 re-pin receipt added
  (`sync.sh:70-74`).
- `sync.sh` re-run: all 8 vendored packs + the runtime overlay re-locked at
  the new pin. Vendored pack **bytes were identical across the move** — the
  only content diffs were the five overlay `.ex.tmpl` GENERATED-PROVENANCE
  headers embedding the new SHA (written by `sync.sh:280-297`) and the
  regenerated lock/provenance. Compare with the 2026-10-07 receipt
  (`sync.sh:63-69`), where the bytes *did* change and the re-pin was a real
  re-vendor — the receipt comments distinguish lock-only moves from
  byte-changing moves.
- `PACKS.lock.json` + `provenance.ttl` regenerated; `verify_lock.sh` OK
  (9 packs); `@pinned_marketplace_sha` re-pinned in the witness court.
- Courts: provenance-baseline + pack-gate-witness 16/16 green;
  `ash_pplan_test` + release contract 42/42 green.

## See Also

- [Adopt a marketplace pack](../how-to/adopt-a-marketplace-pack.md) — the
  first-time adoption recipe this pinning model grew out of.
- [Run the ggen gates](../how-to/run-the-ggen-gates.md) — the fail-closed
  verification surface these courts belong to.
