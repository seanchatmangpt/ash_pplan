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
| release observation | CI exact-head qualification |
| release evidence | `AshPPlan.ReleaseReceipt` |
| persistent continuation | explicit gap; no invented runtime |

## v26.9.7 contract

1. `ontology.ttl` remains the semantic source of truth.
2. `priv/ggen/ash-pplan-pack/ontology.ttl` remains a symlink to that source, so ggen_igniter cannot drift onto a second ontology.
3. `ggen_igniter` manufactures both the runtime projection catalog and the executable P-PLAN plan catalog.
4. `AshPPlan.Compiler` validates admitted topology before building a Reactor.
5. Executable behavior is explicitly bound by semantic step IRI to existing `Reactor.Step` implementations.
6. P-PLAN precedence becomes Reactor result dependencies; Reactor remains the scheduler/executor.
7. `AshPPlan.execute/5` returns the observed Reactor outcome plus a content-addressed execution receipt.
8. `ontology/shapes.ttl` is an executable conformance profile: `./bin/conform` refuses a non-conforming ontology, and `./bin/conform-falsify` proves the profile is capable of refusing.
9. An exact release head is observable and receiptable through `AshPPlan.ReleaseReceipt`.
10. Persistent halted-continuation storage remains an explicit gap rather than being inferred from Oban persistence.

## Manufacture

```bash
mix deps.get
./bin/conform          # ontology conforms to ontology/shapes.ttl
./bin/conform-falsify  # the profile really refuses what it claims to refuse
./bin/manufacture      # regenerate both catalogs from the canonical ontology
mix check
./bin/receipt          # content-addressed evidence for this exact head
```

`bin/conform` and `bin/conform-falsify` need `rdflib` and `pyshacl`; CI pins both.

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

# Inside a step, p-plan precedence is readable as a result:
#
#   def run(arguments, context, _options) do
#     %{"https://w3id.org/ash-pplan#AuthorizePayment" => authorization} =
#       AshPPlan.predecessor_results(arguments, context)
#
#     {:ok, authorization}
#   end

{{:ok, result}, receipt} =
  AshPPlan.execute(
    "https://w3id.org/ash-pplan#SubscriptionRenewal",
    handlers,
    %{subscription_id: "sub_123"},
    %{},
    run_id: "renewal-123"
  )
```

The compiler refuses malformed graphs, duplicate steps, dangling predecessors, cycles, missing handlers, invalid handlers, and unbounded terminal fan-out before Reactor execution begins. Every one of those refusals has an executable falsifier in `test/compiler_refusal_test.exs`.

`ontology/shapes.ttl` refuses several of the same conditions one layer earlier, at the semantic boundary, so a plan the compiler would reject never reaches a manufactured catalog.

## Release evidence

```bash
./bin/receipt
```

```json
{
  "release": "26.9.7",
  "digest": "<sha256>",
  "sources": {
    "ecosystem.lock.toml": "<sha256>",
    "lib/ash_pplan/generated/plan_catalog.ex": "<sha256>",
    "lib/ash_pplan/generated/projection_catalog.ex": "<sha256>",
    "ontology.ttl": "<sha256>",
    "ontology/shapes.ttl": "<sha256>"
  }
}
```

The digests are taken at compile time, so a receipt describes the head that was actually built. A release receipt is evidence, not authority: it publishes, tags and approves nothing.

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
