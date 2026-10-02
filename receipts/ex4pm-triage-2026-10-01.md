# ex4pm Dirty-Tree Triage — 2026-10-01 (read-only lane P4)

## Subject
- Repo: `~/ex4pm`, branch `main`, HEAD `2974b2a chore(release): ex4pm 26.10.1`
- Version in mix.exs: **still `26.10.1`** (no bump to 26.10.2)
- Tags: latest `v26.10.1` (older: v26.9.30, v26.9.9, v26.8.27/28)
- Hex published versions: **`26.10.1`, `26.9.30`, `26.9.9`** — 26.10.2 NOT on hex

## Dirty files (3, all docs-only)
1. `CHANGELOG.md` — adds **26.10.2-targeted "Added" entries** documenting two already-committed feature sets:
   - `Ex4pm.EconomicISA` (refs `d1ff769`, PR #45): one-byte economic-activity ISA, projects into existing OCEL `Ex4pm.Event` IR.
   - `Ex4pm.Gall` (refs `8a68c2c`/`7c9d2f9`/`088df36`): GALL-015..020 qualification surfaces (Corpus, POWL dual-ingress algebra, OCPQ, Discovery, Compliance, Compute); `authority: "NONE"`, observe-only.
   Both modules **exist in lib and are committed** (`git log` on the files confirms `088df36`, `7c9d2f9`, merge `1e385c7`). The changelog is playing catch-up, not describing uncommitted code.
2. `docs/diataxis/reference.md` — reference tables for the same two modules (EconomicISA encode/decode/lookup/to_event; Gall digest/Portable/Corpus/Powl/Ocpq/Discovery/Compliance/Compute).
3. `docs/thesis/chapters/generated_ocel_benchmark_tables.tex` — regenerated benchmark numbers: corpus changed 4910 → 1296 events; wall 28→7 ms, entropy 2.0915→1.9523 bits, P99 80 ms tail line partially shown in diff. Regenerated artifact, consistent with docs-only sweep.

## Meaning of the dirty state
This is **pre-release prep for ex4pm 26.10.2** (CalVer — today 2026-10-01 fits): a docs/changelog backfill session documenting already-merged EconomicISA and Gall work, plus regenerated thesis benchmark tables. Not mid-flight code changes; mix.exs not yet bumped; no v26.10.2 tag; 26.10.2 not published. The release commit ("chore(release): 26.10.2", version bump, tag, hex publish) has NOT happened yet — the other session is mid-sequence, between docs prep and the release commit.

## Recommendation for ash_pplan / beam4pm pinning
- **Pin to `v26.10.1` (hex `26.10.1`)** — the last released, tagged, hex-published version. Do NOT pin to git HEAD `2974b2a`-plus-dirty: HEAD itself is already one commit past a known-good pin? No — HEAD **is** the 26.10.1 release commit, but the dirty tree adds only docs, so a SHA pin to `2974b2a` is functionally identical to the tag. Prefer the tag/hex version for replayability.
- Note: ex4pm commit `2fd3a21 refactor!: remove all beam4pm knowledge from ex4pm` means ex4pm ≥26.10.x is beam4pm-knowledge-free; consumers needing that knowledge hold it themselves.
- **Wait, don't act**: docs-only dirty state, owned by another live session. No consumer action is warranted. Re-triage only if a `chore(release): 26.10.2` commit / `v26.10.2` tag / hex publish appears, then evaluate pinning forward if EconomicISA/Gall surfaces are wanted.

## Standing
- UNKNOWN→observed: triage is read-only observation; no ex4pm file touched, no commits, no pushes. This receipt written outside ex4pm as instructed.
