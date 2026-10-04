# GCP Lifecycle Simulation

`test/support/marketplace_sim/` models the GCP Marketplace lifecycle as a
P-PLAN workflow over in-process participants, exercised by courts that assert
on real process state (GenServers, ETS) — no doubles. The plan is
`test/support/marketplace_sim/lifecycle_plan.ttl`; it imports canonical
P-PLAN 1.3 and PROV-O, vendored under `priv/vendor/` and enforced by
`test/courts/pplan_upstream_court_test.exs`.

## Lifecycle: 8 steps

The plan declares 8 `p-plan:Step` individuals chained by
`p-plan:isPrecededBy`, with 8 `prov:Person` agents, 4 `prov:Organization`
members and 27 `p-plan:Variable` individuals. The plan groups the steps into
six business phases; the phase numbering below is a reading of the plan's
step chain (the TTL does not declare phase individuals).

Step IRIs below are the local fragment of the `https://cloud.google.com/
marketplace/ontology/v1#` individual.

| Step | Phase | Agents (`prov:wasAssociatedWith`) |
|---|---|---|
| `gcp:Step1_EnrollAndVerifySupplier` | 1: onboarding | ElenaVance |
| `gcp:Step2_PublishSaaSListing` | 2: publication | MarcusThorne, KenjiSato |
| `gcp:Step3_StructurePrivateOffer` | 3: private offers | ElenaVance, RachelAdams, LiamSterling |
| `gcp:Step4_AuthorizeAndAcceptOffer` | 4: sourcing | SarahChen, DavidRoss, TariqAlMansoor |
| `gcp:Step5_ProvisionEntitlementAndLinkAccount` | 5: entitlement | MarcusThorne |
| `gcp:Step6_MeterTelemetryUsage` | 5: metering | MarcusThorne |
| `gcp:Step7_ExecuteCommitmentDrawdown` | 5: drawdown | DavidRoss |
| `gcp:Step8_DisburseNetSettlement` | 6: settlement | ElenaVance |

## Participants

Each participant is a real GenServer (Billing: real shared ETS tables). All
timestamps are arguments, never `:erlang.system_time/0`, so courts pin time
deterministically.

| Participant | Module | Real state |
|---|---|---|
| Google Procurement API | `...Google.ProcurementApi` | accounts, entitlements (GenServer) |
| Google Pub/Sub | `...Google.Pubsub` | ordered per-topic envelopes (GenServer) |
| Vendor portal | `...Vendor.Portal` | issued tokens, signing secret (GenServer) |
| Vendor metering | `Vendor.MeteringServer` | per-entitlement usage events (GenServer) |
| Vendor billing | `Vendor.Billing` | EDP pools, `(committed, spent)` (shared ETS) |

Refusal/dedup behavior per participant:

- ProcurementApi: 13-event entitlement state fold; an unknown event type
  refuses rather than silently ignoring.
- Pubsub: duplicate-delivery simulation; redeliveries counted per
  `{subscriber, id}` and exposed via `redeliveries/1`.
- Portal: HMAC-SHA256 JWT verification; `:expired`, `:wrong_aud`,
  `:malformed` are typed refusals.
- MeteringServer: dedupe by `(entitlement_id, usage_event_id)`; aggregation
  over the half-open window `[from, to)`.
- Billing: drawdown idempotent by `ref`; overdraw refused with the committed
  pool left unchanged.

Module prefixes are elided for width: Google-side modules are
`AshPPlan.Sim.Marketplace.Google.*`, vendor-side `AshPPlan.Sim.Marketplace.Vendor.*`
except `Vendor.MeteringServer`/`Vendor.Billing`, which are top-level.

Courts: `test/support/marketplace_sim/metering_billing_court_test.exs` proves
usage dedup, half-open windows, cross-entitlement isolation, zero-usage
anti-vacuity, drawdown and overdraw refusal against the real state.

## Event flow

The simulated run follows the plan's dependency chain:

1. **Signup** — the vendor Portal issues a single-use JWT
   (`sub`/`aud`/`exp` claims, HS256); verification refuses expired,
   wrong-audience and malformed tokens.
2. **Account approve** — a Google-side account is created and approved via
   the ProcurementApi; state lands in the event journal.
3. **Entitlement ACTIVE** — entitlement events (`ENTITLEMENT_CREATION_REQUESTED`,
   `ENTITLEMENT_OFFER_ACCEPTED`, `ENTITLEMENT_ACTIVE`, plan-change and
   cancellation variants) fold to an entitlement status; every transition
   publishes to the simulated Pub/Sub topic.
4. **Usage** — per-entitlement usage events are posted to the MeteringServer;
   duplicates are no-ops; aggregation is window-scoped.
5. **Drawdown** — validated usage draws down the Billing EDP pool; repeated
   refs are idempotent; overdraw is refused with the pool untouched.
6. **Settlement** — the drawn-down totals stand in for the plan's
   `Var_ConsolidatedGCPMonthlyInvoice` / `Var_FinalNetRemittanceWire`
   outputs; the disbursement leg is the boundary described below.

## Honest boundary

What is simulated in-process, and what stays on Google:

**In-process (real, executed):**

- ProcurementApi account/entitlement state and its 13-event fold, ported
  from the beam4pm-pro-entitlement-pack semantics (simplified to a
  sequence-ordered log).
- Pub/Sub topic fan-out with counted redeliveries — the at-least-once
  delivery property is exercised, not assumed.
- JWT signup verification with real HMAC-SHA256 and `Plug.Crypto.secure_compare`.
- Usage metering dedup and half-open-window aggregation.
- EDP committed-spend drawdown with ref idempotence and overdraw refusal.

**Not simulated — BLOCKED on real Google:**

- A real Pub/Sub endpoint: messages never leave the BEAM; no push/pull
  subscriptions, no GCP project, no IAM.
- A real seller/producer account: listing publication, private-offer
  payloads and the Producer Portal are plan variables only.
- Service Control in production: usage is aggregated by the MeteringServer,
  not ingested by Google's metering service; no
  `services.report`/`services.consume` call is made.
- Steps 1-4 and 8 of the plan (onboarding, publication, negotiation,
  sourcing, settlement) have no executing code — they are `p-plan:Step`
  declarations plus variables. The Reactor step wiring under
  `test/support/marketplace_sim/reactors/` is not yet populated.
- No billing money moves: `Vendor.Billing` debits an in-memory ETS integer.

The same honesty pattern as the beam4pm-pro-entitlement-pack README: only
properties testable without the external provider are claimed; MP3-style
entitlement reconciliation and MP6-style metering/billing reconciliation are
the ones exercised here.
