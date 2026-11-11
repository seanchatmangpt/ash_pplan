# ECO: Fleet Zero-Mock Discipline & Anti-Vacuity (`f496f33`)

- **Ticket Key**: `PPLAN-261110-04`
- **Milestone**: `v26.11.10`
- **Locus**: `lib/ash_pplan/chicago/collaborators/mock_scan.ex`, `test/courts/`
- **Status**: VERIFIED

---

## 1. Context & Rationale

Per Chicago school TDD and the Chatman Equation (`A = μ(O*)`), test suites that rely on unchecked mock doubles create vacuous admissions (`admission_vacuous`), where gates never refuse and synthetic tests pass on broken subjects.

## 2. Implementation

Ported from `ash_a2a` (Lane `V8-MOCKCOURT-e`, commit `f496f33`), the zero-mock court:
- Scans all test cases for Mox, double, or monkey-patching constructs.
- Requires explicit collaborator protocol contracts for any test double.
- Enforces anti-vacuity: every court must demonstrate witnessed refusal when supplied with counterexamples.
- Falsifies any test claim lacking byte-identical replay evidence.
