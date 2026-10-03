# How to run the ggen gates

Goal: you changed an ontology, template, gate query, or generated file and want
the fail-closed verification surface to confirm the generated tree is exactly
what the pack manufactures — or refuse when it is not.

Four wrappers cover the four failure classes: pack health, fact binding,
receipt replay / drift, and engine agreement. All exit nonzero on their named
failure and zero when green.

## Prerequisites

- This repo checked out and `mix compile` clean.
- Lane discipline: give each gate a private build root via `MIX_BUILD_ROOT`
  (e.g. `MIX_BUILD_ROOT=_build-adopt2`), and a private manifest root via
  `MANUFACTURE_MANIFEST_ROOT` where noted.
- `python3` and `rdflib` on the interpreter used by the wrappers.

## bin/ggen-doctor — pack preflight

```sh
MIX_BUILD_ROOT=_build-adopt2 bin/ggen-doctor            # all six packs
MIX_BUILD_ROOT=_build-adopt2 bin/ggen-doctor ash-pplan-standing-pack
```

Runs `mix ggen_igniter.doctor --pack-dir priv/ggen/<pack>` per pack and prints
a per-pack summary. Gates pack health: parseable `ontology.ttl`, gate queries,
stale NIFs.

- Exits 1 only on real check failures. The doctor's project-level
  version-literal check cannot pass on a consumer repo, so the wrapper filters
  exactly one message (`could not find a simple \`version: "..."` literal in`)
  and counts it as N/A skipped; any other `✘` line fails.
- NIF fast path: when `priv/native/ggen_graph_nif.so` is newer than every
  `.rs` source the real Rust build is skipped. A cold CI runner does the full
  cargo build once — budget for it.

## bin/ggen-verify — fail-closed pack verification

```sh
bin/ggen-verify
GGEN_VERIFY_PACKS="ash-pplan-pack" bin/ggen-verify   # subset
```

Runs `mix ggen_igniter.verify --pack ... --json-envelope` for every pack that
ships a `gates/` directory (default six). Gates fact binding: unbound facts and
gate-cardinality breaches fail (exit 1); JSON envelopes land in
`tmp/ggen-verify/`.

### The gates/ vs verify/ convention

Every pack separates two query families, and the directory IS the contract:

- `gates/*.rq` — admission/naming queries. At least one row = pass (the
  required ontology shape/individual is present); zero rows = fail.
- `verify/*.unbound.rq` — violations-naming (inverted companion) queries.
  Zero rows = pass; each row names a `?subject ?missing_property` census
  finding. Per-gate row contracts live in `verify/cardinality.json`.

A violations-naming query placed under `gates/` is doubly wrong: it scores
`:pass` exactly when the ontology is BROKEN, and `mix ggen_igniter.sync`
flattens a one-row query's columns into top-level template bindings. This is
ggen_igniter's own documented law (`mix ggen_igniter.verify` moduledoc, "Why
verify/ and not gates/"); the standing pack's `080_ladder_no_skipped_states`,
`130_seal_once` and `140_parent_hash_closure` companions moved gates/ →
verify/ under it in v26.10.2.

The `ash-pplan-workflow-pack` is verified against the merged ontology (core +
`test/support/examples/ontology/examples.ttl`) for the reason given in
[Adopt a marketplace pack](adopt-a-marketplace-pack.md).

## bin/ggen-replay-court — receipt replay and drift preview

```sh
bin/ggen-replay-court                     # receipt-replay court
bin/ggen-replay-court --dry-run-preview   # generated-tree drift preview
```

Two modes:

- **Receipt replay (default)**: finds the freshest receipt per recipe key under
  `MANUFACTURE_MANIFEST_ROOT` (default `tmp/mf`), runs the official
  `mix ggen_igniter.replay <receipt> --verify-only` on each, and exits 1 on any
  reported drift.
- **`--dry-run-preview`**: runs every manufacture entry script with
  `MANUFACTURE_DRY_RUN=1` and expects `planned: skip ... (unchanged)` for every
  recipe. Any `planned: write|inject|prune` line is drift — exit 1.

Two disclosed behaviors worth knowing before you chase a red run:

- **Format-only drift whitelist**: receipt post-run hashes finalize inside
  `mix ggen_igniter.sync`, before the manufacture scripts' trailing
  `mix format`. Today format is a verified byte-level no-op on the generated
  tree; if a template regressed to emitting unformatted output, the court
  recomputes the receipt hash over whitespace-normalized bytes and whitelists
  whitespace-only differences, never real ones.
- **Phantom-drift remap**: receipts canonicalize `files` against
  `--manifest-dir`, so with a manifest root different from the project root the
  official replay would hash absent paths and report phantom drift. The court
  remaps receipt files to real project paths before replaying.

## bin/ggen-engine-report — engine agreement

```sh
MIX_BUILD_ROOT=_build-adopt3 bin/ggen-engine-report
MIX_BUILD_ROOT=_build-adopt3 bin/ggen-engine-report --graphlaw
```

Runs one representative recipe per pack (highest oxigraph row-count template,
measured per pack) twice with `--engine oxigraph,sparql` and
`--engine-report` files, parses each report for engine disagreements, and exits
1 on any. Zero actuation risk by construction: actuation uses only the primary
engine (oxigraph), output is confined to `tmp/adopt3-out/`, manifests under
`tmp/mf-v3`, isolated build root `_build-adopt3` — never
`lib/ash_pplan/generated`.

Cells are canonicalized to string form before comparison (oxigraph returns
`"12"` where sparql returns `12` for the same `xsd:integer`); raw-row compare
would false-red every numeric column.

With `--graphlaw` (or `GRAPH_ENGINE=graphlaw`) the comparison becomes
`oxigraph,graphlaw`. Exit codes are distinguishable: `0` green, `1` real
disagreement, `2` the ggen_igniter dep does not register `graphlaw` yet
("graphlaw: NOT LANDED").

## Which gate when

| Symptom / question | Gate |
|---|---|
| Is the pack well-formed (ontology parses, gates run, NIF current)? | `ggen-doctor` |
| Does every ontology fact bind, and does each gate meet its cardinality contract? | `ggen-verify` |
| Do the receipts still replay byte-identically against disk? | `ggen-replay-court` |
| Would a manufacture run change any generated file right now? | `ggen-replay-court --dry-run-preview` |
| Do two query engines agree on the same ontology/gates? | `ggen-engine-report` |

## Invocation evidence

Background and feature coverage: `notes/ggen-igniter-feature-audit.md`.
The wrappers are exercised in CI and by the adoption lanes; every failure mode
described here is the one implemented in the script on disk — no flag or exit
code is documented that the script does not implement.
