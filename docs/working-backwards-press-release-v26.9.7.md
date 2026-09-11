# ash_pplan v26.9.7 — Working Backwards Press Release

**September 6, 2026** — `ash_pplan` now turns admitted P-PLAN process topology into executable Reactor graphs without converting semantic modeling into a second workflow framework.

Plans, steps, precedence edges, and variables remain defined in the canonical P-PLAN/PROV-O-aligned ontology. `ggen_igniter` manufactures a pure-data plan catalog from that ontology. `AshPPlan.Compiler` validates the graph, requires explicit behavior bindings for every semantic step, and projects the result into Reactor's public `Reactor.Builder` API.

The release adds no scheduler, queue, retry engine, compensation engine, transaction engine, or durable workflow runtime. Reactor remains responsible for execution. Ash.Reactor remains responsible for Ash action integration. AshOban and Oban remain responsible for background delivery and scheduling.

Every observed semantic execution can now produce a content-addressed PROV-style receipt containing plan identity, run identity, status, timing, and a digest of the observed result. Receipts remain evidence rather than authority.

The release remains intentionally conservative about durability: a halted Reactor is observable and receiptable, but arbitrary halted continuation persistence is still not claimed until a concrete store, wakeup, lease, and replay contract is admitted.
