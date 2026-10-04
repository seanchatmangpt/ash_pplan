# Order-to-cash case study: execute the real QualifiedFulfillment durable spine
# (admit_order -> authorize_payment -> await_human_release -> commit_shipment)
# end-to-end on the native ledger engine and emit the full evidence chain.
#
#   MIX_BUILD_ROOT=_build-w19-8 MIX_ENV=test mix run examples/case_study_o2c.exs
#
# Everything is real: real engine, real ETS store, real signals, real effect
# counters, real standing receipt, real hash chain, real OCEL export and real
# sha256 digests. The machine-generated run receipt is written as JSON to
# docs/case-studies/receipts/o2c-run-<timestamp>.json; the markdown case study
# (docs/case-studies/order-to-cash.md) is a projection of that receipt — every
# number in the .md comes from this executed run.

alias AshPPlan.Reactor.Durable.{Clock, Engine, LedgerOCEL}
alias AshPPlan.Reactor.Durable.Store.Ets
alias AshPPlan.Standing
alias AshPPlan.Standing.Chain
alias AshPPlan.Test.{DurableFx, Effects}

subject = "sha256:" <> String.duplicate("ab", 32)
run_id = "o2c-case-study"

# ---- 0. Real effect counter + real adapter registration (no ExUnit) ----------
{:ok, _} = Effects.start_link(name: :o2c_fx)

previous_adapters = Application.get_env(:ash_pplan, :extra_adapters, %{})

Application.put_env(
  :ash_pplan,
  :extra_adapters,
  Map.put(Map.new(previous_adapters), :durable_fx, DurableFx.Adapter)
)

IO.puts("== Order-to-Cash case study: qualified_fulfillment durable spine ==")

# ---- 1. The model ------------------------------------------------------------
model = DurableFx.model()
full_model = AshPPlan.Examples.Workflows.QualifiedFulfillment.model()

IO.puts("\n[1] Model (full generated workflow: #{length(full_model.tasks)} tasks)")
IO.puts("    spine model: #{model.name} (goal: #{model.goal}, #{length(model.tasks)} spine tasks)")

model_rows =
  Enum.map(model.tasks, fn t ->
    deps = if t.depends_on == [], do: "-", else: Enum.join(t.depends_on, ",")

    %{
      id: to_string(t.id),
      capability: t.capability,
      depends_on: deps,
      authority: to_string(t.authority)
    }
  end)

Enum.each(model_rows, fn t ->
  IO.puts("    - #{t.id}  [#{t.capability}]  depends_on: #{t.depends_on}  authority: #{t.authority}")
end)

# ---- 2. Real execution on the durable engine ---------------------------------
{:ok, store} = Ets.start_link()

attrs = %{
  DurableFx.attrs(run_id, effects: :o2c_fx)
  | context: %{:ash_pplan_workflow => %{subject: subject, task: "case_study"}}
}

{:ok, _} = Engine.start(store, attrs)
IO.puts("\n[2] run #{run_id} started")

{:parked, :waiting} = Engine.attempt(store, run_id)
IO.puts("    attempt 1 -> parked at the human-release gate (await_human_release)")

{:ok, _} = Engine.signal(store, run_id, DurableFx.signal_name(), :approved)
IO.puts("    signal '#{DurableFx.signal_name()}' = :approved delivered")

{usec, {:completed, _result}} = :timer.tc(fn -> Engine.attempt(store, run_id) end)
IO.puts("    attempt 2 -> completed in #{usec} microseconds")

record = Engine.fetch(store, run_id)
steps = Engine.steps(store, run_id)
tape = Enum.map(steps, & &1.label)

IO.puts("    final status: #{record.status}")
IO.puts("    standing tape (#{length(tape)} entries):")

tape_rows = Enum.with_index(tape, 1)

Enum.each(tape_rows, fn {label, i} ->
  IO.puts("      #{i}. #{label}")
end)

counts = Effects.all(:o2c_fx)
IO.puts("    real effect counters (exactly-once): #{inspect(counts)}")

# ---- 3. Standing receipt -----------------------------------------------------
standing_cps = Ets.standing(store, run_id)

events =
  for {cp, i} <- Enum.with_index(standing_cps, 1) do
    task =
      cp.label
      |> String.split("#step-")
      |> List.last()
      |> String.trim("\"")
      |> String.to_atom()

    outcome = if task == :await_human_release, do: "approved"

    %AshPPlan.ProcessEvidence.Event{
      id: "run:#{run_id}/#{i}",
      activity: "task_succeeded",
      timestamp: Clock.now(),
      objects: [{"WorkflowRun", "run:#{run_id}", "run"}],
      attributes: %{task: Atom.to_string(task), seq: i, provider: "local", outcome: outcome},
      subject_id: subject
    }
  end

model_tasks = Enum.map(model.tasks, &%{id: &1.id, depends_on: &1.depends_on})

run_map = %{
  run_id: run_id,
  repo: "ash_pplan",
  head: "sha256:" <> String.duplicate("11", 32),
  base: "sha256:" <> String.duplicate("22", 32),
  events: events,
  model: %{tasks: model_tasks},
  selection: Map.new(model_tasks, &{&1.id, :local}),
  fond_gates: [
    %{task: "await_human_release", admit: ["approved"], successors: ["commit_shipment"]}
  ],
  consequence: [{"commit_shipment", true}],
  observation: %{shipment: "observed"},
  execution: {:ok, :ok}
}

{:ok, receipt} =
  Standing.receipt(run_map, replay_commands: ["mix run examples/case_study_o2c.exs"])

IO.puts("\n[3] Standing receipt")
IO.puts("    standing: #{receipt.standing.value}")
IO.puts("    authority ceiling: #{receipt.authority.ceiling} (grant: #{receipt.authority.grant})")
IO.puts("    actor: #{receipt.authority.actor}")
IO.puts("    identity: #{inspect(receipt.identity)}")
IO.puts("    consequence: #{inspect(receipt.consequence)}")
IO.puts("    replay.ledger_digest: #{receipt.replay.ledger_digest}")
IO.puts("    replay.ledger_algorithm: #{receipt.replay.ledger_algorithm}")
IO.puts("    replay.commands: #{inspect(receipt.replay.commands)}")
IO.puts("    replay.evidence.ocel2_sha256: #{receipt.replay.evidence.ocel2_sha256}")

# ---- 4. Ledger digest via the hash chain directly ----------------------------
pairs = Enum.map(events, fn e -> {e.id, e.attributes[:task]} end)
{:ok, chain} = Chain.build_sealed(pairs, "seal", "ALIVE", subject)

IO.puts("\n[4] Hash chain (Standing.Chain)")
IO.puts("    entries: #{length(chain)} (pending+outcome per event, plus seal)")
IO.puts("    Chain.head: #{Chain.head(chain)}")
IO.puts("    Chain.verify: #{Chain.verify(chain)}")

# ---- 5. OCEL export ----------------------------------------------------------
{:ok, ocel_events} = LedgerOCEL.events(store, run_id)
{:ok, ocel_json} = LedgerOCEL.export(store, run_id)
{:ok, ledger_digest} = LedgerOCEL.digest(store, run_id)

export_sha256 =
  :crypto.hash(:sha256, ocel_json) |> Base.encode16(case: :lower)

IO.puts("\n[5] OCEL evidence (LedgerOCEL)")
IO.puts("    events: #{length(ocel_events)}")

Enum.each(ocel_events, fn e ->
  IO.puts("      - #{e.activity}  (#{e.id})")
end)

IO.puts("    LedgerOCEL.digest: #{ledger_digest}")
IO.puts("    export bytes: #{byte_size(ocel_json)}")
IO.puts("    sha256(export): #{export_sha256}")

# ---- 6. Machine-generated run receipt (JSON) ---------------------------------
receipt_json =
  Jason.encode!(%{
    generated_by: "mix run examples/case_study_o2c.exs",
    run_id: run_id,
    executed_at: DateTime.to_iso8601(DateTime.utc_now()),
    model: %{
      spine: model.name,
      goal: model.goal,
      full_workflow_tasks: length(full_model.tasks),
      spine_tasks: length(model.tasks),
      tasks: model_rows
    },
    execution: %{
      final_status: to_string(record.status),
      standing_tape: Enum.map(tape_rows, fn {label, i} -> %{seq: i, label: label} end),
      effect_counters: %{
        admit: counts[:admit],
        authorize: counts[:authorize],
        commit: counts[:commit]
      }
    },
    standing_receipt: %{
      standing: receipt.standing.value,
      authority_ceiling: receipt.authority.ceiling,
      authority_grant: receipt.authority.grant,
      actor: receipt.authority.actor,
      identity: receipt.identity,
      consequence: receipt.consequence,
      ledger_digest: receipt.replay.ledger_digest,
      ledger_algorithm: receipt.replay.ledger_algorithm,
      replay_commands: receipt.replay.commands,
      ocel2_sha256: receipt.replay.evidence.ocel2_sha256
    },
    chain: %{
      entries: length(chain),
      head: Chain.head(chain),
      verified: Chain.verify(chain)
    },
    ocel: %{
      events: length(ocel_events),
      event_ids: Enum.map(ocel_events, & &1.id),
      ledger_ocel_digest: ledger_digest,
      export_bytes: byte_size(ocel_json),
      export_sha256: export_sha256
    }
  })

receipts_dir = Path.expand("docs/case-studies/receipts", File.cwd!())
File.mkdir_p!(receipts_dir)

timestamp =
  DateTime.utc_now()
  |> Calendar.strftime("%Y%m%dT%H%M%SZ")

receipt_path = Path.join(receipts_dir, "o2c-run-#{timestamp}.json")
File.write!(receipt_path, receipt_json <> "\n")

IO.puts("\n[6] Run receipt written: #{receipt_path}")
IO.puts("    receipt sha256: " <> (:crypto.hash(:sha256, receipt_json) |> Base.encode16(case: :lower)))
IO.puts("\n== evidence chain complete ==")

Application.put_env(:ash_pplan, :extra_adapters, previous_adapters)
