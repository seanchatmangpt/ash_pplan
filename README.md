# ash_pplan

**P-PLAN/PROV-O semantics projected into the existing Ash process stack.**

`ash_pplan` deliberately does not introduce another workflow runtime. The canonical object is a technology-neutral process model. The implementation is a projection onto capabilities that already exist:

| Public/process concept | Runtime projection |
|---|---|
| `p-plan:Plan` | Reactor definition / builder |
| `p-plan:Step` | Ash.Reactor step/action binding |
| `p-plan:Variable` | Reactor input/argument/result |
| `prov:Activity` | execution observation / telemetry |
| `prov:Entity` | Ash resource/value state |
| `prov:Agent` | Ash actor/authority context |
| background activation | AshOban trigger/worker |
| temporal activation | AshOban schedule / Oban cron |
| semantic execution | `AshPPlan.Compiler` -> `Reactor.Builder` |
| execution evidence | `AshPPlan.ExecutionReceipt` |
| persistent continuation | explicit gap; no invented runtime |

## v26.9.7 contract

1. `ontology.ttl` remains the semantic source of truth.
2. `priv/ggen/ash-pplan-pack/ontology.ttl` remains a symlink to that source, so ggen_igniter cannot drift onto a second ontology.
3. `ggen_igniter` manufactures both the runtime projection catalog and the executable P-PLAN plan catalog.
4. `AshPPlan.Compiler` validates admitted topology before building a Reactor.
5. Executable behavior is explicitly bound by semantic step IRI to existing `Reactor.Step` implementations.
6. P-PLAN precedence becomes Reactor result dependencies; Reactor remains the scheduler/executor.
7. `AshPPlan.execute/5` returns the observed Reactor outcome plus a content-addressed execution receipt.
8. Persistent halted-continuation storage remains an explicit gap rather than being inferred from Oban persistence.

## Manufacture

```bash
mix deps.get
./bin/manufacture
mix check
```

The generated source must remain unchanged after manufacture:

```bash
./bin/manufacture
git diff --exit-code -- lib/ash_pplan/generated
```

The repository pins its producer identities in `ecosystem.lock.toml`. CI independently validates the ontology inside the pinned `ggen-ecosystem` container and regenerates both Elixir catalogs with `ggen_igniter`.

## Semantic execution

```elixir
handlers = %{
  "https://w3id.org/ash-pplan#AuthorizePayment" => MyApp.AuthorizePaymentStep,
  "https://w3id.org/ash-pplan#RenewSubscription" => MyApp.RenewSubscriptionStep
}

{{:ok, result}, receipt} =
  AshPPlan.execute(
    "https://w3id.org/ash-pplan#SubscriptionRenewal",
    handlers,
    %{subscription_id: "sub_123"},
    %{},
    run_id: "renewal-123"
  )
```

The compiler refuses malformed graphs, duplicate steps, dangling predecessors, cycles, missing handlers, invalid handlers, and unbounded terminal fan-out before Reactor execution begins.

## Architecture

```text
P-PLAN + PROV-O
      |
      v
  ontology.ttl
      |
      +--------------------------+
      |                          |
      v                          v
 ggen-ecosystem              ggen_igniter
 semantic court              manufacture
      |                          |
      +-------------+------------+
                    v
       generated projection + plan catalogs
                    |
                    v
            AshPPlan.Compiler
                    |
                    v
              Reactor.Builder
                    |
       +------------+-------------+
       |            |             |
       v            v             v
   Ash.Reactor    AshOban       scheduling
       |            |             |
       +------------+-------------+
                    v
               Reactor.run
                    |
                    v
        AshPPlan.ExecutionReceipt
```

See `docs/architecture.md`, `docs/semantic-execution.md`, `docs/working-backwards-press-release-v26.9.6.md`, and the HDDL plans under `planning/`.
