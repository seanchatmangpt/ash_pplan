# Provenance Hash Reconciliation — 2026-10-04 (Addendum 7)

## Discrepancy

Integration ledger flagged `priv/ggen/vendor/provenance.ttl` self-hash on disk as
`4409e26b…` while an adjudication lane recorded `b54d1737…` (appears nowhere in repo).
Both are stale observations.

## Current hashes (shasum -a 256)

| subject | sha256 |
|---|---|
| `priv/ggen/vendor/provenance.ttl` (on disk) | `6fe554c14805e29e173cc3d99f0f1870e810cb5d57a90ec94363be98d8418e4c` |
| `PACKS.lock.json` `generated[0].sha256` | `6fe554c14805e29e173cc3d99f0f1870e810cb5d57a90ec94363be98d8418e4c` |
| `git show HEAD:priv/ggen/vendor/provenance.ttl` | `799030fa93cb869de155e9d4795c0545fb12f6444c11b15240232b5acd3259dc` |
| `git show HEAD:priv/ggen/vendor/PACKS.lock.json` generated[0] | `799030fa93cb869de155e9d4795c0545fb12f6444c11b15240232b5acd3259dc` |

## History trace

- Last tracked commit touching both files: `9fd53ae` ("tokyo-depeg: test-only Chicago burn-in scenario").
- At HEAD (`37bc291`), provenance.ttl = `799030fa…` and lock generated[0] = `799030fa…` — internally consistent.
- Working-tree provenance.ttl has since been modified (uncommitted): on-disk now `6fe554c1…`.
- Working-tree `PACKS.lock.json` generated[0] was updated to `6fe554c1…` in the same
  drift window — lock and artifact agree on disk. A later lane already reconciled this pair.
- `4409e26b…` (ledger) and `b54d1737…` (adjudication lane) appear nowhere on disk except as
  the ledger's own historical note (`receipts/integration-ledger-2026-10-04.md:649-676`).
  Both correspond to intermediate working-tree states superseded by the current `6fe554c1…` state.

## Reconciliation

**No edit performed.** Lock `generated[0].sha256` already equals the current on-disk
provenance.ttl hash. Changing it would have introduced the drift it was meant to fix.

## Gate

```
$ bash priv/ggen/vendor/verify_lock.sh
verify_lock: OK (9 packs, lock 503af6c27cef7838dcd82755ab2fe6a44f9eb6a2)
exit=0
```

Zero MISMATCH on all entries, including the previously-flagged provenance entry. No other
owners flagged.

## Standing

ALIVE — gate witnessed passing on the exact on-disk subject; reconciliation already present
in the working tree, not introduced by this lane.
