# Gate Receipt: Dashboard Boot Smoke — 2026-10-04

Subject: `/Users/sac/ash_pplan` @ `9a89aac3d95c079cd7c461bf50777789aa340882` (current tree, uncommitted working changes present; no source files modified by this run).

## Result: ALIVE (both routes, HTTP 200)

## Commands and outputs

### 1. Cold boot (FAILED — timeout, environmental not code)

```
MIX_BUILD_ROOT=_build-boot-smoke timeout 90 bash -c 'bin/dashboard --port 4137 > /tmp/dash-boot.log 2>&1 & sleep 45; curl -s -o /tmp/dash1.html -w "%{http_code}" http://localhost:4137/; echo; curl -s -o /tmp/dash2.html -w "%{http_code}" http://localhost:4137/dashboard'
```

Output: `000` / `000`. Cause: cold `MIX_BUILD_ROOT` compiled deps from scratch; at t=45s the log showed deps still compiling (`==> jason`, `Compiling 10 files`); timeout SIGTERM at 90s killed mix mid-compile. Boot log tail (verbatim):

```
01:13:43.302 [notice] SIGTERM received - shutting down

** (ArgumentError) errors were found at the given arguments:
  * 1st argument: the table identifier does not refer to an existing ETS table
    (stdlib 7.2) :ets.lookup(Mix.State, :debug)
    (mix 1.19.5) lib/mix/state.ex:30: Mix.State.get/2
    /opt/homebrew/bin/mix:7: (file)
{exit,{noproc,{gen_server,call,[elixir_config,{get_and_put,at_exit,[]},infinity]}} ...
```

Environmental (90s timeout < cold-compile time), not a serving-surface defect.

### 2. Warm boot (PASSED)

Pre-warmed build root: `MIX_BUILD_ROOT=_build-boot-smoke MIX_ENV=test mix compile` → exit 0 (`Compiling 263 files (.ex)` / `Generated ash_pplan app`).

```
(MIX_BUILD_ROOT=_build-boot-smoke bin/dashboard --port 4137 > /tmp/dash-boot.log 2>&1 &)
poll curl until connect, then:
curl -s -o /tmp/dash1.html -w '%{http_code}' http://localhost:4137/          -> 200
curl -s -o /tmp/dash2.html -w '%{http_code}' http://localhost:4137/dashboard -> 200
pkill -f dashboard_boot.exs; lsof -ti:4137 -> empty (port-free verified)
```

## Marker greps (saved HTML)

### `/` → /tmp/dash1.html (28510 bytes, sha256 b83f315a…d9e603)
- `p-plan`: 131 occurrences (128+1+2)
- `GCP Marketplace Lifecycle Explorer` (title/heading) present
- `P-Plan`/`P-PLAN`/`marketplace`: present
- Stakeholder roster rendered: Sarah Chen, David Ross, Elena Vance, Kenji Sato, Liam Sterling, Marcus Thorne, Rachel Adams, Tariq Al-Mansoor

### `/dashboard` → /tmp/dash2.html (11342 bytes, sha256 703b7c09…19f99)
- `ash_pplan Fleet Dashboard` (page heading) present
- `Fleet Dashboard`: 1; Step sections: `Live Step Events`, `Real-Time Step Events (newest first)`, `Durable Runs (real ETS ledger)`, `Standing Tape (real checkpoints)`, `Start a REAL durable run`, `Capability Catalog`, `FinOps Commitment Panel`
- `Pool Gain 3500000 / Organic Burn 1100000 / Remaining Pool 3900000 / Post-Deal Pool` values rendered
- LiveView session payload decodes to view `Elixir.AshPplan.MarketplaceSim.DashboardLive`, router `Elixir.AshPplan.MarketplaceSim.Router`

## Cleanup

- Server killed (`pkill -f dashboard_boot.exs`); `lsof -ti:4137` empty (verified port-free).
- `_build-boot-smoke` deleted (verified: `No such file or directory`).
- No git operations. No source files modified.
