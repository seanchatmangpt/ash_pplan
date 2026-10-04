# ECO Upstream Workflow-Pack Promotion + ash-extension-core-pack 0.1.2 (upstream half)

- Date: 2026-10-04
- Repo: /Users/sac/ggen-marketplace
- Branch: `errc-promote-workflow-pack-and-ashext-template` (local only, NO PUSH)
- Base: `main` @ `503af6c27cef7838dcd82755ab2fe6a44f9eb6a2`
- Commits:
  - `f173b150c` feat(pack): publish ash-pplan-workflow-pack 26.10.3 (E2 runbook step 1)
  - `e6496435b` fix(pack): ash-extension-core-pack 0.1.2 — port consumer vendor-time patch into the template
- Consumer-side lane doc: this file (single receipt for both promotions)

## Contents

### 1. packs/ash-pplan-workflow-pack/ (new, verbatim copy)

Verbatim copy of the in-tree consumer pack
`ash_pplan/priv/ggen/ash-pplan-workflow-pack/` as of 2026-10-04. NOTE: the
consumer's root `ontology.ttl` R2-sync was in flight on a concurrent lane, so
this is the pre-R2-sync pack bytes; the consumer must re-sync after the R2
lane lands (see post-merge steps). pack.toml, ontology.ttl, gates/ (15 .rq),
templates/ (9 .eex), verify/ (15 unbound companions + cardinality.json),
bin/manufacture-workflow. No semantic adjustments.

### 2. packs/ash-extension-core-pack/ 0.1.1 → 0.1.2

The vendor lock (`priv/ggen/vendor/PACKS.lock.json`) marks exactly one file
`patched: true`: `templates/ash_reactor_extended_adapter.ex.eex`. The
consumer's vendor-time patch (GENERATED header + multi-line ops list
replacing the single-line `def ops, do: inspect(...)` that mix format kept
rewriting) is ported verbatim into the upstream template. pack.toml version
bumped. No CHANGELOG file exists in the pack, so none was added.

## Validation

- rdflib parse of packs/ash-pplan-workflow-pack/ontology.ttl: **PASS, 1022
  triples** (rdflib 7.x, Turtle).
- Render validation via ggen_igniter (`GgenIgniter.Render`, stdlib EEx) into
  /tmp scratch (`/tmp/eco-render`, script `/tmp/eco_validate.exs` run with
  `mix run` in ash_pplan, synthetic SPARQL-row bindings, ash_pplan sources
  read-only): **all 9 workflow-pack templates render OK**. Format
  characterization: all rendered Elixir/ExUnit surfaces are **FORMAT-STABLE**
  (parse clean, `mix format` converges) but **NOT byte-stable pre-format**;
  `hddl_file.hddl.eex` is a non-Elixir surface (no format check).
- ash-extension-core-pack adapter template: old (0.1.1 upstream) vs new
  (0.1.2 ported) both render OK with identical assigns; new output carries
  the GENERATED header + multi-line ops list, i.e. the vendor-time patch
  content is now upstream. Recorded as **FORMAT-STABLE, not byte-stable
  pre-format** — the consumer still runs its normal `mix format`, but no
  hand patching.

## Post-merge consumer steps (after this branch merges to ggen-marketplace main)

1. Merge the branch into ggen-marketplace `main` (no force, no push beyond
   the normal merge).
2. In ash_pplan, re-pin `priv/ggen/vendor/PACKS.lock.json`:
   `ash-pplan-workflow-pack` → new upstream SHA (pack newly exists upstream),
   `ash-extension-core-pack` → post-merge upstream SHA; update
   `source_git_sha`.
3. Re-sync via `priv/ggen/vendor/sync.sh` — but first extend the sync flow so
   the workflow pack is vendored whole (it is not yet in the vendored set).
4. Re-copy the new upstream `ash_reactor_extended_adapter.ex.eex` over the
   vendored copy and **delete the vendor-time patch** (`patched: true` →
   `false` in the lock); the sync output must now be byte-identical to
   upstream 0.1.2.
5. Verify the vendor overlay returns to **269/269** sha256 match against
   PACKS.lock.json (`priv/ggen/vendor/verify_lock.sh`).
6. Run the ash_pplan gate suite and the workflow-pack renders
   (`bin/manufacture-workflow`) to confirm the published pack regenerates the
   consumer surfaces; then port the root `ontology.ttl` R2-sync outcome into
   the upstream pack ontology as a follow-up if the R2 lane changed
   workflow-pack inputs.

## Standing

ALIVE for the publish + version bump on branch
`errc-promote-workflow-pack-and-ashext-template` @ `e6496435b` (exact subject:
local branch, no push). Merge is a coordinator transition, not performed by
this lane.

## Update 2026-10-04: R2 sync ported to the branch pack (delta-ERRC P2 unblock)

The reconciliation lane has landed, so the workflow-pack copy on
`errc-promote-workflow-pack-and-ashext-template` was pre-R2-sync bytes. New
commit `9b961d454` (added on top of `e6496435b`; the ashext commit is not
rewritten) ports the post-R2-sync state from
`ash_pplan priv/ggen/ash-pplan-workflow-pack`:

- `packs/ash-pplan-workflow-pack/ontology.ttl` replaced with the current
  upstream copy. Header-stripped SHA-256 (`tail -n +5`) ==
  `cd212e7bd242d978fce18c5ac7640d63ac137377226761ea05a02fa0468208c8`, and the
  header-stripped bytes are byte-identical (`cmp`) to canonical repo-root
  `ontology.ttl`; rdflib parses cleanly, **1041 triples**.
- Dir diff of gates/verify/templates/bin/pack.toml against upstream found two
  deltas, both ported: `verify/cardinality.json` (task_props contract
  VALUES -> DERIVED_ROWS; the previously-recorded KNOWN STANDING refusal
  14-vs-18 is closed, 18 == 18) and the new
  `templates/placeholder.tmpl`.
- Render validation: `mix ggen_igniter.sync` (ggen_igniter 26.10.2, engine
  oxigraph) rendered `templates/capability_catalog.ex.eex` from the
  marketplace pack copy into scratch — wrote a valid 45-line
  `CapabilityCatalog` module (15 queries, 203 rows), scratch deleted after.
  First attempt with `--out` under /private/tmp was typed-refused by the
  reactor (`target resolves outside the authorized project root`); rendering
  from a gitignored scratch path inside the project root is the working
  shape.
- Reactor gates re-verified upstream: 4/15/15/4.

Standing: ALIVE for the R2 sync on the branch @ `9b961d454` (local, no push).
Marketplace repo restored to `main` with the prior working tree intact
(stash round-trip); no other branches touched.
