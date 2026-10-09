# STANDING-RECEIPT — ash_pplan v26.10.8 doc-hdit certify standing (post-R71)

Lane: R112, 2026-10-09. Subject-bound standing receipt at main `a833f1b`.
All figures below re-read from the landed receipt files in this directory at
mint time (chain files parsed, verdicts and gates confirmed on disk).

## Standing: CERTIFIED (subject-bound, receipt-bound)

The ACCEPTED certify receipt is intact at/near HEAD with the drift disclosed.

- **Witness of record**: `reclose/ash_pplan.reclose.chain.jsonl` — ACCEPTED,
  chain `ab72283261c0d2ade86d8981d630c4ae09df086567dbc7bbdfb54352fa0ff4a6`,
  subject `cb97bcdb80e5ab7bf796db0d15bd5868ddfbe6632d67e7db39ee28047c01bbac`
  (both recomputed on disk at landing, per RECLOSE.md), gates **S_coverage
  0.97747 / Phi_halluc 0.000775 / Q_density 0.99923**, over a clean
  `git archive` of main `a1f332e` with the extractor pinned at `feb12208`.
- Landing-era chain (`ash_pplan.chain.jsonl`, b791ca5a… at a8810b5, gates
  0.98389 / 0.00038 / 0.99962) is grandfathered and superseded as the
  current-main witness by the reclose; both receipts verified ACCEPTED on
  disk at mint time.

## Drift delta (certify subject era → HEAD a833f1b)

- **10 commits** from the landing subject `a8810b5` to HEAD `a833f1b`.
- lib/test drift named by V19/R98: `lib/mix/tasks/ash_pplan.dsl_docs.ex`
  (+180 lines) and `test/dsl_docs_test.exs` (+48 lines), landed via the
  `cd2b3d3` merge. No `lib/ash_pplan/` runtime code changed in the range
  (`git diff --stat a8810b5..HEAD -- lib/ test/`: these two files only).
- Docs-only commits after the reclose subject `a1f332e`: one (`a833f1b`,
  this directory's reclose landing). The reclose subject predates HEAD by
  one docs-only commit; standing is subject-bound to `a1f332e`, not
  head-unconditional.

## Denominator-scope law citation (R91)

**PENDING.** Per the ggen-marketplace wave ledger
(`ggen-marketplace:docs/sjira/v26.10.8/SEMANTIC-WAVE-RECEIPT.md`), the R89/R91
denominator-scope law citation landed in 6 repos (ash_graphlaw, frozen-duckdb,
ex4pm, ferroplan, castle, ash_surface) but ash_pplan was carried as **SKIP** —
"denominator citation (R91) not landed" at tip `a833f1b`. The extractor-drift
mechanism the law covers is documented here and in CERTIFY-VERIFY.md (claims
3424 → 3767 under the drifted extractor, moving the coverage denominator);
no dedicated denominator-law commit exists in this repo.

## Extractor pin lineage

- **feb12208** — the extractor identity every ash_pplan ACCEPTED binds.
  Historical witnesses (b791ca5a, 184b851d) predate the pin and are
  grandfathered; the reclose (ab722832) pins it explicitly (extractor
  receipt `452051e17918de86…`, script byte-equal to
  `git show feb12208:scripts/gen_doc_surface.py`).
- **Current fleet pin**: `feb12208`, per the reclose disclosure — the
  scaffold-grounding discipline lane (ggen-marketplace `hdit-v2-structs`,
  tip `e31fbf8ed`) is **not yet merged** into ggen-marketplace main, so
  `feb12208` remains the standing extractor pin. When it lands, a fresh
  reclose at the new extractor identity is the falsifier-driven next
  witness. Certify now embeds an `extractor` field and refuses typed
  (`REFUSED:EXTRACTOR_MISMATCH`) on identity mismatch (CERTIFY-VERIFY.md,
  extractor identity pin section).

## Replay

See `reclose/RECLOSE.md` (replay block, extractor pinned at feb12208).
Replay is (inputs bytes, extractor pin, binary)-bound; an unpinned replay
picks up whatever extractor is on the marketplace checkout and will refuse
once it drifts.

## Falsifiers

- A fresh pinned-extractor certify at HEAD fails any gate → standing drops to
  FAIL-HONEST.
- A replay of the reclose inputs at the recorded pin does not reproduce
  ACCEPTED.
- hdit-v2-structs lands on ggen-marketplace main without a follow-up reclose
  at the new pin → standing goes stale by disclosure.
