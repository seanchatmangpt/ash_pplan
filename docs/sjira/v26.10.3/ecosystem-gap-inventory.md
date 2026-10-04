# Ecosystem Gap Inventory — ash_pplan v26.10.3

Measured 2026-10-04, lane GAP-INVENTORY. Replaces the research report's inferred
headroom caveat with per-extension evidence. Sources: `mix.exs`, `mix.lock`,
grep over `lib/` and `test/`.

## Dependencies present (mix.exs + mix.lock)

ash 3.33.11 · reactor 1.0.7 · reactor_req 0.1.7 · reactor_file 0.18.5 ·
reactor_process (vendored) · ash_state_machine 0.2.13 · ash_oban 0.9.0 (pulls oban
2.24.1) · spark 2.7.3 · ggen_igniter 26.10.2 · igniter 0.8.4 (transitive) ·
ex4pm/ash_ex4pm 26.10.x (dev/test) · simple_sat (test) · bb_reactor 0.2 (dev/test).

## Inventory table

Statuses: **adopted** = extension's DSL/runtime used directly;
**projected** = extension consumed read-only/projection-only (a form of adopted,
noted separately because the control plane deliberately never performs transitions
or schedules jobs itself); **hand-rolled** = local implementation of what the
extension would provide; **absent** = no dep, no usage.

| Extension / feature | Dep present? | Usage evidence (file:line) | Status | Generating pack |
|---|---|---|---|---|
| Ash (core) | yes 3.33.11 | whole `lib/` compiles against Ash.Query/Changeset/ActionInput | adopted | ash-extension-core-pack |
| Spark | yes 2.7.3 | `lib/ash_pplan/compiler.ex:177` (behaviour check admission) | adopted | ash-extension-core-pack |
| Reactor (core) | yes 1.0.7 | `lib/ash_pplan/compiler.ex` (Reactor.Builder compilation), `lib/ash_pplan/reactor.ex:189` (add_middleware) | adopted | ash-extension-pack |
| Reactor middleware | yes | `lib/ash_pplan/reactor/middleware/{identity,evidence,observation}.ex` (`use Reactor.Middleware`), `reactor.ex:189` | adopted | ash-extension-pack |
| Reactor compensate/undo | yes | `lib/ash_pplan/reactor/durable/checkpointed.ex:47` (compensate/4), `reactor/durable/migration.ex:370` (compensate_orphans) | adopted | ash-extension-pack |
| AshOban | yes 0.9.0 | `lib/ash_pplan/oban.ex:34,109,227,302` (Info, Trigger/Schedule structs, `build_trigger/3`, `check_for_oban_return`) | projected (DSL never declared locally — no `use AshOban` in lib/ or test/; test/oban_test.exs drives the projection against structs, not the DSL) | ash-extension-pack |
| Oban | yes 2.24.1 (transitive via ash_oban) | `lib/ash_pplan/oban.ex` (CONSTRUCT-only job boundary) | projected | ash-extension-pack |
| AshStateMachine | yes 0.2.13 | `lib/ash_pplan/state_machine.ex:17-19` (BuiltinChanges, ValidNextState check), `StateMachine.from_resource` | projected (consumed via Info/BuiltinChanges; no `use Ash.StateMachine` resource is defined in this repo) | ash-extension-core-pack |
| Ash.Reactor (generic/ash_step/domain kinds) | not a dep (ships inside ash) | `lib/ash_pplan/reactor/adapters/ash_reactor.ex:7-22` — adapter maps `domain_create/read/update/destroy/action` onto a **local** `Steps.DomainAction` step that calls Ash directly (Ash.Changeset.for_create etc.), NOT `Ash.Reactor` kinds. `available?/0` probes `Code.ensure_loaded?(Ash.Reactor)` | hand-rolled (the Ash.Reactor extension's step kinds are reimplemented locally; only its availability is probed) | ash-extension-pack |
| Reactor extensions (reactor_req / reactor_file / reactor_process) | yes | adapters `lib/ash_pplan/reactor/adapters/{reactor_req,reactor_file,reactor_process}.ex` | adopted | ash-extension-pack |
| Bulk actions (Ash.bulk_create/bulk_update/bulk_destroy) | n/a (core ash API) | zero hits for `bulk_create|bulk_update|bulk_destroy` in lib/ and test/ | absent | no pack — author one (candidate: `ash-extension-pack` extension or new `ash-pplan-bulk-surface-pack`) |
| AshPaperTrail | no | zero hits in lib/ and test/ | absent | no pack — author one |
| AshCloak | no | zero hits in any file | absent | no pack — author one |
| AshGraphql | no | zero hits | absent | no pack — author one |
| AshJsonApi | bandit/plug present in dev/test but no AshJsonApi dep | zero hits | absent | no pack — author one |
| AshAuthentication | no | zero hits | absent | no pack — author one (only `actor_persister` surface via AshOban.Info at `oban.ex:329`) | 
| dsl_patches / Spark Dsl.Patch | n/a | zero hits for `dsl_patches|Dsl.Patch` in lib/ | absent | no pack — author one (pack-authoring-pack covers pack mechanics, not the dsl_patches pattern) |

## Counts

- adopted: 6 (Ash, Spark, Reactor core, middleware, compensate, reactor_* extensions)
- projected: 3 (AshOban, Oban, AshStateMachine — dep present, read-only consumption,
  no local DSL declaration)
- hand-rolled: 1 (Ash.Reactor step kinds via local `Steps.DomainAction`)
- absent: 7 (bulk actions, AshPaperTrail, AshCloak, AshGraphql, AshJsonApi,
  AshAuthentication, dsl_patches)

## Notes

1. `test/oban_test.exs` and `test/state_machine_test.exs` are projection tests
   against AshOban/AshStateMachine **structs and Info functions**, not DSL users —
   neither file declares `use AshOban` or `use Ash.StateMachine`. The repo defines
   zero Ash resources of its own; it is a compiler/projection control plane over
   consumer resources.
2. The `Steps.DomainAction` step (`lib/ash_pplan/reactor/steps/domain_action.ex`)
   reimplements what `Ash.Reactor`'s `ash_create/ash_read/ash_update/ash_destroy/
   ash_action` kinds provide; swapping it onto Ash.Reactor kinds is the single
   highest-signal hand-rolled → adopted conversion available.
3. `mix.exs:17` description claims "control plane over Ash, AshStateMachine,
   Reactor and AshOban" — consistent with measured status: those four are the only
   extensions touched, all read-only/projected except Reactor, which is compiled
   against directly.
