# Lane V7 — Sealed-Package Boundary Validation (2026-11-07)

Standing: PARTIAL

Subject: `/Users/sac/ash_pplan` @ HEAD ea21645 (WIP snapshot tree). No git
commands run; build/unpack/compile only.

## Verdict table

| # | Check | Verdict | Evidence |
|---|---|---|---|
| 1 | `mix hex.build` (via `bin/verify-package`) | PASS | tarball `ash_pplan-26.11.7.tar` (857 KB) produced; script exited 0 through the build step |
| 2 | Exclusion census of unpacked tarball | PASS | absent from tar: `priv/courts` (incl. `airbus_parity/corpus` + `courts/corpus` — `priv/` in tar holds only airo/overlay/ggen/mappings/schemas/tla/vendor), `lib/mix`, `scripts/`, `test/`, `notes/`, `receipts/`, `docs/sjira`, `docs/jira` |
| 2b | New-dir leak census | **FLAG** | PRESENT in tar: `lib/ash_pplan/telemetry` (4 files), `lib/ash_pplan/airbus` (2 files), `lib/ash_pplan/playground` (3 files). Top-level `telemetry/`, `airbus/`, `playground/` dirs: absent (no leak at that level) |
| 3 | Unpacked standalone compile (`MIX_ENV=prod mix compile --warnings-as-errors`) | **FAIL — real exit 1** | `AshPPlan.Playground.TelemetryBroadcaster` (lib/ash_pplan/playground/telemetry_broadcaster.ex:21/28/35) calls `Phoenix.PubSub.broadcast/3`; phoenix is `only: [:dev, :test]` in mix.exs:113, so the dep is absent in the unpacked prod compile. 3 warnings → warnings-as-errors → `REAL_EXIT=1` (second run, unpiped rc; the first run's `EXIT=0` was the `tail` pipe's rc) |
| 4 | Version coherence inside artifact | PASS | tar `mix.exs` @version `26.11.7` == tar `ontology.ttl` `owl:versionInfo "26.11.7"` == tar CHANGELOG head `26.11.7 (DRAFT)`; in-tree `lib/ash_pplan.ex:31` derives @version from Mix.Project dynamically (no hardcode to drift) |
| 5 | bin/receipt zero-arity (D4) packaging impact | no packaging impact | `bin/receipt` ships in the tar but verify-package never invokes it; it is git-bound (`git rev-parse HEAD`) and would fail in a consumer checkout — a repo-tool that arguably does not belong in the package, LOW |

## Decision point recorded: playground leak

`lib/ash_pplan/playground/` (engine_bridge.ex, scenario_runner.ex,
telemetry_broadcaster.ex) IS in the hex package. D1 documented playground as a
WIP surface; it now breaks the package compile outright because
telemetry_broadcaster's Phoenix.PubSub call has no prod dep behind it. Options:
(a) reject `lib/ash_pplan/playground` in `package_files/2` "lib" clause
(matches existing lib/mix precedent), or (b) make the phoenix dep prod-scoped.
Recorded, not repaired — this lane is validation-only.

## Tarball census summary

- `ash_pplan-26.11.7.tar`, 877,568 bytes, 887 files unpacked, ~7 MB on disk.
- Exclusion boundary otherwise holds for every probed path.

## Falsifier / replay

- `./bin/verify-package` → exit 1 (reproduced twice; unpiped `rc=$?` on second run).
- Census: tar -xf → contents.tar.gz → per-path `ls -d` probes (all probed paths reported above).

See Also: `bin/verify-package`, `mix.exs package_files/2`, `receipts/INDEX-2026-10-04.md`
