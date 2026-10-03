# ash_pplan v26.9.6 — Working Backwards Press Release

**September 6, 2026** — `ash_pplan` makes technology-neutral P-PLAN and W3C PROV-O semantics the interface for process definition and observation in the Ash ecosystem.

Instead of beginning with Reactor steps, Oban workers, cron entries, or framework-specific workflow terminology, applications can begin with plans, steps, variables, activities, entities, and agents. `ash_pplan` projects those semantics onto the mature capabilities already present in Reactor, Ash.Reactor, AshOban, Oban scheduling, and Ash.

The release deliberately introduces no new queue, scheduler, retry engine, transaction engine, or general workflow executor. Reactor remains responsible for dependency-driven execution, retry, compensation and undo. Ash remains responsible for domain state and authority. AshOban remains responsible for background delivery and scheduled activation.

The result is a semantic composition layer rather than another workflow product.

v26.9.6 also makes one boundary explicit: durable persistence of an arbitrary halted Reactor continuation is not claimed merely because Oban persists jobs. That capability remains an admitted gap until concrete applications prove the narrow primitive required to fill it.

The acceptance criterion is simple: a process must remain understandable without knowing Ash, Reactor, Oban, Elixir, or any particular implementation technology, while its Ash implementation remains deterministically manufacturable from the admitted semantic source.
