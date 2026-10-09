# CERTIFY-VERIFY — doc-hdit certify at merged main (v26.10.8)

Lane: pplan-merge-certify, 2026-10-08. Merges the final phantom-claim repair and
re-certifies the doc surface at merged main.

## Merge

`docs/repair-final-3-phantom-claims` @ e932e93 landed on main via cherry-pick `-x`
as **a8810b5** ("docs: repair final 3 phantom claims"). Deviation, disclosed: the
named branch also carried 66a6894 (`lib/mix/tasks/ash_pplan.dsl_docs.ex` + test),
which is shared with the still-pending lanes `fix/dsl-docs-unbackticked-spec-cells`
and `lane/dsl-gen-fix-98` — merging it here would have crossed the docs-only gate
and stolen another lane's file ownership, so only the docs-only tip e932e93 was
landed. The branch itself is untouched (no rebase, no force).

## Verdict

**ACCEPTED at main a8810b5** — this replaces the FAIL-honest row: the pre-repair
audit (branch era, /tmp/hdit/lane3-cache inputs) measured Phi_halluc 0.0034 with
9 ungrounded claims (top: AshPPlan.Catalog / AshPPlan.PolicyClosure / Mix.Tasks),
over the 0.001 gate. The repair (e932e93) dropped it to 0.00038 and certify now
passes all three gates.

- Canonical chain (`ash_pplan.chain.jsonl` in this directory): hash
  `b791ca5ae8519e68d08c5cefa2765b2ae509efe46ca080869523d52f10d125eb`,
  parent `""`, subject
  `ee5cdb575ecf8d2a919154b6c52ed3fad074478e1695714b22dcb7ef5f3a8f50`,
  gates S_coverage 0.98389 / Phi_halluc 0.00038 / Q_density 0.99962, **ACCEPTED**,
  certify exit 0.
- Inputs `ash_pplan.inputs.json` (sha256 `26debcf44a5e40f84a839b03176bb85e8c8a871a901ac0bed94781bb6d12df1a`,
  BLAKE3 `45e934d3add7f2406f58f95f70adbf12afbb591aa5b3b5153c85acad2853473c`):
  full 4-array merge (modules 426, claims 3424, paths 15551, directories 813,
  known_external carried) extracted fresh at merged main a8810b5 with
  ggen-marketplace @ feb12208 extractor.
- Fresh vectorize cache (`/tmp/hdit/pmerge-cache`), no replay of the lane3 cache.

## Hash verification (on disk, at landing time)

- chain hash recomputed: `blake3("doc-hdit-certify/v1|" + canonical receipt JSON
  excluding `hash`, serde sorted-key compact)` = `b791ca5a...` — MATCH.
- subject recomputed: `blake3("doc-hdit/subject/v1|inputs|" + inputs bytes)` =
  `ee5cdb57...` — MATCH, so the receipt binds the exact committed inputs bytes.

## Gates at main a8810b5

| gate | value | threshold | verdict |
|---|---|---|---|
| S_coverage | 0.98389 | >= 0.90 | **PASS** |
| Phi_halluc (phantom) | 0.00038 | <= 0.001 | PASS |
| Q_density | 0.99962 | >= 0.65 | PASS |

## Replay

```sh
# ggen-marketplace @ main (extractor scripts/gen_doc_surface.py; pack binary
# packs/rust-doc-hdit-pack/target/release/doc-hdit)
cd /Users/sac/ggen-marketplace
python3 scripts/gen_doc_surface.py code /Users/sac/ash_pplan > /tmp/hdit/pmerge/ash_pplan.code.json
python3 scripts/gen_doc_surface.py doc  /Users/sac/ash_pplan --code-json /tmp/hdit/pmerge/ash_pplan.code.json \
  > /tmp/hdit/pmerge/ash_pplan.doc.json
# full 4-array merge (the ex4pm seam fix: carry paths/directories/known_external,
# not only modules+claims)
python3 - <<'PY'
import json
c=json.load(open('/tmp/hdit/pmerge/ash_pplan.code.json'))
d=json.load(open('/tmp/hdit/pmerge/ash_pplan.doc.json'))
for i,cl in enumerate(d['claims']): cl.setdefault('id', f'ashpplan-{i}')
json.dump({
    'claims': d['claims'],
    'directories': c.get('directories', []),
    'known_external': c.get('known_external', []),
    'modules': c['modules'],
    'paths': c.get('paths', []),
}, open('/tmp/hdit/pmerge/ash_pplan.inputs.json','w'), indent=2, sort_keys=True)
PY
cd packs/rust-doc-hdit-pack
target/release/doc-hdit vectorize /tmp/hdit/pmerge/ash_pplan.inputs.json --cache /tmp/hdit/pmerge-cache
target/release/doc-hdit audit     /tmp/hdit/pmerge/ash_pplan.inputs.json courts/doc_quality.court --cache /tmp/hdit/pmerge-cache
target/release/doc-hdit certify   /tmp/hdit/pmerge/ash_pplan.inputs.json courts/doc_quality.court \
  --chain /tmp/hdit/pmerge/ash_pplan.chain.jsonl --cache /tmp/hdit/pmerge-cache  # expect ACCEPTED
```

## Falsifier

Re-run the replay at any HEAD where certify REFUSES (any gate out of bounds with
the full 4-array merge in place) — the ACCEPTED baseline above is refuted and
this doc must be refreshed.

## Standing

- Pre-repair honest finding (branch-era audit, Phi 0.0034 / 9 ungrounded claims):
  superseded by this ACCEPTED certify at a8810b5.
- ash_pplan doc-hdit gate standing at main a8810b5: **ACCEPTED** — certify hash
  `b791ca5a...` bound to the committed inputs (`ash_pplan.inputs.json`,
  sha256 `26debcf4...`), not to HEAD unconditionally.
- Disclosed residual (carried from e932e93): 1 ungrounded claim (AshPPlan.Dsl,
  README group row) — symbol verified real on disk (`lib/ash_pplan/dsl.ex:4`) but
  invisible to the gen_doc_surface v1 scanner (heredoc swallows the defmodule).
  Extractor fidelity gap, not a doc defect; Phi gate passes with it.

## Standing refresh — 2026-10-09 re-confirmation at main 6c8c7ec

Lane pplan-merge-certify re-ran the confirmation at merged main 6c8c7ec.
Three facts, all real output:

1. **The committed subject reproduces ACCEPTED.** Chain hash `b791ca5a...`
   and subject hash `ee5cdb57...` recomputed on disk from
   `ash_pplan.chain.jsonl` / `ash_pplan.inputs.json` — both MATCH. The
   committed inputs re-audited with the same doc-hdit binary:
   coverage 0.9839 / phantom 0.0004 / density 0.9996 — PASS, agreeing
   with the landed gates. The receipt is valid as bound.
2. **Fresh re-certification at merged main REFUSES.** Documented replay
   (working-tree extraction, current ggen-marketplace `637db33a` extractor,
   fresh vectorize cache `/tmp/hdit/pmerge-h2-cache`, surface 457 modules /
   3767 claims / 15559 paths / 815 dirs) →
   `REFUSED:DOC_HDIT_CERTIFY_GATE_FAIL:S_coverage value=0.6232
   threshold=0.9000`, certify exit 1, no receipt minted.
   Cross-check on a clean `git archive` of HEAD (current extractor):
   coverage 0.5935, same FAIL. Verdict tracks the extraction surface,
   not the docs.
3. **Cause: extractor drift, not docs regression.** The landed subject was
   extracted at marketplace pin `feb12208`; since then the extractor
   harvests additional claim classes (e.g. `[130]` string/atom config keys),
   changing claims (3424 → 3767) and the coverage denominator. Same binary,
   landed inputs bytes → PASS; freshly extracted inputs → FAIL. The gate is
   extractor-identity-sensitive and the replay did not pin it.

### Reconciled standing (updated after 9c6b676)

Concurrent lane commit **9c6b676** ("post-merge re-witness — ACCEPTED at main
6c8c7ec") re-certified at HEAD with the extractor **pinned at `feb12208`**
over a clean `git archive` of the subject: ACCEPTED, chain
`184b851d83ee0c5a161809f1091d3e06685c05f46de914cdee42d187de4cab41`,
subject `0961ceaa7472031870dd29c58a5a0662653618adb1d4c0f45d599d84698ddf20`
(both recomputed on disk by this lane: MATCH), gates S_coverage 0.97747 /
Phi_halluc 0.000775 / Q_density 0.99923, surface 317 modules / 3365 claims /
1070 paths / 126 dirs.

- ACCEPTED **does** reproduce at merged main 6c8c7ec when the extractor is
  pinned at `feb12208` (9c6b676 receipt). The refusal in fact 2 is fully
  attributed to extractor identity, and the docs themselves are clean.
- Gate standing is **receipt-bound, not head-unconditional**: each ACCEPTED
  binds an (inputs bytes, extractor pin, binary) triple. The unpinned replay
  command in this doc silently picks up whatever extractor is on the
  marketplace checkout and will refuse once it drifts — pin it before
  relying on a re-run.
- The a8810b5-era landing inputs (`26debcf4...`) additionally embed the
  working tree at extraction time (`_build-court-*` directories, 109
  empty-ident modules), so those exact subject bytes are a working-tree
  snapshot, not reproducible from a clean checkout; the 9c6b676
  clean-archive receipt supersedes it as the current-main witness.

## Extractor identity pin (ggen-marketplace fleet law [150], 2026-10-09)

Both chains in this doc (b791ca5a... at a8810b5, 184b851d... at 6c8c7ec) are
**grandfathered**: they predate the extractor pin and remain valid as bound.
Certify now embeds an `extractor` field (BLAKE3 over the extractor source
bytes) into every new receipt and refuses typed
(`REFUSED:EXTRACTOR_MISMATCH`) on replay when the current extractor identity
differs from the recorded one; `--force-rebaseline` mints a NEW baseline
receipt acknowledging the drift. Pass `--extractor scripts/gen_doc_surface.py`
(ggen-marketplace) when replaying so new receipts carry the pin. The unpinned
replay block above predates the pin and still picks up whatever extractor is
on the marketplace checkout — the pin exists so that failure mode becomes a
typed refusal instead of a silent verdict change.
