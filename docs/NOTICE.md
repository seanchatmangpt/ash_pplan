# NOTICE

## Attribution: mbuhot/magma

The native durable engine `AshPPlan.Reactor.Durable.*` has a design derived from mbuhot/magma. The upstream `mix.exs` declares the MIT license; the upstream repository ships no LICENSE file.

- Derived: the design (checkpointed steps replayed through their implementations, signals and waiters, claim leases, newest-first unwinding, guarded status transitions).
- Not copied: the code. The engine was re-implemented for Reactor 1.0.7, Ash 3.33 and the `AshPPlan.Workflow` model.
- Not depended on: ash_pplan has no dependency on magma, Oban or Postgres.

Each derived module carries the line "Design derived from mbuhot/magma (MIT per its mix.exs)".
