# ECO-SA2A-PACKS — sa2a pack family: zero-consumer decision

Date: 2026-10-04. Lane: ERRC item 3. Status: decision + evidence only,
nothing implemented.

## Verified state (read-only, 2026-10-04)

- Packs exist in `/Users/sac/ggen-marketplace/packs/`:
  - `sa2a-governed-process-pack` — pack.toml (484 B) + ontology.ttl
    (1847 B); `gates/`, `queries/`, `templates/` all EMPTY dirs.
  - `sa2a-spark-dsl-pack` — pack.toml (411 B) + ontology.ttl (2693 B);
    `gates/`, `queries/`, `templates/` all EMPTY dirs.
  - `sa2a-chicago-court-pack` — pack.toml (535 B) + ontology.ttl (2440 B)
    + shapes.ttl + queries/courts.rq + 2 templates
    (`chicago_suite.exs.tmpl`, `chicago_suite_test.exs.tmpl`).
- Zero consumers in ash_pplan: grep over `lib/ test/ mix.exs ggen.toml`
  for `sa2a-(governed-process|spark-dsl|chicago-court)` and variants
  returns no matches (exit 1). `priv/ggen/vendor/` vendors only
  tokyo-depeg-burn-in-pack; no sa2a pack is vendored or synced.
- Empty-husk confirmed: the two packs ship no gates, queries, or
  templates — pack.toml description promises C12 fabric / Spark DSL
  transformers that do not exist as pack artifacts.
- chicago-court templates are AshA2A-repo-targeted: they alias
  `AshA2A.Authority.{Lease, TwoPortGate}`, `AshA2A.{Command, Receipt,
  SemanticSubject}`, `AshA2A.Receipt.OfflineReplay` — none exist in
  ash_pplan. Adopting them here is a port, not a drop-in.

## Option A — mark UNSUPPORTED (typed, generator-capability)

Typed status `UNSUPPORTED (generator-capability)` in the composition
space, citing precedent in
`receipts/final-release-receipt-26.10.1.md` (UNSUPPORTED table, e.g.
"ggen_igniter `for_each` frontmatter substitution | UNSUPPORTED
upstream") and `docs/archive/pplan-w3c-audit-2026-10-04.md` (C10 verdict:
CONFORMANT_WITH_UNSUPPORTED_GAPS).

- Capability gain: zero new capability; honest standing vocabulary.
  Risk: low — declarative only, no gates touched.
- Cost: ~minutes. Zero falsifier burden (a no-gate status).

## Option B — adopt chicago-court templates over existing corpora

Adopt the pack's two templates against the tokyo-depeg/refusal corpora,
with a mutation-vacuity check before replacing hand-written fuzz
scaffolds. Exact hand-written files it would replace (grep-verified):

- `test/hardening/sa2a_refusal_fuzz_test.exs` (253 lines)
- `test/hardening/sa2a_replay_fuzz_test.exs` (220 lines)
- adjacent real-collaborator scaffolds in `test/hardening/`:
  `fond_policy_fuzz_test.exs` (287 lines), `receipts_fuzz_test.exs`,
  `policy_offers_fuzz_test.exs`

Plus un-verified risks: templates hard-code `AshA2A.*` aliases absent
here; ontology.ttl (2440 B) has never been admitted against an ash_pplan
subject; no receipt of a pack-generated suite passing in ash_pplan.

- Capability gain: moderate IF the pack-generated suite matches or
  beats the hand-written courts; unknown until falsified.
- Risk: high — replacing ~473 lines of currently-passing hand-written
  fuzz courts (real collaborators, currently in the passing suite) with
  an un-admitted port; `mocking-banned` discipline means a generated
  suite must prove zero-mock + real-collaborator parity, not be assumed.
- Cost: high — port aliases, admit ontology, mutation-vacuity check
  (C05 pattern), re-run full hardening suite.

## Recommendation

**Option A, unconditionally.** Option B only as a later work order if
the pack suite is first admitted on the AshA2A repo (its actual target)
and shows a measured gap the hand-written ash_pplan courts miss.

Rationale by (capability)/(risk x cost):

- Option A: 0/(low x ~0) — zero-denominator, honest standing, minutes.
- Option B: moderate/(high x high) — negative expected value now; the
  hand-written courts exist, pass, and are mutation-proven non-vacuous
  (see `receipts/case-study-layer-2026-10-04.md` family); replacing
  passing courts with an un-admitted generator output violates the
  verify-ladder (SUBJECT_ALIVE requires proof on the exact subject).
