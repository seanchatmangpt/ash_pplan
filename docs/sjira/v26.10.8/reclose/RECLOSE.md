# RECLOSE — doc-hdit reclose at main a1f332e (extractor pinned at feb12208)

Lane: pplan-reclose, 2026-10-09. Re-runs the canonical audit at current
ash_pplan main after the [125] repair settled, with the full 4-array merge.
The scaffold-grounding discipline lane (ggen-marketplace `hdit-v2-structs`,
tip `e31fbf8ed`) is **not yet merged** into ggen-marketplace main, so this is
the fallback witness: extractor pinned at `feb12208`.

## Subject

- ash_pplan main @ `a1f332e` (committed tree exported via `git archive a1f332e`
  to `/tmp/hdit/reclose/src` — exact committed subject, no working-tree
  contamination; other lanes' in-flight `lib/` and `docs/` edits excluded).
- Extractor pinned: ggen-marketplace `scripts/gen_doc_surface.py` @
  `feb12208` (extractor receipt pin `452051e17918de86...`, script sha256
  `880840ae9703e1c9...`, md5 `7fd2a9577d92874f9e69e96f2ed7036f` — byte-equal
  to `git show feb12208:scripts/gen_doc_surface.py`).
- Pack binary: `packs/rust-doc-hdit-pack/target/release/doc-hdit`
  (ggen-marketplace @ `115f96bdc`).
- Court: `packs/rust-doc-hdit-pack/courts/doc_quality.court`
  (thresholds unchanged — no threshold change in this reclose).

## Verdict

**ACCEPTED** — certify exit 0, receipt appended to
`ash_pplan.reclose.chain.jsonl` in this directory.

- chain hash `ab72283261c0d2ade86d8981d630c4ae09df086567dbc7bbdfb54352fa0ff4a6`,
  parent `""`, subject
  `cb97bcdb80e5ab7bf796db0d15bd5868ddfbe6632d67e7db39ee28047c01bbac`.
- inputs `ash_pplan.inputs.json` (built at `/tmp/hdit/reclose/`, sha256
  `44bd9097f96cb3cde9ba70d12e82bc0690cf32b7cd8db39306a585de730b973f`,
  1,203,702 bytes): full 4-array merge — modules 317, claims 3365,
  paths 1074, directories 127, known_external 27 — extracted fresh at the
  archived subject with a fresh vectorize cache (`/tmp/hdit/reclose-cache`,
  hit `8c241a069faa60a7`).

## Hash verification (recomputed on disk at landing time)

- chain hash: `blake3("doc-hdit-certify/v1|" + canonical receipt JSON
  excluding `hash`, sorted-key compact)` = `ab722832...` — **MATCH**.
- subject hash: `blake3("doc-hdit/subject/v1|inputs|" + inputs bytes)` =
  `cb97bcdb...` — **MATCH**, the receipt binds the exact landed inputs bytes.

## Gates at main a1f332e

| gate | value | threshold | verdict |
|---|---|---|---|
| S_coverage | 0.97747 | >= 0.90 | **PASS** |
| Phi_halluc (phantom) | 0.000775 | <= 0.001 | PASS |
| Q_density | 0.99923 | >= 0.65 | PASS |

## Delta vs the 6c8c7ec re-witness (184b851d)

Gates effectively unchanged: S_coverage 0.97747 → 0.97747,
Phi_halluc 0.000775 → 0.000775, Q_density 0.99923 → 0.99923. Surface moved
only in paths/directories (1070 → 1074, 126 → 127; modules and claims
identical at 317 / 3365), consistent with the docs-only landing commits
(8d42603, a1f332e) between the two subjects. **No spec-tier exclusion of any
kind was applied in this run** — the plain court passes as-is at the pinned
extractor; the audit ran with `external_documented count=0` and no claim
allowlist. Phantom residue remains the disclosed AshPPlan.Dsl heredoc
extractor-fidelity gap carried from the re-witness, under the gate.

## Standing

This receipt supersedes the 9c6b676 re-witness (184b851d, subject 6c8c7ec) as
the current-main witness. Standing remains **receipt-bound, not
head-unconditional**: each ACCEPTED binds an (inputs bytes, extractor pin,
binary) triple. Once the scaffold-grounding discipline lands on
ggen-marketplace main, a fresh reclose at the new extractor identity is the
falsifier-driven next witness.

## Replay

```sh
# subject export (exact committed tree)
cd /Users/sac/ash_pplan && git archive a1f332e | tar -x -C /tmp/hdit/reclose/src
# extractor pinned at feb12208
cd /Users/sac/ggen-marketplace
git archive feb12208 scripts/gen_doc_surface.py | tar -x -C /tmp/hdit/reclose/ext
python3 /tmp/hdit/reclose/ext/scripts/gen_doc_surface.py code /tmp/hdit/reclose/src \
  > /tmp/hdit/reclose/ash_pplan.code.json
python3 /tmp/hdit/reclose/ext/scripts/gen_doc_surface.py doc /tmp/hdit/reclose/src \
  --code-json /tmp/hdit/reclose/ash_pplan.code.json > /tmp/hdit/reclose/ash_pplan.doc.json
python3 - <<'PY'
import json
c=json.load(open('/tmp/hdit/reclose/ash_pplan.code.json'))
d=json.load(open('/tmp/hdit/reclose/ash_pplan.doc.json'))
for i,cl in enumerate(d['claims']): cl.setdefault('id', f'ashpplan-{i}')
json.dump({'claims':d['claims'],'directories':c.get('directories',[]),
           'known_external':c.get('known_external',[]),'modules':c['modules'],
           'paths':c.get('paths',[])},
          open('/tmp/hdit/reclose/ash_pplan.inputs.json','w'),indent=2,sort_keys=True)
PY
cd packs/rust-doc-hdit-pack
target/release/doc-hdit vectorize /tmp/hdit/reclose/ash_pplan.inputs.json --cache /tmp/hdit/reclose-cache
target/release/doc-hdit audit     /tmp/hdit/reclose/ash_pplan.inputs.json courts/doc_quality.court --cache /tmp/hdit/reclose-cache
target/release/doc-hdit certify   /tmp/hdit/reclose/ash_pplan.inputs.json courts/doc_quality.court \
  --chain /tmp/hdit/reclose/ash_pplan.chain.jsonl --cache /tmp/hdit/reclose-cache \
  --extractor /tmp/hdit/reclose/ext/scripts/gen_doc_surface.py  # expect ACCEPTED
```
