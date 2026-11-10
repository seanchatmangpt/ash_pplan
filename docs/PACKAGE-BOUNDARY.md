# package-boundary

> Standing: IN-FORCE (2026-11-07 operator decision; per-item status below).

## The Law (2026-11-07)

One sentence of ownership:

**ash_pplan owns the deliberation core + flight recorder; ash_a2a owns the
sensory nervous system + authority.**

| Package | Owns | Does NOT own |
|:---|:---|:---|
| **ash_pplan** | The deliberation core and the flight recorder: the semantic compiler, FOND/HTN deliberation, the SHACL shape engine, the durable replay ledger, and engine telemetry emission. | No sensory ingress, no twins, no wire codecs, no authority grants. |
| **ash_a2a** | The sensory nervous system and authority: the digital twins, sensory ingress, attention broker, wire protocol, and the CommandBus. | No planning, no durable execution, no shape validation, no ledger. |

## Boundary Test

One-sentence ownership test: **if it deliberates or records, it is
ash_pplan; if it senses, communicates, or holds authority, it is ash_a2a.**

This sentence is the canonical law. The ash_a2a-side boundary statement
(`ash_a2a/docs/explanation/copilot-membrane.md`, section "The membrane in
one sentence") must carry it byte-identically; the cross-repo seam
inventory (`ash_a2a/docs/explanation/pplan-seams.md`) links back here.

## Exclusions (ash_pplan must never contain)

| Exclusion | Detail | Status |
|:---|:---|:---|
| No Phoenix / React | No web framework, no UI layer, no channels. | IN-FORCE |
| No wire codecs | No A2A JSON-RPC / protocol framing in ash_pplan; wire lives in ash_a2a. | IN-FORCE |
| No embedded Python | The Airbus oracle is CI-only, reached over a socket — never linked or embedded in-core. | IN-FORCE |
| No hardcoded municipal content | Municipal domain content lives in external TTL shape data, not in `lib/`. | IN-FORCE |
| Shapes are external TTL data | The SHACL engine consumes shapes as data; shapes ship outside `lib/`. | IN-FORCE |

## Item Status

| Item | Package | Status |
|:---|:---|:---|
| Compiler, FOND/HTN, SHACL engine, durable ledger, telemetry emission | ash_pplan | IN-FORCE (built; known defects being fixed) |
| Financial margin / statutory envelope gating | ggen-marketplace pack `financial-margin-envelope` | IN-FORCE (shipped as pack, absent in-core) |
| Digital twins | ash_a2a | IN-FORCE (relocated 2026-11-07) |
| Sensory ingress + attention broker | ash_a2a | IN-FORCE (relocated 2026-11-07) |
| Wire protocol + CommandBus | ash_a2a | IN-FORCE (relocated 2026-11-07) |
| Authority.PEP | ash_a2a | LANDED (`lib/ash_a2a/authority/pep.ex`; module landed, Pipeline wiring still prescribed-not-wired) |
| Authority GraphPin | ash_a2a | LANDED (`lib/ash_a2a/authority/graph_pin.ex`) |
| Actuation | ash_a2a | LANDED (skeleton: `lib/ash_a2a/actuation/` — adapter, engine, ticket) |
| Attention broker | ash_a2a | LANDED (`lib/ash_a2a/attention/broker.ex`) |
| Negotiation strategy | ash_a2a | LANDED (`lib/ash_a2a/negotiation/strategy.ex`) |
| Tactical COP console | separate deliverable | PENDING LANE (ships separately) |
| Architecture cross-link (`docs/architecture.md` → this file) | ash_pplan docs | PENDING LANE (D2 owns `architecture.md`) |

## See Also

- `docs/industrial-deliberation-and-durable-execution-subsystem-prd-ard.md`
  (claim census, same date)
- `docs/architecture.md` (owned by lane D2; cross-link suggestion filed in
  the D7 receipt, not edited here)
- `/Users/sac/ash_a2a/docs/explanation/copilot-membrane.md` — the ash_a2a-side
  boundary statement; carries the same law sentence
- `/Users/sac/ash_a2a/docs/explanation/pplan-seams.md` — cross-repo seam and
  integration-court inventory
