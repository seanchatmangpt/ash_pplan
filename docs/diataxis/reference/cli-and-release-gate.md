# Reference: bin/ scripts and the release gate

Information-oriented reference for every executable in `bin/` and for the
release procedure defined in `AGENTS.md` (Release gate). Sources: each script
itself, `AGENTS.md`, and `.github/workflows/ci.yml`. Nothing here supersedes
`AGENTS.md`.

Standing vocabulary: `UNKNOWN | PARTIAL_ALIVE | ALIVE | BLOCKED | BUILD_BROKEN
| UNSUPPORTED | REFUSED_*`. A script's exit code observed in a session is
execution evidence for that session and subject only; generated source is not
execution evidence; a receipt is evidence, not authority.

## bin/ scripts

| script | language | mutates the tree? | writes |
|---|---|---|---|
| `bin/conform` | python3 | no | stdout only |
| `bin/conform-falsify` | python3 | no | stdout only |
| `bin/demonstrate` | bash | yes (regenerates `priv/`, rewrites `docs/demonstration.md`) | `docs/demonstration.md` |
| `bin/durable-stateright` | bash | no (builds only under `tmp/stateright-diff`) | stdout only |
| `bin/gate` | bash | yes (runs manufacture + `verify-package`, which leaves a tar) | stdout only |
| `bin/manufacture` | bash | yes | `lib/ash_pplan/catalog/` |
| `bin/manufacture-durable-chaos` | bash | yes | `test/durable/chaos/` |
| `bin/manufacture-durable-tla` | bash | yes | `priv/tla/durable/` |
| `bin/manufacture-examples` | bash | yes | `test/support/examples/`, `planning/examples/` |
| `bin/manufacture-standing` | bash | yes | `lib/ash_pplan/standing/` |
| `bin/manufacture-store-conformance` | bash | yes | `test/support/durable/store_conformance.ex` |
| `bin/manufacture-workflow` | bash | yes | `lib/ash_pplan/workflow/`, `test/courts/providers/` |
| `bin/observe-ontology` | python3 | no | stdout only |
| `bin/receipt` | bash | no | stdout (JSON) |
| `bin/verify-package` | bash | yes (`ash_pplan-<version>.tar` in repo root) | stdout only |

### bin/conform

Executable conformance gate (`bin/conform:1-93`). Validates `ontology.ttl`
against the admitted SHACL profile `ontology/shapes.ttl` with pyshacl
(`advanced=True`, `inference="none"`).

- Arguments: `--json` (machine-readable evidence on stdout; otherwise a
  human-readable report).
- Refusal conditions: any SHACL violation, or triple count below the floor
  `MINIMUM_TRIPLES = 110` (`bin/conform:29`). The floor also lives in
  `bin/observe-ontology:14`; a near-empty parse must not make downstream gates
  pass vacuously.
- Exit codes: `0` conformant and above floor; `1` violation or below floor;
  `2` rdflib/pyshacl not importable.
- Output keys (`--json`): `ontology`, `shapes`, `triples`,
  `minimum_triples`, `conforms`, `admitted`. `admitted = conforms AND
  floor_met` (`bin/conform:56-57`).

### bin/conform-falsify

Anti-vacuity court for the profile (`bin/conform-falsify:1-108`). Appends each
of 13 admitted counterexamples to the canonical ontology in memory, validates
the merged graph, and requires the profile to refuse every one. A profile that
admits any counterexample fails here.

Counterexamples (`bin/conform-falsify:25-67`): unadmitted projection standing;
duplicate projection order; duplicate projection source term; step preceded by
a step of another plan; step preceded by itself; step preceded by a non-step;
plan without a label; plan with no steps; step with two labels; projection
source term that is a literal; step using a variable from another plan; step
outside any plan; variable outside any plan.

- Arguments: none.
- Exit codes: `0` all 13 refused; `1` one or more ADMITTED (names them on
  stderr); `2` rdflib/pyshacl not importable.

### bin/demonstrate

One-command claims-vs-evidence chain (`bin/demonstrate:1-207`). Runs the full
evidence sequence in order — all seven manufacture scripts plus a
content-digest before/after comparison of tracked `priv/` files, conformance
gates, store-conformance tests (ETS + DETS negative controls), native TLA
court, JVM TLC court, chaos court (`ASH_PPLAN_CHAOS_RUNS=3`), durable
sub-courts (policy failover, counterfactual replay, migration refusal,
standing receipts, self-hosting loop), ledger/OCEL court, store differential
court, Stateright differential build, then `mix test --exclude
demonstration_court` — and renders one table row per claim: real command,
real exit code, evidence digest (last non-empty output line, first 140
chars), verdict `PASS | FAIL | SKIP`. `SKIP` requires an explicit reason;
there are no silent passes (`bin/demonstrate:56-61`).

- Arguments: none.
- Environment: `MIX_BUILD_ROOT` defaults `_build-dem`;
  `MANUFACTURE_MANIFEST_ROOT` defaults `tmp/mf-dem-<pid>`; optional
  `ASH_PPLAN_NATIVE_TLA` (or a pinned `tools/tla-rs` binary, tla-rs v0.11.1).
- Serialization: holds a lock directory `tmp/.demonstrate-lock` (60 x 2s
  spin) so concurrent/nested runs cannot race the regeneration phase
  (`bin/demonstrate:20-31`).
- Writes: `docs/demonstration.md` (tracked; a receipt document, not a CI
  attestation — `bin/demonstrate:198-199`).
- Exit codes: `0` zero FAIL rows; `1` any FAIL; `3` lock not acquired
  (`REFUSED` on stderr).
- Bounded: chaos runs kept small; full run stated to stay well under 10
  minutes on a warm build (`bin/demonstrate:8-9`).

### bin/durable-stateright

Differential check of the generated Stateright model (`bin/durable-stateright:1-49`).
Copies `priv/tla/durable/stateright/model.rs` (produced by
`bin/manufacture-durable-tla`) into a scratch cargo project
`tmp/stateright-diff` and runs `cargo test`. Verdicts must agree with the
tla-rs court (`test/durable/native_tla_court_test.exs`): both encode the same
ontology individuals.

- Scope: the generated model is currently a vocabulary witness (states,
  actions, guards, properties); full state-space exploration needs the
  `stateright` crate, whose 0.18 dependency tree does not compile on current
  Rust toolchains, so the witness builds dependency-free
  (`bin/durable-stateright:9-14`).
- Arguments: none. Requires `cargo`.
- Anti-vacuity: requires `1 passed` in the cargo log — a stripped test module
  fails the script (`bin/durable-stateright:47`).
- Exit codes: `0` PASS; `1` model missing, `cargo test` failure, or
  vocabulary test did not run; `2` cargo not on PATH (caller
  `bin/demonstrate` records a reasoned SKIP).

### bin/gate

Runs the release gate locally in CI order (`bin/gate:1-87`). Step names match
CI so "passes locally" and "passes in CI" cannot drift silently. Steps that
cannot run are reported `SKIP`, never passed; the gate is only fully observed
when every step ran, and CI on the exact head remains the authority
(`bin/gate:4-7`).

Steps, in order (`bin/gate:47-73`):

1. `conform` — skipped without python rdflib+pyshacl
2. `conform-falsify` — skipped without python rdflib+pyshacl
3. `ggen-ecosystem parses ontology.ttl` — `docker run` of the image digest
   taken as the first `sha256:...` match in `ecosystem.lock.toml`
   (`bin/gate:55-59`); skipped without a running docker daemon
4. `mix deps.get --check-locked`
5. `mix hex.audit`
6. `mix deps.unlock --check-unused`
7. `mix format --check-formatted`
8. `mix compile --warnings-as-errors`
9. `mix check`
10. `manufacture leaves generated source unchanged` — runs all seven
    manufacture scripts then `git diff --exit-code` plus a porcelain-empty
    check over `lib/ash_pplan/catalog lib/ash_pplan/workflow lib/ash_pplan/providers planning/examples test/courts/providers
    test/support/examples priv/tla` (`bin/gate:33-45`)
11. `verify-package`; then removes `./ash_pplan-*.tar` (`bin/gate:72`)
12. `receipt`

- Arguments: none.
- Exit codes: `0` (with `GATE PARTIAL` verdict) if everything that could run
  passed but some steps were skipped; `0` with `GATE PASSED locally` when no
  skips and no failures; `1` (`GATE FAILED`) on any failing step. A local
  pass never grants standing: "CI on the exact head still grants standing"
  (`bin/gate:86`).

### bin/manufacture

Regenerates the core projection catalogs (`bin/manufacture:1-23`):

- `mix ggen_igniter.sync` (engine `oxigraph`, pack
  `priv/ggen/ash-pplan-pack`) renders
  `lib/ash_pplan/catalog/projection_catalog.ex` from
  `templates/projection_catalog.ex.eex` and
  `lib/ash_pplan/catalog/plan_catalog.ex` from
  `templates/plan_catalog.ex.eex`.
- `mix format` on both outputs.
- Then delegates to
  `priv/ggen/ash-pplan-workflow-pack/bin/manufacture-workflow`
  (`bin/manufacture:23`) — i.e. `bin/manufacture` is a superset of
  `bin/manufacture-workflow`.

The manufactured source (`lib/ash_pplan/catalog/`, `lib/ash_pplan/workflow/`,
`lib/ash_pplan/providers/`) is generated by ggen_igniter; never repair it
directly — repair `ontology.ttl`, the SPARQL gate, or the EEx template and
regenerate (`AGENTS.md`, Manufacture).

### bin/manufacture-workflow

Wrapper that execs
`priv/ggen/ash-pplan-workflow-pack/bin/manufacture-workflow` (delegating
wrappers: `bin/manufacture-workflow:1-3`, same pattern for standing,
store-conformance and durable-chaos). The pack script runs the GENERIC
workflow recipes serially, one template per sync
(`priv/ggen/ash-pplan-workflow-pack/bin/manufacture-workflow:1-26`):

- `capability_catalog.ex.eex` -> `lib/ash_pplan/workflow/capability_catalog.ex`
- `provider.ex.eex` with `--for-each providers` ->
  `lib/ash_pplan/providers/<provider_id>.ex`
- `provider_index.ex.eex` -> `lib/ash_pplan/providers/index.ex`
- `court_provider.exs.eex` with `--for-each providers` ->
  `test/courts/providers/<provider_id>_provider_court_test.exs`

All syncs use `--on-stale prune` and a manifest dir
`${MANUFACTURE_MANIFEST_ROOT:-tmp}/mf-<name>`. The shipped ontology declares
no workflows, and a for-each over zero rows is refused, so workflow/hddl/court
recipes run only in `bin/manufacture-examples`
(`priv/ggen/ash-pplan-workflow-pack/bin/manufacture-workflow:21-22`).

### bin/manufacture-examples

Manufactures TEST-SUPPORT example output, never shipped in `lib/`
(`bin/manufacture-examples:1-44`). Sets `MIX_ENV=test` (workflow modules live
in `test/support`, compiled only in `:test`), merges `ontology.ttl` with
`test/support/examples/ontology/examples.ttl` into `tmp/examples-ontology.ttl`
via rdflib, then runs five workflow-pack recipes over the merged graph with
`--for-each`:

| recipe | output |
|---|---|
| `provider.ex.eex` | `test/support/examples/providers/<provider_id>.ex` |
| `workflow.ex.eex` | `test/support/examples/workflows/<name>.ex` |
| `hddl_file.hddl.eex` | `planning/examples/<name>.hddl` |
| `court_workflow.exs.eex` | `test/support/examples/courts/<name>_workflow_court_test.exs` |
| `court_provider.exs.eex` | `test/support/examples/courts/<provider_id>_provider_court_test.exs` |

Pack: `test/support/ggen/examples-pack`; templates from
`priv/ggen/ash-pplan-workflow-pack/templates/`. Outputs are `mix format`-ed.

### bin/manufacture-standing

Wrapper execing `priv/ggen/ash-pplan-standing-pack/bin/manufacture-standing`,
which renders from the standing ontology
(`priv/ggen/ash-pplan-standing-pack/bin/manufacture-standing:1-16`):

- `receipt.ex.eex` -> `lib/ash_pplan/standing/receipt.ex`
- `chain.ex.eex` -> `lib/ash_pplan/standing/chain.ex`

### bin/manufacture-store-conformance

Wrapper execing
`priv/ggen/ash-pplan-store-conformance-pack/bin/manufacture-store-conformance`,
rendering `store_conformance.ex.eex` ->
`test/support/durable/store_conformance.ex`. Manifest lane defaults to
`store-conformance`, overridable with `MF_LANE`
(`priv/ggen/ash-pplan-store-conformance-pack/bin/manufacture-store-conformance:9`).
The generated module is the store-conformance suite; a new durable-store
backend must pass it (`bin/manufacture-store-conformance`) before use
(`AGENTS.md`, Durable store fence).

### bin/manufacture-durable-tla

Generates the durable-protocol TLA+ module, TLC cfg, trace reader and
Stateright differential model from the ontology
(`bin/manufacture-durable-tla:1-20`). Pack
`priv/ggen/ash-pplan-durable-tla-pack`; four templates:

| template | output |
|---|---|
| `durable.tla.eex` | `priv/tla/durable/DurableProtocol.tla` |
| `durable.cfg.eex` | `priv/tla/durable/DurableProtocol.cfg` |
| `transitions.exs.eex` | `priv/tla/durable/transitions.exs` |
| `stateright_model.rs.eex` | `priv/tla/durable/stateright/model.rs` |

Environment: `MIX_BUILD_ROOT` defaults `_build-m2`;
`MANUFACTURE_MANIFEST_ROOT` defaults `tmp/mf-m2-<template>`;
`VERIFY_CWD` overridable (all manufacture scripts pass `--verify-cwd`).

### bin/manufacture-durable-chaos

Wrapper execing
`priv/ggen/ash-pplan-durable-chaos-pack/bin/manufacture-durable-chaos`, which
generates the model-based chaos suites from the chaos pack's own ontology
(`priv/ggen/ash-pplan-durable-chaos-pack/bin/manufacture-durable-chaos:1-17`):

| recipe | output |
|---|---|
| `invariant_property.exs.eex` (`--for-each invariants`) | `test/durable/chaos/<invariantId>_property_test.exs` |
| `kill_matrix.exs.eex` (`--for-each kill_phases`) | `test/durable/chaos/kill_<phaseId>_test.exs` |

Environment: `MIX_BUILD_ROOT` defaults `_build-m3`.

### bin/observe-ontology

Parses `ontology.ttl` and prints `ONTOLOGY_TRIPLES=<n>` (`bin/observe-ontology:1-25`).
Exists as a script so the same file can run inside the pinned ggen-ecosystem
container (release gate item 3) and anywhere rdflib is installed; a change to
it is a reviewed diff (`bin/observe-ontology:4-7`).

- Arguments: none.
- Exit codes: `0` at or above the 110-triple floor; `1` below floor
  (`REFUSED` on stderr).

### bin/receipt

Emits a content-addressed release receipt bound to the exact Git head
(`bin/receipt:1-18`). Resolves `git rev-parse --verify 'HEAD^{commit}'`, then
runs `mix run --no-start` with `ASH_PPLAN_RELEASE_HEAD=<sha>`, calling
`AshPPlan.ReleaseReceipt.observe/0` and `AshPPlan.ReleaseReceipt.to_json/0`;
JSON goes to stdout. The semantic/manufactured digests are compile-time
observations; the Git commit identity binds them to the exact tree and
history position CI checked out (`bin/receipt:3-5`).

- Arguments: none. Writes nothing to the tree.
- Exit codes: `0` on emitted JSON; nonzero on any failure (`set -euo
  pipefail`, e.g. detached/unresolvable HEAD).

### bin/verify-package

Proves the built package compiles as a consumer would receive it
(`bin/verify-package:1-40`). `mix hex.build` only asserts a tarball can be
produced; it does not compile the result, so a compile-time input missing from
the package `files:` list would ship a package that cannot build.

Procedure: `mix compile`; read the version from `AshPPlan.version()`; `mix
hex.build` producing `ash_pplan-<version>.tar`; unpack the tar and its
`contents.tar.gz` into a `mktemp` directory; copy the already-fetched `deps/`
and `mix.lock` (this gate is about the package's own contents, not
re-resolution); `MIX_ENV=prod mix compile --warnings-as-errors` in the
scratch directory.

- Arguments: none. Leaves `ash_pplan-<version>.tar` in the repo root
  (`bin/gate` removes it; `bin/verify-package` itself does not).
- Exit codes: `0` package compiles from its own contents; nonzero on any
  failure (`set -euo pipefail`).

## Shared environment variables

| variable | consumers | meaning |
|---|---|---|
| `MIX_BUILD_ROOT` | manufacture-durable-tla (`_build-m2`), durable-chaos (`_build-m3`), demonstrate (`_build-dem`), durable-stateright | per-invocation build isolation |
| `MANUFACTURE_MANIFEST_ROOT` | all manufacture scripts (default `tmp/mf-*`), demonstrate (`tmp/mf-dem-<pid>`) | ggen_igniter reconciliation-manifest root |
| `VERIFY_CWD` | all manufacture scripts | `--verify-cwd` passed to `mix ggen_igniter.sync` |
| `MF_LANE` | manufacture-store-conformance | manifest lane name (default `store-conformance`) |
| `MIX_ENV` | manufacture-examples forces `test`; verify-package forces `prod` in the scratch compile | environment for the mix invocation |
| `ASH_PPLAN_NATIVE_TLA` | demonstrate, native TLA court test | path to a native tla-rs binary (pinned v0.11.1); falls back to `tools/tla-rs` |
| `ASH_PPLAN_REQUIRE_TLC` | TLC court tests | when set (CI sets `1`), TLC unavailability raises instead of skipping |
| `ASH_PPLAN_CHAOS_RUNS` | demonstrate (sets `3`), chaos suites | chaos iteration count |
| `ASH_PPLAN_RELEASE_HEAD` | receipt | exact commit SHA bound into the receipt |

## Release gate (AGENTS.md, canonical 10 items)

All items must pass for the exact release head (`AGENTS.md`, Release gate).
`bin/gate` and CI run the same steps in the same order; CI additionally runs
`mix deps.get --check-locked` and `mix deps.unlock --check-unused`.

| # | item | command | what it proves |
|---|---|---|---|
| 1 | Ontology conforms | `./bin/conform` | the canonical ontology satisfies every constraint in the admitted profile `ontology/shapes.ttl`, and is above the 110-triple emptiness floor |
| 2 | Profile refuses | `./bin/conform-falsify` | the profile is not vacuous: all 13 admitted counterexamples are refused; a profile that cannot refuse is not evidence |
| 3 | Pinned producer parses | docker: pinned ggen-ecosystem image runs `python3 bin/observe-ontology` | the ggen version that will consume the ontology parses it and sees the triple floor |
| 4 | No retired/advised deps | `mix hex.audit` | no resolved dependency is retired or advisory-listed (live advisory data — hence the weekly CI sweep) |
| 5 | Formatted | `mix format --check-formatted` | tree is formatter-clean under the imported Ash-extension contracts |
| 6 | Compiles warning-free | `mix compile --warnings-as-errors` | public-contract drift in first-class dependencies falsifies at compile time |
| 7 | Check | `mix check` | the full verify ladder (format, compile, tests,credo/dialyzer-classes) passes |
| 8 | Manufacture is idempotent | `./bin/manufacture` (+ six sibling scripts) then generated-diff verification | regenerating every pack leaves the committed projections byte-identical — generated source is projection, not an editing surface |
| 9 | Package compiles from its own contents | `./bin/verify-package` | a consumer receiving the hex tarball can build it; the package `files:` list is complete |
| 10 | Head receipted | `./bin/receipt` | the exact head is observed and emitted as a JSON release receipt |

Item 8's generated-path set: `lib/ash_pplan/catalog`, `lib/ash_pplan/workflow`,
`lib/ash_pplan/providers`, `planning/examples`,
`test/courts/providers`, `test/support/examples`, `priv/tla`
(`bin/gate:33`; `.github/workflows/ci.yml:158`).

Receipt semantics (`AGENTS.md`): a release receipt is evidence, not
authority. It grants no standing on its own; a green exact-head observation is
what grants standing, and the receipt records which head that was.

## CI wiring (.github/workflows/ci.yml)

Trigger: `pull_request`, `push` to `main`, tags `v*`, weekly schedule
(`23 5 * * 1`, so `mix hex.audit` against live advisory data can turn red
without a code change), and `workflow_dispatch` (`ci.yml:6-15`). Permissions:
`contents: read` only. Third-party actions are pinned to full commit SHAs
(`ci.yml:29-31`).

Every job checks out `github.event.pull_request.head.sha || github.sha` — the
exact head, never the synthetic PR merge commit — so what is observed is what
would be released (`ci.yml:3-5,40,58,93`).

Jobs:

| job | contents | notes |
|---|---|---|
| `semantic` | pull pinned image, `ggen --version`, `observe-ontology` in-container | image pinned by digest `sha256:917eb72a...`; comment records it was observed at ash_pplan v26.10.1 and is not confirmed against ggen-ecosystem v26.9.29, whose own image is BLOCKED awaiting republish (`ci.yml:24-27`) |
| `conformance` | python 3.12 with pinned `rdflib==7.6.0 pyshacl==0.40.1`; `./bin/conform`; `./bin/conform-falsify` | parallel to `semantic`; neither feeds the other (`ci.yml:70-71`) |
| `elixir` (matrix: `current` 1.18.4 = release toolchain, `floor` 1.17.3 = declared `~> 1.17` floor) | deps check-locked, `hex.audit`, `deps.unlock --check-unused`, format (primary), `mix compile --warnings-as-errors`, `mix check` (primary, `ASH_PPLAN_REQUIRE_TLC=1`), `mix test` (floor), all seven manufacture scripts + generated-diff verification (primary), `./bin/verify-package` (primary), `./bin/receipt > release-receipt.json` (primary) | toolchains: Erlang/OTP 27.3, Rust stable, Temurin 21; tla2tools 1.7.4 fetched with SHA-256 check (`ci.yml:107-114`); `release-receipt.json` uploaded as the `release-receipt` artifact (`ci.yml:168-172`) |
| `release-gate` | join job: `if: always()`, `needs: [semantic, conformance, elixir]`; exits nonzero (`release gate REFUSED`) unless every need is `success` | the one check to require in branch protection; runs even when an upstream job failed or was skipped (`ci.yml:174-193`) |

The `concurrency` group cancels in-progress runs only for pull requests
(`ci.yml:20-22`).

## Local vs CI

`bin/gate` exists so local and CI cannot drift: identical step names, same
order. Two structural differences remain and are explicit in the scripts:

- Locally missing toolchains (python SHACL deps, docker daemon, java, cargo,
  native TLA binary) produce `SKIP` rows/verdicts, never passes; the gate
  verdict is `GATE PARTIAL` and standing still requires the exact-head CI run
  (`bin/gate:81-86`).
- `bin/demonstrate` is a local evidence receipt over the wider court chain
  (chaos, TLA/Stateright, durable sub-courts) that CI does not run as such;
  it states on its own output that it is never run for the CI receipt
  (`bin/demonstrate:198-199`).
