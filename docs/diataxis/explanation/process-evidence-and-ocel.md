# Process evidence and OCEL

Workflow runs leave evidence in two shapes: in-memory process-evidence events
built from an execution receipt, and durable-run checkpoint ledgers exported as
OCEL 2.0 JSON. Both feed the standing layers and the receipt's evidence field.

## ProcessEvidence: events from a receipt

`AshPPlan.ProcessEvidence.events_from_receipt/3`
(`lib/ash_pplan/process_evidence.ex`) projects an
`%AshPPlan.ExecutionReceipt{}` into `AshPPlan.ProcessEvidence.Event` structs:
an `attempted`/`succeeded` (or `failed`) event pair per task; tasks after a
failure are never attempted, so the log shows the run as it actually went.
Options: `:tasks`, `:realizations`, `:failed_task`.

`Event` struct (`lib/ash_pplan/process_evidence/event.ex`):
`id, activity, timestamp, objects, attributes, subject_id` — one subject id on
every event binds the log to the workflow subject the standing receipt cites.

`ProcessEvidence.export/2` serializes events as pure OCEL 2.0 JSON
(`{:ok, String.t()} | {:error, map()}`; requires Jason; any other format is
refused with `:unsupported_format`). The export is pure — no dependency on a
running system — so it is safe to diff, hash, or archive.

## LedgerOCEL: durable runs as process evidence

`AshPPlan.Reactor.Durable.LedgerOCEL`
(`lib/ash_pplan/reactor/durable/ledger_ocel.ex`) exports a durable run's
standing checkpoint ledger as process-mining evidence:

- `LedgerOCEL.events/3` — `(store, run_id, opts)`; one `task_succeeded` event
  per standing checkpoint (ordered by the ledger's monotonic `seq`, carried in
  attributes), plus `run_started` / `run_ended` events carrying the run's
  terminal status, and each event carries the workflow subject id from the run
  context when present.
- `LedgerOCEL.export/3` — the same events through
  `ProcessEvidence.export(events, :ocel2_json)`.
- `LedgerOCEL.digest/3` — sha256 over `{id, activity, attributes}` of every
  event; changes if any standing output changes. This is the digest the
  standing receipt's `derived_from` cites ("ledger &lt;digest&gt; at &lt;head&gt;").

Honesty note (from the module doc): checkpoint rows carry no wall-clock
timestamps, so event timestamps reflect export time; the authoritative order is
the ledger's `seq`. Design lineage: mbuhot/magma's ledger idea, re-implemented
(see `docs/NOTICE.md`).

## The ex4pm adapter

`AshPPlan.ProcessEvidence.Ex4pm`
(`lib/ash_pplan/process_evidence/ex4pm.ex`) maps `ProcessEvidence.Event` to
`Ex4pm.Event` / `Ex4pm.EventLog` and serializes the real `Ex4pm.EventLog` to
OCEL 2.0 JSON; `parse/2` reads it back through the real reader
`Ex4pm.OCEL.normalize/1`.

Ex4pm is a test/dev-only dependency: every reference is guarded by
`Code.ensure_loaded?/1` and made via `apply/3`/`struct!/2`, so ash_pplan
compiles without it. When it is absent (or `available?: false` is passed), every
call returns
`{:error, %{reason: :unsupported, detail: :ex4pm_not_available}}` — absence is
reported, never faked.

## How the pieces connect

`AshPPlan.Standing.receipt/2` consumes all three: `:evidence` (default `true`)
adds the OCEL 2.0 JSON sha256 of the run's process evidence plus the guarded
ex4pm validation status, and the receipt's `standing` field anchors itself to
the ledger digest — see
[Standing, receipts, and the ladder](standing-receipts-and-the-ladder.md).
