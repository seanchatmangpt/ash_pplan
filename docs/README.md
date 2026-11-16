# ash_pplan documentation index (v26.11.10)

The primary entry point for documentation is the Diátaxis map:
[docs/diataxis/README.md](diataxis/README.md) — tutorials (learn),
how-to guides (accomplish a task), reference (look something up),
and explanation (understand why).

Start there; the quadrants link every documentation page. Pages are also wired into
`mix docs` via the `extras:` and `groups_for_extras:` configurations in `mix.exs`.

---

## Current Release: v26.11.10

- **Release Epic**: [docs/jira/v26.11.10/EPIC-RELEASE-v26.11.10.md](jira/v26.11.10/EPIC-RELEASE-v26.11.10.md) — milestone scope, closed work items, and acceptance criteria.
- **Swarm Review Synthesis**: [docs/jira/v26.11.10/SWARM-REVIEW-SYNTHESIS.md](jira/v26.11.10/SWARM-REVIEW-SYNTHESIS.md) — cross-perspective architectural synthesis across 10 expert evaluations (Score: 196.0/200.0, 98% approval).
- **Hex Release Court**: [docs/jira/v26.11.10/HEX-RELEASE-COURT-RECEIPT.md](jira/v26.11.10/HEX-RELEASE-COURT-RECEIPT.md) (`hex-release-court.receipt.json`) — packaging gate verification and release receipt (status: `ADMITTED`).
- **Domain Expert Evaluations** ([docs/jira/v26.11.10/evaluations/](jira/v26.11.10/evaluations/)):
  1. [EVAL-01-ZACH-DANIEL.md](jira/v26.11.10/evaluations/EVAL-01-ZACH-DANIEL.md) — Ash Framework architecture & Spark DSL boundaries.
  2. [EVAL-02-JOE-ARMSTRONG.md](jira/v26.11.10/evaluations/EVAL-02-JOE-ARMSTRONG.md) — Level-triggered scheduling, failure isolation & concurrency.
  3. [EVAL-03-JOSE-VALIM.md](jira/v26.11.10/evaluations/EVAL-03-JOSE-VALIM.md) — Elixir idioms, behaviour contracts & Hex packaging.
  4. [EVAL-04-CHRIS-MCCORD.md](jira/v26.11.10/evaluations/EVAL-04-CHRIS-MCCORD.md) — Telemetry, OCEL 2.0 emissions & real-time observability.
  5. [EVAL-05-PRAGMATIC-PROGRAMMERS.md](jira/v26.11.10/evaluations/EVAL-05-PRAGMATIC-PROGRAMMERS.md) — Andy Hunt & Dave Thomas: orthogonal design & pragmatic mechanics.
  6. [EVAL-06-FRANCESCO-CESARINI.md](jira/v26.11.10/evaluations/EVAL-06-FRANCESCO-CESARINI.md) — Supervision tree design, FSM correctness & release gate rigor.
  7. [EVAL-07-MIKE-WILLIAMS.md](jira/v26.11.10/evaluations/EVAL-07-MIKE-WILLIAMS.md) — Hardware fault boundaries, durable storage & memory footprint.
  8. [EVAL-08-ROBERT-VIRDING.md](jira/v26.11.10/evaluations/EVAL-08-ROBERT-VIRDING.md) — Language purity, macro hygiene & semantic compilation.
  9. [EVAL-09-FRED-HEBERT.md](jira/v26.11.10/evaluations/EVAL-09-FRED-HEBERT.md) — Operability, failure modes & property-based resilience.
  10. [EVAL-10-RICH-HICKEY.md](jira/v26.11.10/evaluations/EVAL-10-RICH-HICKEY.md) — Value-oriented programming, data-first ontology & time-model decoupling.

---

## Architectural Boundaries & Principles

- [architecture.md](architecture.md) — Core architecture, descriptor law, SELECT/CONSTRUCT/DO fences, and runtime execution mapping.
- [PACKAGE-BOUNDARY.md](PACKAGE-BOUNDARY.md) — Boundary law: `ash_pplan` owns deliberation core and flight recorder; `ash_a2a` owns sensory nervous system and authority.
- [industrial-deliberation-and-durable-execution-subsystem-prd-ard.md](industrial-deliberation-and-durable-execution-subsystem-prd-ard.md) — Deliberation and durable execution PRD/ARD specification.
- [semantic-execution.md](semantic-execution.md) — Semantic projection and execution lifecycle.
- [ontology-only-authoring.md](ontology-only-authoring.md) — Graph-first authoring discipline.
- [NOTICE.md](NOTICE.md) — Upstream derivations and licensing attribution.

---

## Roadmap & Historical Archives

- [POST-ARCHIVE-MAP.md](POST-ARCHIVE-MAP.md) — Post-archive roadmap and completed P1–P9 item closeouts through `v26.11.10`.
- [COMBINE-HARDEN-MAP.md](COMBINE-HARDEN-MAP.md) — Historical hardening and combine roadmap (archived).
- [archive/](archive/) — Directory of point-in-time documents, historical audits, and prior milestone snapshots.

