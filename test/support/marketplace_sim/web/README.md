# Marketplace Sim — Web Layer

Adapted single-file PETAL app (GCP Marketplace P-Plan explorer) plus a real-time
fleet dashboard, on ash_pplan's real runtime.

# Launch (serving mode)

    bin/dashboard --port 4100
    # then open http://127.0.0.1:4100/ and /dashboard

# Routes

- `/` — GCP Marketplace lifecycle explorer (`LifecycleLive`): 8 p-plan steps,
  29 variables, 8 agents, 4 orgs extracted with RDF.Turtle + SPARQL at compile
  time from `../lifecycle_plan.ttl`; domain-filtered Petal avatar cards;
  step detail (inputs/outputs/agents/preceded-by + risk prose); FinOps
  simulator (server-side math, inline SVG burn-down); server-side turtle
  search (prefix lines preserved).
- `/dashboard` — fleet dashboard (`DashboardLive`): capability catalog +
  provider index KPIs; real `Store.Ets` durable-run ledger rows; REAL-TIME step
  event stream via `:telemetry.attach_many` on
  `Observation.events() ++ Telemetry.events()` (pid-scoped handler, detached in
  terminate/2); standing tape panel (real checkpoints from `Ets.standing/2`);
  form-to-run starts a REAL durable `ontology_only` run through
  `AshPPlan.Examples.Runners.OntologyOnly.run_durable/2` on the dashboard's own
  store, parking on the `confirm` gate; signal+resume completes it.

# What's real vs simulated

- REAL: TTL extraction (SPARQL), capability catalog, provider index, durable
  ETS ledger, durable runs (engine park/resume), telemetry stream, standing
  tape, FinOps math.
- SIMULATED: the FinOps commitment-pool scenario numbers (closed-form model,
  no external billing system), the avatar/step prose layer (not in the TTL,
  kept as module attributes keyed by IRI local name), and the 12-month linear
  burn-down curve (illustrative model, server-side SVG).
