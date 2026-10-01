defmodule AshPPlan.Reactor.Durable.Record do
  @moduledoc "Durable run record. Persists the Model + bindings (data), never a module."
  @enforce_keys [:id]
  defstruct id: nil,
            plan_iri: nil,
            model: nil,
            bindings: %{},
            inputs: %{},
            context: %{},
            status: :pending,
            result: nil,
            error: nil,
            intent: nil,
            parent_id: nil,
            parent_signal: nil,
            claimed_at: nil,
            claimed_by: nil,
            version: 0,
            seq: 0

  @type t :: %__MODULE__{}
end

defmodule AshPPlan.Reactor.Durable.Checkpoint do
  @moduledoc "One standing step output. `impl`/`args` are snapshotted so unwind needs no rebuild."
  @enforce_keys [:run_id, :step_key]
  defstruct run_id: nil,
            step_key: nil,
            label: nil,
            name: nil,
            output: nil,
            impl: nil,
            args: nil,
            seq: 0,
            undone_at: nil

  @type t :: %__MODULE__{}
end

defmodule AshPPlan.Reactor.Durable.Signal do
  @moduledoc "A delivered signal, consumed at most once, FIFO per name by `seq`."
  @enforce_keys [:id, :run_id, :name]
  defstruct id: nil, run_id: nil, name: nil, payload: nil, consumed_at: nil, seq: 0

  @type t :: %__MODULE__{}
end

defmodule AshPPlan.Reactor.Durable.Waiter do
  @moduledoc "What a parked run waits on. `deadline` is measured once."
  @enforce_keys [:run_id, :name]
  defstruct run_id: nil, name: nil, kind: :signal, deadline: nil

  @type t :: %__MODULE__{}
end
