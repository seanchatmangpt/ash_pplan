# Anti-vacuity Mutation Tests

Executable anti-vacuity court for the durable engine's adversarial courts and the standing
falsifier. Each `*_mutation_test.exs` file here takes the real production module source, applies
one mechanical break, compiles the mutated copy in-process under a `Mutation.*` module name
(`Code.compile_string/1`), and runs the property the court asserts against BOTH the production
module and the mutated copy. The property must hold for the production module and be violated by
the mutated copy — if the mutated copy still satisfies the property, the court is vacuous and
that is a real defect.

Mutations:

| file | target | mutation |
|---|---|---|
| `migration_orphan_mutation_test.exs` | `Migration.classify/3` orphan refusal | `classify/3` never refuses (orphans admitted) |
| `counterfactual_digest_mutation_test.exs` | `Counterfactual.do_replay/5` scratch store | replay runs against the original store, mutating the original ledger |
| `policy_driver_admit_mutation_test.exs` | `PolicyDriver.admit/1` | admits any hand-built driver unconditionally |

The standing-falsifier mutation lives at `test/workflow/standing_falsifier_mutation_test.exs`
(standing receipts issued without observed-consequence evidence).

Chicago discipline: no mocks anywhere — every case runs the real store, real engine, real FOND
synthesis, and the real (mutated-copy) module compiled from the production source.
