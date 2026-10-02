# graphlaw engine — consumer wiring and differential court

Lane W5. Status of this note: written 2026-10-01 against ggen_igniter branch
`docs/diataxis-fanout` (canonical checkout `~/ggen_igniter`).

## What graphlaw-wasm adds

An **independent SPARQL engine implementation** for parity courts. The
ggen_igniter engine registry (`~/ggen_igniter/lib/ggen_igniter/engine.ex`)
currently offers three engines — `oxigraph` (default, Rustler NIF over ggen's
own oxigraph), `sparql` (pure-Elixir hex package), and `qlever` (remote HTTP
endpoint). All three in-process options share one weakness as parity witnesses:
they are separate implementations but the differential court between them was
run per-query rather than over the full 18-gate manufacture surface.

graphlaw is a **wasm-hosted SPARQL engine** (Rust `graphlaw` compiled to wasm,
hosted in Elixir via the already-present `wasmex` dep, `~> 0.9`) registered as
a fourth engine name, `"graphlaw"`. Because it is an independent
implementation with no shared code with oxigraph or the sparql hex package, a
disagreement between oxigraph and graphlaw over the same gate query is real
signal — one of the two is wrong — rather than a shared-implementation
artifact. This is the generate-and-kill shape (composition C04/C20): N
independent generator/engine identities, courts kill on disagreement.

## How to attach

- Engine name: `--engine graphlaw` (single) or `--engine oxigraph,graphlaw`
  (comparison; oxigraph stays primary/actuating, graphlaw is witness-only).
- Artifact path: `Application.get_env(:ggen_igniter, :graphlaw_wasm_path)` —
  explicit override; the built-in default is
  `~/graphlaw/target/wasm32-wasip1/wasm/graphlaw_wasm.wasm` (verified present
  on this machine: 6,657,549 bytes, built 2026-09-30). A missing artifact
  fails fast in `prepare!/2` with a typed error naming the exact path and
  build command. Or in config:

  ```elixir
  config :ggen_igniter, graphlaw_wasm_path: "priv/graphlaw/praxis_graphlaw.wasm"
  ```

- `wasmex` is already a hard dep of ggen_igniter (`mix.exs`, `{:wasmex,
  "~> 0.9"}`), so no new dep is required by consumers.
- Bash consumers: `bin/ggen-engine-report --graphlaw` (or
  `GRAPH_ENGINE=graphlaw bin/ggen-engine-report`) runs one representative
  recipe per ash_pplan pack with `--engine oxigraph,graphlaw` and the
  engine-report artifact; disagreement handling identical to the
  `oxigraph,sparql` comparison (same canonicalizing parser,
  `bin/.ggen-engine-report-parse.py`).

## The differential-court recipe (oxigraph vs graphlaw over the 18 gates)

W4's differential validation runs all 18 real ash_pplan gates under both
engines. The consumer-side recipe, once landed:

```bash
cd ~/ash_pplan
MIX_BUILD_ROOT=_build-w5 MANUFACTURE_MANIFEST_ROOT=tmp/mf-w5 \
  ./bin/ggen-engine-report --graphlaw
```

Exit codes: 0 = engines agree on every pack's representative recipe;
1 = at least one engine disagreement (see `tmp/engine-report-*.md` for the
diffable artifact); 2 = graphlaw not yet registered in ggen_igniter's
`Engine.valid_names()` (W2/W3 pending — not a semantic failure).

Per-pack detail: `tmp/engine-report-<pack>.md` (human-diffable) and
`.json` (machine-parsed by `bin/.ggen-engine-report-parse.py`, which
canonicalizes cell value-shapes so oxigraph's `"12"` vs sparql's `12`
integer-shape difference does not false-red).

## Current status (verified 2026-10-01, lane W5)

**LANDED in the ggen_igniter canonical checkout, NOT YET CONSUMABLE from
ash_pplan, VALIDATION PENDING (W4).**

Verified real on disk just now:

- `~/ggen_igniter/lib/ggen_igniter/engine.ex` `@registry` now contains
  `"graphlaw" => GgenIgniter.Engine.Graphlaw` (direct read).
- `~/ggen_igniter/lib/ggen_igniter/engine/graphlaw.ex` exists (wasmex-hosted,
  WASI store, typed fail-fast on missing artifact).
- `mix ggen_igniter.sync`'s `--help` documents `--engine graphlaw` and
  `--engine oxigraph,graphlaw` comparison mode.
- Wasm artifact present: `~/graphlaw/target/wasm32-wasip1/wasm/graphlaw_wasm.wasm`
  (6,657,549 bytes, 2026-09-30).

**The blocking hop is ash_pplan's own dep pin** (`mix.exs` line 6,
`@ggen_igniter_ref "0abed8a35db68c18bba6982b266dd7546c162d1c"`), which
predates the landing — `deps/ggen_igniter` resolves to 0abed8a, whose
registry lacks graphlaw. Real output from this lane's own run:

```
$ MIX_BUILD_ROOT=_build-w5 ./bin/ggen-engine-report --graphlaw
graphlaw: NOT LANDED in ggen_igniter Engine registry (W2/W3 pending)
exit=2
```

(Exit 2 = registered-not-in-this-dep-version, per the script's contract; the
in-script probe asks the *compiled dep* `GgenIgniter.Engine.valid_names()`,
which is the truthful per-consumer answer.)

**Differential validation: VALIDATED by W4** (results landed during this
lane's polling window; corpus `tmp/w4/results.json`, comparator
`tmp/w4/compare.py`, run through W4's own harness — NOT yet through
ash_pplan's pinned-dep `bin/ggen-engine-report --graphlaw`, which stays exit
2 until the pin moves). Real comparator summary (31 gates, exceeding the
planned 18):

```
ash-pplan-workflow-pack            010_capabilities.rq      48  48  OK
ash-pplan-workflow-pack            020_providers.rq         33  33  OK
... (11 workflow gates, 7 standing gates, 5 durable-tla gates,
     3 store-conformance gates, 2 durable-chaos gates, plus the
     ash-pplan pack's own gates)
--------------------------------------------------------------------------------------------------------------
TOTAL 31 gates | agree 31 | diverge 0
```

Oxigraph and graphlaw agree on row counts (and canonical row sets, per
W4's comparator) across all 31 ash_pplan pack gates. Independently, this
lane ran its own end-to-end fixture court inside `~/ggen_igniter`
(4 audit-trail gate queries, `--engine oxigraph,graphlaw` + engine-report +
actuation on oxigraph only): sync exit 0, 4/4 queries ok in both engines,
1 order-only warning. Remaining blocker is purely the
`@ggen_igniter_ref` pin transition (coordinator), after which
`bin/ggen-engine-report --graphlaw` becomes the standing consumer-side
court. The baseline `oxigraph,sparql` court remains GREEN (this lane's own run,
exit 0):

```
ggen-engine-report: GREEN — all packs agree
  queries: 3  blocking: 0  order-warnings: 3   (store-conformance)
  queries: 5  blocking: 0  order-warnings: 5   (durable-tla)
  queries: 2  blocking: 0  order-warnings: 2   (durable-chaos)
  ... same shape for ash-pplan, ash-pplan-workflow, ash-pplan-standing
```

See Also: [[dfcm-composition]] C20 · [[local-dfcm-manufacturing-engine]]
