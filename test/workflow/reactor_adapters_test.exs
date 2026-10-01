defmodule AshPPlan.ReactorAdaptersTest do
  use ExUnit.Case, async: true
  alias AshPPlan.{Realization, Reactor}

  defp real(adapter, op, options \\ []) do
    %Realization{
      capability: "X.Y",
      provider: :t,
      binding: %{adapter: adapter, op: op},
      options: options
    }
  end

  test "every op of every available adapter resolves to a Reactor.Step module" do
    for {id, mod} <- Reactor.adapters(), mod.available?(), op <- mod.ops() do
      assert {:ok, {step, kw}} = Reactor.step_for(real(id, op)), "#{id}/#{op}"
      assert Code.ensure_loaded?(step) and is_list(kw)
    end
  end

  test "ops tables cover the legacy provider capabilities" do
    expected = %{
      reactor_file: ~w(file_read file_write file_copy file_delete file_mkdir)a,
      reactor_req:
        ~w(network_get network_post network_put network_patch network_delete network_head remote_read)a,
      reactor_process: ~w(process_start process_count process_terminate)a,
      ash_reactor: ~w(domain_create domain_read domain_update domain_destroy domain_action)a,
      ultracode:
        ~w(work_observe work_select agent_execute work_integrate verification_check repository_observe repository_integrate verification_run evidence_record authority_check)a
    }

    for {id, ops} <- expected do
      assert Enum.sort(Reactor.adapters()[id].ops()) == Enum.sort(ops)
    end
  end

  test "options merge over adapter defaults" do
    assert {:ok, {Elixir.Reactor.Req.Step, kw}} =
             Reactor.step_for(real(:reactor_req, :network_get, retry: false))

    assert kw[:fun] == :get and kw[:retry] == false
  end

  test "unknown op, unknown adapter and invalid binding are typed unsupported" do
    assert {:error, %{reason: :unsupported, adapter: :reactor_file, detail: {:unknown_op, :nope}}} =
             Reactor.step_for(real(:reactor_file, :nope))

    assert {:error, %{reason: :unsupported, detail: :unknown_adapter}} =
             Reactor.step_for(real(:bogus, :file_write))

    assert {:error, %{reason: :unsupported}} =
             Reactor.step_for(%Realization{capability: "A.B", provider: :t, binding: nil})
  end

  defmodule NotAStepAdapter do
    @behaviour AshPPlan.Reactor.Adapter
    def id, do: :local
    def available?, do: true
    def ops, do: [:file_write]
    def step(:file_write, _), do: {:ok, {Enumerable, []}}
  end

  test "mutation: an adapter returning a non-Reactor.Step module is rejected" do
    adapters = Map.put(Reactor.adapters(), :local, NotAStepAdapter)

    assert {:error, %{reason: :not_a_step, module: Enumerable}} =
             Reactor.step_for(real(:local, :file_write), adapters: adapters)

    assert {:error, %{reason: :not_a_step}} = Reactor.validate_step(String)
    assert :ok = Reactor.validate_step(Elixir.Reactor.File.Step.WriteFile)
  end
end
