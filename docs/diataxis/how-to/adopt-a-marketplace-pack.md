# How to adopt a ggen-marketplace pack

Goal: you want to consume a marketplace pack's ontology and gates inside your
repo without adding ggen-marketplace as a dependency: vendor the pack files at
file level, lock them by sha256, and verify the lock on every sync.

Three working in-tree patterns are documented here:

- **File-level vendoring with a lock** (`~/ex4pm/priv/ggen/vendor/`) — copies
  chosen files out of a marketplace checkout into your tree, then writes a
  byte-deterministic lock.
- **Merged-ontology pack** (`priv/ggen/ash-pplan-workflow-pack` in this repo) —
  the pack ships a core ontology; application individuals are merged in from
  a test-support ontology at manufacture time.
- **Rows-translation pilot** (`priv/ggen/ash-pplan-chaos-pack-acp-rows.ttl`) —
  consuming ash_pplan's own marketplace trio by re-declaring in-repo
  individuals in the pack's consumer-facing namespace. See
  [Pattern C](#pattern-c-the-marketplace-trio--consuming-your-own-packs-namespace-pilot).
  (Superseded 2026-10-04: the rows file was deleted; the vendored
  `ash-pplan-chaos` pack adoption in `ggen.toml` `[packs.ash-pplan-chaos]`
  replaces it.)

## Prerequisites

- A local checkout of `ggen-marketplace` (default `$HOME/ggen-marketplace`).
- The consuming repo compiles (`mix compile`).
- `python3` on `PATH` (all three patterns use it; no other runtime deps).
- Lane discipline: use a private build root, e.g.
  `MIX_BUILD_ROOT=_build-adopt2 bin/ggen-doctor`.

## Pattern A: file-level vendoring with a sha256 lock

Source: `~/ex4pm/priv/ggen/vendor/sync.sh` and `PACKS.lock.json`.

`sync.sh` vendors two artifacts per pack: the pack's `ontology.ttl` and its
`gates/*.rq` files, then rewrites `PACKS.lock.json` and `provenance.ttl`
deterministically (no timestamps): same pack bytes + same source git sha ⇒
byte-identical lock.

### Step 1: Copy the pack files

```sh
# run inside the ex4pm checkout (the script lives there, not in this repo):
priv/ggen/vendor/sync.sh [path-to-ggen-marketplace]   # default ~/ggen-marketplace
```

For each pack in the script's `packs=()` array it:

1. Copies `packs/<p>/ontology.ttl` to `<vendored>/<p>.ontology.ttl`.
2. Copies `packs/<p>/gates/*.rq` to `<vendored>/gates/<p>/`.
3. Reads `pack.toml` for the pack version and `git status` for dirtiness.

> **`verify/` travels with `gates/`.** A pack's violations-naming companions
> (`verify/*.unbound.rq`, zero rows = pass) belong to the same verification
> surface as its `gates/*.rq` (>= 1 row = pass). A violations query under
> `gates/` is doubly wrong — scores `:pass` exactly when the ontology is
> broken — so the two directories are the contract together. ex4pm's
> `sync.sh` vendors `gates/` only today; when the pack you adopt ships
> `verify/`, vendor it beside the gates and add it to the lock, so the
> consumer can run `mix ggen_igniter.verify` against the vendored pack too.
> Convention reference:
> [Run the ggen gates](run-the-ggen-gates.md#the-gates-vs-verify-convention).

### Step 2: Write the lock

A Python block inside `sync.sh` rewrites `PACKS.lock.json`:

The lock's top-level keys are `schema` (`"ex4pm.ggen.vendor-lock/v1"`),
`source_repo`, `source_git_sha` (the marketplace checkout's HEAD sha), `packs`,
and `generated` (the `provenance.ttl` entry with its own sha256). Each entry in
`packs` carries the pack `name`, `version` (from `pack.toml`), the
`source_tree_dirty` flag, and a `files` array whose entries are per-file
`path`, `source_path`, and `sha256`. Do not hand-edit the lock; it is
generated.

### Step 3: Verify the lock on every sync

```sh
mix ex4pm.ggen.verify_determinism --all
```

`verify_determinism` refuses when any vendored file's sha256 differs from
`PACKS.lock.json`. This is the falsifier for "the vendored pack bytes are
exactly what the lock claims."

## Pattern B: merged-ontology pack

Source: `priv/ggen/ash-pplan-workflow-pack` in this repo, driven by
`priv/ggen/ash-pplan-workflow-pack/bin/manufacture-workflow` and
`bin/manufacture-examples`.

The shipped ontology in the pack declares no Workflow/Task/Method individuals
(for-each over zero rows is refused by ggen_igniter sync). Application-specific
workflows live in `test/support/examples/ontology/examples.ttl`; the manufacture
loop merges the two graphs before sync:

```sh
# As performed by bin/ggen-verify for the same reason:
python3 - "$merged" <<'PY'
import sys
from rdflib import Graph
g = Graph()
g.parse("ontology.ttl", format="turtle")
g.parse("test/support/examples/ontology/examples.ttl", format="turtle")
g.serialize(destination=sys.argv[1], format="turtle")
PY
```

(See the real invocation in `bin/ggen-verify`, which builds the identical merge
into `tmp/ggen-verify/workflow-merged-ontology.ttl` so the pack is verified
against the same merged ontology the manufacture loop consumes.)

## Pattern C: the marketplace trio — consuming your own pack's namespace (pilot)

ash_pplan publishes generalizations of its own manufacturing machinery to
ggen-marketplace — the trio `ash-pplan-chaos-pack` (`acp:`), the
`ash-pplan-store-conformance-pack` (`scb:`) and the
`ash-pplan-protocol-court-pack` (`pcp:`) — and those packs deliberately speak a
consumer-facing vocabulary, not the in-repo one. The IRI divergence is real and
intentional:

- in-repo manufacturing source: `priv/ggen/ash-pplan-durable-chaos-pack/`,
  namespace `dc:` = `https://w3id.org/ash-pplan/durable-chaos#`
  (`bin/manufacture-durable-chaos` is the manufacturer);
- marketplace pack: `packs/ash-pplan-chaos-pack/`, namespace `acp:` =
  `https://seanchatmangpt.github.io/packs/ash-pplan-chaos#` (class vocabulary:
  `acp:Harness` / `acp:Invariant` / `acp:KillPhase`); the store-conformance and
  protocol-court packs diverge the same way (`scb:` / `pcp:` under the same
  `seanchatmangpt.github.io/packs/` base).

The bridge is a rows-translation file, not a namespace rewrite at sync time:
re-declare the in-repo `dc:` individuals in the marketplace pack's `acp:`
namespace as an individuals-only rows file, keeping the pack's class
vocabulary where it lives. The pilot rows file is
`priv/ggen/ash-pplan-chaos-pack-acp-rows.ttl` (deleted 2026-10-04,
superseded by the vendored `ash-pplan-chaos` pack adoption; see
`ggen.toml` `[packs.ash-pplan-chaos]`): 1 `acp:Harness` (real
`AshPPlan.Test.Chaos.*` module names, not specimens), 6 `acp:Invariant`
(anchored on `acp:order`, not `acp:seed`), 4 `acp:KillPhase` — exactly the
individuals the pack's gates and `verify/cardinality.json` contracts expect,
matching the specimen counts the pack was verified against (pack.toml).

**Pilot status (v26.10.2): rows file landed, wiring not.** The rows file is
NOT referenced by `ggen.toml` yet, so nothing renders from it; the in-repo
`dc:` ontology remains the manufacturing source. When wired (per the pack
README's "Consumer integration steps" step 1), the `acp:` rows replace the
marketplace pack's specimen rows and the trio renders consumer suites from
ash_pplan's own individuals. The rows file is generated from the `dc:` source
by rdflib translation (generate, don't hand-write): regenerate rather than
editing values in place.

## Lock discipline summary

- The lock file is generated, never hand-edited.
- A version bump or pack change must go through `sync.sh` (or the manufacture
  scripts) so the lock stays byte-deterministic.
- Verification refuses on any sha256 mismatch — fail-closed.

## FM-PACK-005 placeholder convention

Every registered pack must ship `templates/*.tmpl` (ggen floor). If the
marketplace source has no `.tmpl`, add an inert `placeholder.tmpl`:

```text
---
to: "tmp/ggen-law-placeholder.txt"
mode: file
---
placeholder template satisfying ggen FM-PACK-005 (templates/*.tmpl floor); renders to tmp/ only.
```

It renders to `tmp/ggen-law-placeholder.txt` only — inert by construction.
`priv/ggen/vendor/sync.sh` carries a re-add hook that restores the placeholder
after every resync (only when upstream ships no `.tmpl` of its own; an
upstream placeholder must win over ours), so you never hand-re-add it.

## Offender-gate re-home convention (ADR 0010)

Offender-shaped gates — pass means 0 rows — live in `verify/*.unbound.rq`,
never `gates/`. When adopting a pack whose gates are offender-shaped, re-home
contract-first-then-move in the same change and cite
`ECO-GATE-CONVENTION-DECISION.md`. `sync.sh` patch 2g re-materializes the
re-home plus the both-way witnesses after every sync (vendoring drops them —
the 2026-10-04 wipe), and retires stale `gates/` copies once their verify
twin exists.
