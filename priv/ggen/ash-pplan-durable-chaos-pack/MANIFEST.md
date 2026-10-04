# ash-pplan-durable-chaos-pack — manifest

Manufacturing source of `test/durable/chaos/*_test.exs` (6 invariant
suites + 4 kill suites, byte-identical replay witnessed 2026-10-04,
ggen_igniter 26.10.2, engine `oxigraph`).

## Manufacture recipe (single command, per template)

```sh
mix ggen_igniter.sync --ontology priv/ggen/ash-pplan-durable-chaos-pack/ontology.ttl \
  --pack-dir priv/ggen/ash-pplan-durable-chaos-pack \
  --template priv/ggen/ash-pplan-durable-chaos-pack/templates/invariant_property.exs.eex \
  --engine oxigraph --on-stale prune \
  --out 'test/durable/chaos/<%= invariantId %>_property_test.exs' --for-each invariants \
  --manifest-dir tmp/mf --verify-cwd "$PWD"

mix ggen_igniter.sync --ontology priv/ggen/ash-pplan-durable-chaos-pack/ontology.ttl \
  --pack-dir priv/ggen/ash-pplan-durable-chaos-pack \
  --template priv/ggen/ash-pplan-durable-chaos-pack/templates/kill_matrix.exs.eex \
  --engine oxigraph --on-stale prune \
  --out 'test/durable/chaos/kill_<%= phaseId %>_test.exs' --for-each kill_phases \
  --manifest-dir tmp/mf --verify-cwd "$PWD"
```

(Equivalent to the two `sync` calls in `bin/manufacture-durable-chaos`, which
wraps them in `mf_sync` with `--manifest-dir tmp/mf`.)

## Local proof (one command, no repo writes)

```sh
cd /Users/sac/ash_pplan && PACK=priv/ggen/ash-pplan-durable-chaos-pack && \
mix ggen_igniter.sync --ontology $PACK/ontology.ttl --pack-dir $PACK \
  --template $PACK/templates/invariant_property.exs.eex --engine oxigraph --on-stale prune \
  --out 'tmp/chaos-proof/<%= invariantId %>_property_test.exs' --for-each invariants \
  --manifest-dir tmp/chaos-proof/mf --verify-cwd "$PWD" && \
mix ggen_igniter.sync --ontology $PACK/ontology.ttl --pack-dir $PACK \
  --template $PACK/templates/kill_matrix.exs.eex --engine oxigraph --on-stale prune \
  --out 'tmp/chaos-proof/kill_<%= phaseId %>_test.exs' --for-each kill_phases \
  --manifest-dir tmp/chaos-proof/mf --verify-cwd "$PWD" && \
for f in tmp/chaos-proof/*.exs; do cmp "$f" "test/durable/chaos/$(basename $f)"; done \
  && echo "byte-identical: 10/10" && rm -r tmp/chaos-proof
```

Measured 2026-10-04: `byte-identical: 10/10` (6 invariant suites + 4 kill
suites). Note: ggen_igniter refuses `--out` targets resolving outside the
project root ("resolves outside the authorized project root"), so the scratch
out must live under the repo (gitignored `tmp/` is fine).

## Gate witness (measured 2026-10-04, GgenIgniter.Query.Oxigraph)

vs the pack's own `gates/` + `verify/` over `ontology.ttl` (dc: namespace):

| query | rows | expected |
|---|---|---|
| gates/010_invariants.rq | 6 | 6 Invariants |
| gates/020_kill_phases.rq | 4 | 4 KillPhases |
| verify/010_invariants.unbound.rq | 0 | 0 (pass) |
| verify/020_kill_phases.unbound.rq | 0 | 0 (pass) |

vs the marketplace pack `ggen-marketplace:packs/ash-pplan-chaos-pack` gates
over `priv/ggen/ash-pplan-chaos-pack-acp-rows.ttl` (acp: namespace)
(deleted 2026-10-04; superseded by the vendored `ash-pplan-chaos` pack
adoption, recorded on `[packs.ash-pplan-chaos]` in `ggen.toml`):

| query | rows | expected |
|---|---|---|
| gates/010_harness.rq | 1 | 1 Harness |
| gates/020_invariants.rq | 6 | 6 Invariants |
| gates/030_kill_phases.rq | 4 | 4 KillPhases |
| verify/010_harness.unbound.rq | 0 | 0 (pass) |
| verify/020_invariants.unbound.rq | 0 | 0 (pass) |
| verify/030_kill_phases.unbound.rq | 0 | 0 (pass) |

Cardinality contracts (both packs) are ROWS-mode, predicate-anchored on
`testNamespace` / `order` / `nth` — the rows file carries all three anchors,
so every ROWS contract is non-zero. Row values are the real ash_pplan modules
(`AshPPlan.Test.Chaos.{Generators,Harness,Invariants,Sabotage}`) and seeds,
not specimens.

Note: the acp: rows file does NOT satisfy this pack's dc:-prefixed gates (and
is not supposed to — it is the marketplace-pack translation, generated from
this dc: ontology; regenerate, don't hand-edit). The dc: ontology is the
manufacturing source; the acp: rows file is the consumer-facing projection.
