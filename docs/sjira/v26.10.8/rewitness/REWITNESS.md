# REWITNESS — doc-hdit certify at merged main (post-[125] cherry-pick certify)

Lane: pplan-witness-land, 2026-10-09. The official post-merge witness: the
[125] cherry-pick certify (6c8c7ec) was minted at a8810b5-era; this re-witness
re-runs the canonical audit at merged main (6c8c7ec, parent cd2b3d3) and lands
the fresh receipt chain.

## Subject

- ash_pplan main @ `6c8c7ec45b4591a84612c213879b276c8cb4b9c9` (tree of HEAD,
  exported via `git archive HEAD` to /tmp/hdit/rewitness/src — exact committed
  subject, isolated from other lanes' in-flight working-tree edits).
- Extractor pinned: ggen-marketplace `scripts/gen_doc_surface.py` @
  `feb12208` (script md5 `7fd2a9577d92874f9e69e96f2ed7036f`, verified byte-equal
  to `git show feb12208:scripts/gen_doc_surface.py`).
- Pack binary: `packs/rust-doc-hdit-pack/target/release/doc-hdit`
  (ggen-marketplace @ `115f96bdc`).
- Court: `packs/rust-doc-hdit-pack/courts/doc_quality.court`.

## Verdict

**ACCEPTED** at main 6c8c7ec — certify exit 0, fresh receipt appended to
`ash_pplan.rewitness.chain.jsonl` in this directory.

- chain hash `184b851d83ee0c5a161809f1091d3e06685c05f46de914cdee42d187de4cab41`,
  parent `""`, subject
  `0961ceaa7472031870dd29c58a5a0662653618adb1d4c0f45d599d84698ddf20`.
- inputs `ash_pplan.rewitness.inputs.json` sha256
  `17377126596017efe5fbbcf0f1d82ec913d69dde57f84c1a206c178e97416986`,
  BLAKE3 `d443040a1457a6eb8cc4dfed05535376462ae9a69b573fc783a0247bb3922ce6`
  (1,203,440 bytes): full 4-array merge — modules 317, claims 3365,
  paths 1070, directories 126 — extracted fresh at the archived subject with a
  fresh vectorize cache (`/tmp/hdit/rewitness-cache`, miss 8c241a069faa60a7 →
  hit on certify replay).

## Hash verification (recomputed on disk at landing time)

- chain hash: `blake3("doc-hdit-certify/v1|" + canonical receipt JSON excluding
  `hash`, serde sorted-key compact)` = `184b851d...` — **MATCH**.
- subject hash: `blake3("doc-hdit/subject/v1|inputs|" + inputs bytes)` =
  `0961ceaa...` — **MATCH**, the receipt binds the exact landed inputs bytes.

## Gates at main 6c8c7ec

| gate | value | threshold | verdict |
|---|---|---|---|
| S_coverage | 0.97747 | >= 0.90 | **PASS** |
| Phi_halluc (phantom) | 0.000775 | <= 0.001 | PASS |
| Q_density | 0.99923 | >= 0.65 | PASS |

Delta vs the a8810b5-era receipt (6c8c7ec): S_coverage 0.98389 → 0.97747,
Phi_halluc 0.00038 → 0.000775, Q_density 0.99962 → 0.99923. All three gates
still PASS with margin; residual Phi_halluc remains under the 0.001 ceiling.
Inputs arrays are smaller than the a8810b5 receipt's (317/3365/1070/126 vs
426/3424/15551/813) because that run extracted from the live checkout (deps/
and _build/ present) while this witness extracts from the exact committed tree
via `git archive` — the committed subject is the stricter, deps-free view and
still ACCEPTED.

## Replay

```sh
# subject export (exact committed tree, no working-tree contamination)
cd /Users/sac/ash_pplan && git archive HEAD | tar -x -C /tmp/hdit/rewitness/src
# extractor pinned at feb12208
cd /Users/sac/ggen-marketplace
git archive feb12208 scripts/gen_doc_surface.py | tar -x -C /tmp/hdit/rewitness/ext
python3 /tmp/hdit/rewitness/ext/scripts/gen_doc_surface.py code /tmp/hdit/rewitness/src \
  > /tmp/hdit/rewitness/ash_pplan.code.json
python3 /tmp/hdit/rewitness/ext/scripts/gen_doc_surface.py doc /tmp/hdit/rewitness/src \
  --code-json /tmp/hdit/rewitness/ash_pplan.code.json > /tmp/hdit/rewitness/ash_pplan.doc.json
python3 - <<'PY'
import json
c=json.load(open('/tmp/hdit/rewitness/ash_pplan.code.json'))
d=json.load(open('/tmp/hdit/rewitness/ash_pplan.doc.json'))
for i,cl in enumerate(d['claims']): cl.setdefault('id', f'ashpplan-{i}')
json.dump({'claims':d['claims'],'directories':c.get('directories',[]),
           'known_external':c.get('known_external',[]),'modules':c['modules'],
           'paths':c.get('paths',[])},
          open('/tmp/hdit/rewitness/ash_pplan.inputs.json','w'),indent=2,sort_keys=True)
PY
cd packs/rust-doc-hdit-pack
target/release/doc-hdit vectorize /tmp/hdit/rewitness/ash_pplan.inputs.json --cache /tmp/hdit/rewitness-cache
target/release/doc-hdit audit     /tmp/hdit/rewitness/ash_pplan.inputs.json courts/doc_quality.court --cache /tmp/hdit/rewitness-cache
target/release/doc-hdit certify   /tmp/hdit/rewitness/ash_pplan.inputs.json courts/doc_quality.court \
  --chain /tmp/hdit/rewitness/ash_pplan.chain.jsonl --cache /tmp/hdit/rewitness-cache  # expect ACCEPTED
```
