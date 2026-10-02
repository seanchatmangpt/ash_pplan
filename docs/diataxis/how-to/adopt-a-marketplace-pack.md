# How to adopt a ggen-marketplace pack

Goal: you want to consume a marketplace pack's ontology and gates inside your
repo without adding ggen-marketplace as a dependency: vendor the pack files at
file level, lock them by sha256, and verify the lock on every sync.

Two working in-tree patterns are documented here:

- **File-level vendoring with a lock** (`~/ex4pm/priv/ggen/vendor/`) — copies
  chosen files out of a marketplace checkout into your tree, then writes a
  byte-deterministic lock.
- **Merged-ontology pack** (`priv/ggen/ash-pplan-workflow-pack` in this repo) —
  the pack ships a core ontology; application individuals are merged in from
  a test-support ontology at manufacture time.

## Prerequisites

- A local checkout of `ggen-marketplace` (default `$HOME/ggen-marketplace`).
- The consuming repo compiles (`mix compile`).
- `python3` on `PATH` (both patterns use it; no other runtime deps).
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
priv/ggen/vendor/sync.sh [path-to-ggen-marketplace]   # default ~/ggen-marketplace
```

For each pack in the script's `packs=()` array it:

1. Copies `packs/<p>/ontology.ttl` to `<vendored>/<p>.ontology.ttl`.
2. Copies `packs/<p>/gates/*.rq` to `<vendored>/gates/<p>/`.
3. Reads `pack.toml` for the pack version and `git status` for dirtiness.

### Step 2: Write the lock

A Python block inside `sync.sh` rewrites `PACKS.lock.json`:

The lock's top-level keys are `schema` (`"ex4pm.ggen.vendor-lock/v1"`),
`source_repo`, `source_git_sha` (the marketplace checkout's HEAD sha), and
`packs` — the `packs` array carries per-file `path`, `source_path`, `sha256`,
the pack version, and the `dirty` flag. Do not hand-edit the lock; it is
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

## Lock discipline summary

- The lock file is generated, never hand-edited.
- A version bump or pack change must go through `sync.sh` (or the manufacture
  scripts) so the lock stays byte-deterministic.
- Verification refuses on any sha256 mismatch — fail-closed.
