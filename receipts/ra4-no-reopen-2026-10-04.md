# RA4 No-Reopen Receipt — 2026-10-04

Closeout of this cycle's reopen sweep. READ-ONLY on lib/, packs, packs
sources; only files written: this receipt, lib/HANDWRITTEN.md (dated note),
docs/jira/coverage-index-2026-10-04.md (closeout rows). No git commands.

## Method

Every subject module re-verified with `ls` on disk at receipt time; every
falsifier cited below is an existing file-backed receipt already filed under
receipts/ — no new falsifier runs were executed by this receipt; it records
confirmations, closing the sweep opened by the E2/E2b/E3/R4/R4b/R5 waves.

## Confirmations (subject / verdict / dated falsifier citation)

- lib/ash_pplan/standing/cached.ex — UNSUPPORTED (generator-capability).
  ERRC R5, 2026-10-04: standing-ladder-pack ships only
  `templates/standing_audit_trail.md.tmpl` (markdown echo), zero Elixir
  template class (lib/HANDWRITTEN.md row).
- lib/ash_pplan/standing/sj_bridge.ex — UNSUPPORTED
  (generator-capability). ERRC R5, 2026-10-04: same standing-ladder-pack
  markdown-only falsifier as standing.ex/cached.ex (lib/HANDWRITTEN.md row).
- lib/ash_pplan/fond.ex — UNSUPPORTED (generator-capability). ERRC E2,
  2026-10-04; re-confirmed E3, 2026-10-04 —
  receipts/e3-falsifier-batch-2026-10-04.md (planning-federation-pack
  Python+JSON-IR only; no strong-cyclic Elixir template class).
- lib/ash_pplan/fond/corpus.ex — UNSUPPORTED (generator-capability).
  ERRC E3, 2026-10-04 — receipts/e3-falsifier-batch-2026-10-04.md
  (workflow-corpus-pack ships NO templates/ at all; nearest analog
  tokyo-depeg-burn-in-pack corpus class-disjoint).
- workflow-corpus-pack surface (workflow_corpus_court) — generation
  impossible a priori. ERRC E3, 2026-10-04 — same e3 receipt: pack has
  ontology.ttl + SPARQL gates only, no templates/.
- lib/ash_pplan/state_machine.ex (fsm.ex.tmpl class) — PARTIAL (named
  residue). R4b, 2026-10-04 —
  receipts/r4b-state-transition-falsifier-2026-10-04.md (row-shape slice
  expressible; runtime AshStateMachine introspection surface is not;
  reopens only if the pack gains a resource-projection template class).

## Reopen triggers (restated, unchanged)

- cached.ex / sj_bridge.ex / standing.ex: any standing-ladder-pack Elixir
  judgment-class template.
- fond.ex / fond/corpus.ex: any strong-cyclic / corpus-generator Elixir
  template class in any pack.
- state_machine.ex: state-transition-pack resource-projection template
  class.

## Closeout status

Sweep CLOSED for this cycle. Queue stands at 26 rows / 30 files (E3 count);
no candidate row reopened; no verdict changed.
