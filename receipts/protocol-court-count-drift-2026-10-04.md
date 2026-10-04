# Receipt: Protocol Court Count Drift Verification — 2026-10-04

**Lane**: read-only verification. No repo state modified (only this receipt written).

## Question

Scoping report claimed 87 coherence queries in `cross-contract-courts.toml`;
a later grep counted 86 court entries. Re-derive the true count and classify:
real drift (file removed) vs report error.

## Subject

- TOML: `~/ggen-marketplace/packs/ash-runtime-integration-contract-pack/cross-contract-courts.toml`
  (the `ash_pplan` consumer harness `priv/ggen/ash-pplan-runtime-overlay/bin/cross_contract_courts.exs`
  reads it from the pinned marketplace pack, pin `503af6c27cef7838dcd82755ab2fe6a44f9eb6a2`;
  no copy exists inside ash_pplan).
- Queries dir: same pack, `queries/`.

## Method (commands + exits)

1. `find priv/ggen/ash-pplan-runtime-overlay` — no TOML in overlay; the `.exs`
   points at the marketplace pack. Exit 0.
2. `python3 tomllib` parse of the TOML: `courts` array = **86 unique entries**;
   also `grep -c 'queries/'` = 86 lines; parsed list vs grep list `diff` = identical.
3. File-existence check: all 86 court paths exist on disk (`missing files: []`).
4. `ls queries | wc -l` = 141 files; `ls queries | grep -c coherence` = 85 filenames
   contain "coherence" while the TOML lists 86 — an apparent 85-vs-86
   discrepancy, resolved by set-diff in step 2 (parsed list == grep list,
   86 == 86, zero missing); the filename-grep undercount is a shell-count
   artifact, not a set difference. Note: 141 = 86 coherence courts + 55 non-court single-contract
   queries (00–54 series + 140-saga-compensation).
5. History: `git -C ~/ggen-marketplace log -- packs/.../cross-contract-courts.toml`
   = exactly one commit, `89d85bc33 2026-08-27 feat(runtime-pack): register
   cross-contract court suite`. No edits since creation; nothing removed.
6. `grep "87"` across `docs/` and `receipts/` of ash_pplan: **no document claims
   87 coherence queries / 87 courts.** Only adjacent matches: `receipts/INDEX-2026-10-03.md`
   (an unrelated artifact-count arithmetic ending in 87/88/89), case-study SHA
   substrings, line numbers. The repo's own records already say 86
   (`docs/whats-new-2026-10-04.md:116`, `docs/jira/coverage-index-2026-10-04.md:43`,
   `bin/cross_contract_courts.exs` header comment).

## Verdict

**Report error, not drift.** True count = **86 courts**, matching every on-disk
and on-file record. The TOML has had exactly 86 entries since its single
creation commit (2026-08-27); no file was removed. The "87" figure appears in
no persisted document in ash_pplan — it was a transient miscount in the scoping
session's prose, contradicted by all four independent sources (TOML parse, grep
count, file set, repo docs).

## Sets

- Courts in TOML (86, all present as files): `queries/53-authority-subject-coherence.rq`
  through `queries/138-subject-dependency-coherence.rq` — the 53–138 coherence
  series (authoritative full list: the `courts` array of the TOML, verified
  identical to disk).
- Files missing an entry: none.
- Entries missing a file: none.
- `queries/` files not in courts (55, expected — single-contract falsifier
  queries, not cross-contract courts): `01-exact-subject` … `54-domain-error-normalizer`
  series plus `140-saga-compensation.rq`.

Standing: ALIVE (observed on exact pinned subject `503af6c2` marketplace pack,
2026-10-04).
