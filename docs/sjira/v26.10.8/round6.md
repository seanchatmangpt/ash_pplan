# Round 6 — Standing

Lane: pplan-round6-land, 2026-10-09. Standing note for the ash_pplan doc-hdit
round-6 certify work; all figures below read from the landed receipt files in
this directory (`ash_pplan.chain.jsonl`,
`rewitness/ash_pplan.rewitness.chain.jsonl`, `rewitness/REWITNESS.md`,
`CERTIFY-VERIFY.md`).

## Certify ACCEPTED at merged main

- Verdict: **ACCEPTED**, certify exit 0, at merged main `6c8c7ec`
  (post-[125] cherry-pick certify; parent `cd2b3d3`).
- Chain hash
  `184b851d83ee0c5a161809f1091d3e06685c05f46de914cdee42d187de4cab41`,
  parent `""`, subject
  `0961ceaa7472031870dd29c58a5a0662653618adb1d4c0f45d599d84698ddf20`.
- Gates (stricter deps-free archive view — extracted from a clean
  `git archive` of the committed subject, no working-tree `_build`/deps
  contamination):

| gate | value | threshold | verdict |
|---|---|---|---|
| S_coverage | 0.97747 | >= 0.90 | **PASS** |
| Phi_halluc (phantom) | 0.000775 | <= 0.001 | PASS |
| Q_density | 0.99923 | >= 0.65 | PASS |

## Re-witnessed

- Landed as commit `9c6b676` ("docs(sjira): v26.10.8 post-merge re-witness —
  ACCEPTED at main 6c8c7ec"); receipt dir
  `docs/sjira/v26.10.8/rewitness/`.
- Chain hash and subject hash **recomputed on disk at landing time**
  (blake3 canonical-receipt re-derivation) and both **MATCH** — the receipt
  binds the exact landed inputs bytes
  (`ash_pplan.rewitness.inputs.json`, sha256 `17377126...`, 1,203,440 bytes:
  317 modules / 3365 claims / 1070 paths / 126 dirs).
- The earlier a8810b5-era receipt (chain `b791ca5a...`) extracted from the
  live working tree (deps/ and `_build/` present); the re-witness receipt is
  the stricter, deps-free committed-subject view and supersedes it as the
  current-main witness.

## Disclosed residual

1 ungrounded claim (AshPPlan.Dsl, README group row) — symbol verified real on
disk (`lib/ash_pplan/dsl.ex:4`) but invisible to the gen_doc_surface v1
scanner (heredoc swallows the defmodule). Extractor fidelity gap, not a doc
defect; the Phi gate passes with it.

## Standing

**certify-landed + re-witnessed.** The ACCEPTED baseline is receipt-bound, not
head-unconditional: each ACCEPTED binds an (inputs bytes, extractor pin,
binary) triple.

**Extractor pin required for replays** (ggen-marketplace fleet law [150],
2026-10-09): certify embeds an `extractor` field (BLAKE3 over extractor source
bytes) and refuses typed (`REFUSED:EXTRACTOR_MISMATCH`) when the replay
extractor identity differs. Pass
`--extractor scripts/gen_doc_surface.py` pinned at ggen-marketplace
`feb12208`. Unpinned replays silently pick up whatever extractor is on the
marketplace checkout and will refuse once it drifts.

See Also: `CERTIFY-VERIFY.md` · `rewitness/REWITNESS.md`
