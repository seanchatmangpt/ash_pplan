# ECO-FOND-PACK Reconciliation

Read-only recon for ERRC C8 prep. FOND surface inventory, pack vocabulary
mapping, falsifier-court analysis, phased runbook. No code edits made.

## 1. FOND Surface Inventory

`/Users/sac/ash_pplan/lib/ash_pplan/fond/` — 18 modules, 1769 lines total:

| module | lines | role |
|---|---|---|
| fond.ex | ~330 | core domain struct + `validate_policy/4` + `synthesize/1` + `to_tla/5` |
| tla.ex | 258 | TLA+ render-only projection (authority NONE, ceiling CONSTRUCT) |
| differential.ex | 72 | differential court: native validator vs independent checker |
| tla/json.ex, tla/manifest.ex, tla/mutation.ex | 184 | TLC json/manifest + anti-vacuity mutants |
| synthesis.ex | 283 | strong / strong-cyclic synthesis |
| policy_supervisor.ex + offers.ex | 303 | supervised policy execution offers |
| policy_switch.ex | 110 | policy switch |
| provider_registry.ex | 101 | pluggable checker providers |
| corpus.ex, counterexample.ex, recovery.ex, replay.ex, subject.ex, supervision_session.ex, trace.ex, projection.ex | 448 | evidence plumbing |

Core semantics: `%AshPPlan.FOND{states, goals, transitions}`, policy =
`%{state => action}`, modes `:strong` / `:strong_cyclic`. Typed refusals:
`missing_policy_action`, `unavailable_policy_action`, `not_strong`,
`not_strong_cyclic`. `new/2` refuses empty outcome lists (anti-vacuity).
`check/1` refuses hand-built struct bypasses.

## 2. The Two Falsifier Courts

### Court A: `test/fond/semantic_reality_fond_court_test.exs` (344 ln)

Exact-semantics falsifiers over `validate_policy` / `synthesize`:
- strong vs strong-cyclic discrimination ("retry policy refused as
  `:not_strong`, admitted as `:strong_cyclic`")
- coin-flip domain strong-cyclic policy validates
- determinism of validate/synthesize across repeated calls
- domain-struct immutability; zero processes started
- dead-end / losing-cycle refusals naming the state
- empty outcome list refused at `new/2` (no vacuous admission)
- `missing_policy_action` / `unavailable_policy_action` naming the state

### Court B: `test/fond/tla_differential_edge_test.exs` (358 ln)

Differential court + TLC falsifiers:
- "the ontology edge graph validates as a FOND domain and renders;
  reader == elixir" — pack/graph-sourced edge reading must equal the
  Elixir-native transition relation
- "every status pair agrees, including the unwind_blocked self-transition"
- negative controls: pairs the wave did not add refused by BOTH sources
- guard-dropping mutants (`tla/mutation.ex`) differ at one guard line;
  "TLC: mutant dropping guard:X is refused via Y" — anti-vacuity of the
  rendered spec itself
- cfg property + signal-guard presence
- real supervisor: orphan signal, DETS path-in-use, `unwind_blocked`
  second-failed-rollback witness, `horizon_exceeded` typed refusal

Supporting: `fond_harden_h4_test.exs` (Differential.check with malformed
checkers), `fond_horizon_burn_test.exs` (soak), `corpus_test.exs`,
`replay_test.exs`, `research_wave_0{1,2,3,7,11,12,13,14}_test.exs`.
There is no `test/courts/*fond*` file; the two falsifier courts live in
`test/fond/` directly.

## 3. Pack Reading

### planning-federation-pack (v26.9.4)

Generates a **Python** planner federation from `queries/model.rq` over a
`pf:` vocabulary (`pf:PlanningDomain`, `pf:PlannableAction`,
`pf:precondition/effect/cost/duration/probability/authorityRef`):
classical BFS `symbolic.py`, `projector.py` dispatch, `interchange.py`,
`planner_ir.json`, no-plan status vocabulary
(`NO_PLAN/UNREACHABLE/.../AUTHORITY_BLOCKED`). It is **classical planning
only — it has no FOND policy semantics, no strong/strong-cyclic modes, no
outcome branches, no fairness**. Probabilities exist as annotation fields,
never consumed.

### planning-policy-pack (v26.9.12)

Pure vocabulary + gates pack. Classes: `pp:Policy`, `pp:PolicyBranch`,
`pp:Action`, `pp:Outcome`, `pp:PlannerOutput`, plus HDDL
(`pp:CompoundTask/PrimitiveTask/Method`) and validation/replanning/
explanation classes. Gate `010_select_is_not_do.rq` refuses any
`PlannerOutput` with `hasDOAuthority true` — SELECT != DO, BRCE is the
only DO path. Profile `permanent-human-twin.ttl` composes HDDL intent
decomposition with FOND outcome branches and requires BRCE for execution.
Qualification fixture `consumer.ttl` (kitchen world) exercises the chain.

## 4. Vocabulary Reconciliation Table

| pack term | ap: term | ash_pplan runtime | gap |
|---|---|---|---|
| pp:Policy | ap:FONDPolicy | `%AshPPlan.FOND{}` + `policy` map | 1:1 concept; pack has no strong/strong-cyclic mode |
| pp:PolicyBranch | (none; implicit in policy map + outcomes) | `outcomes(domain,state,action)` | pack branch carries `recoveryAction`; runtime carries outcome->state lists |
| pp:Action + pp:Outcome | (implicit via transitions) | `transitions` relation | pack is nominal (RDF links), runtime is intensional (state->state) |
| pp:hasDOAuthority gate | BRCE authority NONE / CONSTRUCT ceiling | TLA render authority NONE | aligned: both refuse planner output as DO |
| pf:PlannableAction | (none) | `actions/2` admitted actions | pf has cost/duration/probability; runtime has none of these |
| pf:authorityRef | ap: owner/authority surfaces | provider_registry | string URN vs typed authority |
| pp:ValidationResult VALID/INVALID | ap:status | validator verdict `:admitted/:refused` | names differ; semantics match |
| pp:PlannerOutput | FOND.Projection portable map (schema `ash_pplan/fond-projection/v1`) | projection.ex | pack class has no projection schema/subject id |
| pp:HDDL decomposition | ap:FONDPolicy is sibling (prov:Plan) | synthesis.ex | different layer; compose, don't replace |
| pf:no-plan statuses | ap: typed REFUSED/BLOCKED vocabulary | typed refusal maps | pack strings vs typed maps |
| (none) | ap:PolicyState | state terms (any Erlang term) | pack has no state vocabulary at all |
| (none) | (TLC court) | tla/mutation.ex mutants | packs have no falsifier analog |

Table size: 12 rows; 5 aligned, 4 partial (projection adapter needed),
3 pack-side gaps (no modes, no states, no falsifiers).

## 5. What Breaks Under a Naive Swap

Any plan to replace the handwritten FOND core with pack-generated
artifacts breaks:

1. `semantic_reality_fond_court_test.exs` "a retry policy is refused as
   :not_strong but admitted as :strong_cyclic" — neither pack has mode
   semantics; a generated policy source cannot produce the `:not_strong`
   refusal.
2. Same court: "an empty outcome list ... refused, not vacuously
   admitted" — pack vocabulary permits zero branches; the runtime's
   anti-vacuity is `new/2`-level, not representable in pp:.
3. Same court: "validate_policy is deterministic across repeated calls"
   and "no processes are started" — pack path is Python ggen output;
   cross-language determinism/process guarantees are out of scope.
4. `tla_differential_edge_test.exs` "the ontology edge graph validates
   as a FOND domain and renders; reader == elixir" — the court demands
   pack/graph edges EQUAL the Elixir relation; a swap without a
   round-trip reader breaks this identity test.
5. Same court: "TLC: mutant dropping guard:X is refused" — mutation
   court requires the renderer's guard/branch structure
   (`B_<i>_<k>`, `SF_vars` strong-cyclic fairness); the federation
   pack's classical BFS emits nothing with branch structure.
6. `fond_harden_h4_test.exs` line 168/176/187: Differential.check
   contract (typed mismatch maps, checker-shape refusal) — no generated
   backend implements `checker :: (map() -> map())`.

## 6. Verdict

PROCEED — phased, projection-only first. The packs supply vocabulary and
SELECT!=DO authority alignment that matches ash_pplan's authority NONE /
CONSTRUCT ceiling exactly; they do not (and cannot yet) supply FOND
execution semantics. DECLINE is wrong: the vocabulary convergence is
real and the differential court is precisely the falsifier that makes a
later swap court-provable.

## 7. Phased Runbook

### Phase 1 — projection-only, alongside handwritten (low risk)

1. Add a pp:/pf: RDF projection of `FOND.Projection.portable/4`
   (policy, branches per outcome, verdict) into the existing projection
   map — new key, additive only.
2. Ship an adapter in ash_pplan reading pp:Policy/PolicyBranch/
   Outcome graphs into `%AshPPlan.FOND{}` via `FOND.new/2`, feeding the
   existing "ontology edge graph ... reader == elixir" court as the
   gate.
3. Keep handwritten core as the only validator/synthesizer. Run both
   falsifier courts unchanged; they must stay green with zero edits.
4. Gate: `mix test test/fond` green; new projection round-trips through
   the reader adapter byte-identically.

### Phase 2 — court-proven swap (only after phase 1 soak)

1. Extend planning-policy-pack with strong/strong_cyclic mode
   properties + outcome->state edges so pp:PolicyBranch carries
   transition structure (pack-side change, upstream).
2. Generator identity: pack-generated policy graph must satisfy Court A
   verbatim (same test names, unmodified) via the phase-1 reader.
3. Differential court extended: generated-graph policy vs handwritten
   policy over the same domain must agree on verdict AND counterexample
   set (`Counterexample.from_validator` vs `from_checker` parity).
4. TLC mutation court extended to mutants sourced from the generated
   projection.
5. Swap allowed only when all three court families pass on the
   generated source; otherwise remain projection-only (phase 1 steady
   state).

See Also: `lib/ash_pplan/fond/`, `test/fond/semantic_reality_fond_court_test.exs`,
`test/fond/tla_differential_edge_test.exs`, ontology.ttl (ap:FONDPolicy)
