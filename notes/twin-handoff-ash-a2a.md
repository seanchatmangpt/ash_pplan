# Twin Subsystem Handoff: ash_pplan -> AshA2A

Standing: PARTIAL (design delivered here; implementation landed in /Users/sac/ash_a2a/lib/ash_a2a/twin, gate receipt in lane T1 receipt)

## Reclassification

Communicating Digital Twins (v26.11.7 spec §3) are reclassified as
sensory-periphery: they belong in AshA2A (agent communication surface), not
ash_pplan (planning surface). Lane T1 built the subsystem in ash_pplan, then
deleted it in full at operator redirect; this spec plus the ash_a2a
implementation are the deliverables.

## gen_statem actor design

Three twin actors share one `gen_statem` engine (`AshA2A.Twin.Server`,
`callback_mode: :handle_event_function`), dispatched on a `kind` field
(`:asset | :partner | :operator`), each started under the `AshA2A.Twin`
supervisor's `DynamicSupervisor` + `Registry`, in-memory state only:

- **Asset** — operating window + SLA countdown timer (real `gen_statem`
  event timer, `{{:timeout, :sla}, sla_ms, ref}`). `record_activity/2` opens
  and rearms the window; `disarm/1` cancels. Emits
  `{:sla_expired, name, meta}` to the configured listener.
- **Partner** — shift state (`:on_shift` / `:off_shift`) + empirical
  response-latency distribution via the hazard monitor. `dispatch/2` marks an
  outstanding dispatch; `response/2` feeds a latency; `ack/1` acknowledges.
  Emits `{:hazard_tripped, name, z, stats}` only for an unacknowledged
  outstanding dispatch while on shift; `{:shift_changed, name, shift}` on
  flips.
- **Operator** — queue (`:queue`) + attention budget. `enqueue/2`,
  `attend/1` (dequeue + consume budget; fail-closed no-op at zero budget),
  `recharge/1`. Emits `{:budget_exhausted, name, meta}`.

Wrapper modules (`Asset`, `Partner`, `Operator`) own the public API and
`child_spec/1`; the engine holds no per-kind module references.

## Hazard median/MAD/Z semantics

`AshA2A.Twin.Hazard` — semantics mirror the manufactured
`latency-hazard-radar` pack (`ggen-marketplace/packs/latency-hazard-radar/`)
without depending on it:

- ring buffer of observations, oldest evicted past capacity (default 64)
- `median/1`: sorted middle element, average-of-two-middle for even length
- `mad/1`: median of absolute deviations from the median; `0.0` for empty or
  zero-dispersion windows
- `zscore/2`: `Z = (x - median) / MAD`; `MAD == 0` ->
  `{:error, :insufficient_dispersion}` (typed, never division by zero)
- `trip?/2`: strictly greater than threshold (default 2.5, configurable per
  partner; may be sigma or absolute seconds for hours-before-SLA semantics)
- `observe/2`: push then estimate; returns `{:ok, %{z, median, mad, trip?,
  window, monitor}}` — the updated monitor is in the map so callers can
  advance state without re-pushing

Known witness: window `[100, 102, 98, 105, 95]` -> median `100.0`, MAD
`2.0`, `Z(106) = 3.0` (trips at 2.5); `Z = threshold` does NOT trip.

## Monotonic lease CAS shape

`AshA2A.Twin.Lease` — `%Lease{id, holder, granted_at, lease_until,
renewed_count}`:

- `grant/4`: monotonic (`:erlang.monotonic_time/1`), positive duration only
  (`{:error, :invalid_duration}` otherwise)
- `renew/4`: CAS on holder — only the current holder extends; foreign
  claimants get `{:error, :not_holder}`
- `expired?/3` / `held?/3`: fail-closed (wrong holder or past-due = expired);
  a zombie task is expiry without renewal
- `revoke/2`: holder or `:force`; revoked leases read expired
- clock injection seam `clock_now/1` with `clock: {:mono, fun}` — tests
  inject clock funs, no `Process.sleep` for synchronization; bounded polls
  only for async transitions

Shape-compatible with ash_pplan's durable `renew_claim` (`claimed_by` /
`lease_until`, fail-closed) but intentionally independent.

## Integration seams AshA2A needs

1. **Hazard trip consumption**: `{:hazard_tripped, name, z, stats}` is the
   handoff event; a supervision/recovery module (e.g. semantic replan or
   telemetry bridge) subscribes as the twin's `listener:` pid and can gate
   replan dispatch on trips.
2. **Lease as replan claim**: `AshA2A.Twin.Lease` can back in-flight replan
   work claims — same fail-closed shape as durable claims, actors-local.
3. **SLA expiry as task escalation**: asset `{:sla_expired, name, meta}`
   maps naturally onto A2A task deadline-exceeded escalations.
4. **Clock injection**: `clock_now/1` is the seam for any existing module to
   adopt injected monotonic time instead of re-implementing arithmetic.
5. **Start order**: `AshA2A.Twin` supervisor (`DynamicSupervisor` +
   `Registry` children) can be added to the application supervision tree;
   tests start it standalone per test module (unique outer name, shared
   child names — run `async: false`).

## ash_pplan file actions (disclosure)

Created then deleted at redirect (net zero, nothing pre-existing touched):
`lib/ash_pplan/twin.ex`, `lib/ash_pplan/twin/{server,hazard,lease,asset,partner,operator}.ex`,
`test/twin/twin_test.exs`, `docs/diataxis/explanation/digital-twins.md`.
