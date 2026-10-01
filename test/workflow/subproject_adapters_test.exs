defmodule AshPPlan.SubprojectAdaptersTest do
  @moduledoc """
  Court for the bb_reactor, ash_durable_reactor and ash_oban adapters: every op
  resolves to a loadable `Reactor.Step` or a typed unsupported error; the
  approval step halts and resumes through a real Reactor run; the ash_oban step
  constructs a job carrying the continuation reference. Mutations: a missing
  continuation reference is refused, and an absent implementation is typed
  unsupported rather than crashing.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.{Realization, Reactor}
  alias AshPPlan.Reactor.Adapters.{AshDurableReactor, AshOban}

  defp real(adapter, op, options \\ []) do
    %Realization{
      capability: "X.Y",
      provider: :t,
      binding: %{adapter: adapter, op: op},
      options: options
    }
  end

  test "adapters are registered and allowlisted" do
    for id <- ~w(bb_reactor ash_durable_reactor ash_oban)a do
      assert Map.has_key?(Reactor.adapters(), id)
      assert id in Realization.adapters()
    end
  end

  test "every op resolves to a loadable Reactor.Step" do
    for id <- ~w(bb_reactor ash_durable_reactor ash_oban)a,
        mod = Reactor.adapters()[id],
        mod.available?(),
        op <- mod.ops() do
      assert {:ok, {step, _kw}} = Reactor.step_for(real(id, op)), "#{id}/#{op}"
      assert :ok = Reactor.validate_step(step)
    end
  end

  test "capability ops map as specified" do
    assert Realization.op_for("Actuator.Command") in Reactor.adapters()[:bb_reactor].ops()
    assert Realization.op_for("State.Await") in Reactor.adapters()[:bb_reactor].ops()
    assert Realization.op_for("Human.Approve") in AshDurableReactor.ops()
    assert Realization.op_for("Schedule.Deferred") in AshOban.ops()
  end

  test "mutation: absent implementation and unknown ops are typed unsupported" do
    for id <- ~w(bb_reactor ash_durable_reactor ash_oban)a do
      op = hd(Reactor.adapters()[id].ops())

      assert {:error, %{reason: :unsupported, adapter: ^id, detail: :implementation_unavailable}} =
               Reactor.step_for(real(id, op, available?: false))

      assert {:error, %{reason: :unsupported, adapter: ^id, detail: {:unknown_op, :nope}}} =
               Reactor.step_for(real(id, :nope))
    end
  end

  describe "human approval step (halt/resume)" do
    defp run_approval(options, context \\ %{}) do
      {:ok, {step, kw}} = Reactor.step_for(real(:ash_durable_reactor, :human_approve, options))
      step.run(%{}, context, kw)
    end

    test "halts without a decision and on still_waiting" do
      assert {:halt, %{awaiting: :approval}} = run_approval([])
      assert {:halt, %{awaiting: :approval}} = run_approval(decision: :still_waiting)
    end

    test "completes on approved or refused, from option or resume context" do
      assert {:ok, %{decision: :approved}} = run_approval(decision: :approved)
      assert {:ok, %{decision: :refused}} = run_approval([], %{private: %{decision: :refused}})
    end

    test "durable resume callback honours the stored payload" do
      assert {:ok, %{decision: :approved}} =
               AshDurableReactor.Approve.resume(%{}, %{}, [], %{
                 resume_payload: %{decision: :approved}
               })

      assert {:halt, _} = AshDurableReactor.Approve.resume(%{}, %{}, [], %{resume_payload: nil})
    end

    test "a real Reactor halts at the approval step" do
      {:ok, {step, kw}} = Reactor.step_for(real(:ash_durable_reactor, :human_approve))

      reactor = Elixir.Reactor.Builder.new()
      {:ok, reactor} = Elixir.Reactor.Builder.add_step(reactor, :approve, {step, kw}, [])
      reactor = %{reactor | return: :approve}

      assert {:halted, %Elixir.Reactor{state: :halted}} = Elixir.Reactor.run(reactor, %{}, %{})
    end
  end

  describe "ash_oban deferred step" do
    setup do
      %{
        record:
          struct(AshPPlan.ObanIntegrationResource, id: Ash.UUID.generate(), processed: false)
      }
    end

    test "constructs a job carrying the continuation reference, without inserting", %{
      record: record
    } do
      ref = %{"id" => "c1", "plan_iri" => "urn:plan:1", "run_id" => "r1"}
      {:ok, {step, kw}} = Reactor.step_for(real(:ash_oban, :schedule_deferred, trigger: :process))

      assert {:ok, %{inserted?: false, continuation_ref: ^ref, job: job}} =
               step.run(%{record: record, continuation: ref}, %{}, kw)

      assert job.valid?
      args = Ecto.Changeset.get_field(job, :args)
      assert inspect(args) =~ "continuation_ref"
      assert inspect(args) =~ "urn:plan:1"
    end

    test "accepts an AshPPlan.Continuation struct", %{record: record} do
      c = %AshPPlan.Continuation{
        id: "i",
        schema_version: 2,
        plan_iri: "urn:p",
        run_id: "r",
        ash_pplan_version: "v",
        reactor_version: "v",
        codec_id: "c",
        codec_version: "1",
        payload: "",
        payload_sha256: ""
      }

      assert {:ok, %{continuation_ref: %{"id" => "i", "run_id" => "r"}}} =
               AshOban.Schedule.run(%{record: record, continuation: c}, %{}, trigger: :process)
    end

    test "mutation: no continuation reference is refused, not scheduled as a private workflow",
         %{record: record} do
      assert {:error, %{reason: :missing_continuation_reference}} =
               AshOban.Schedule.run(%{record: record}, %{}, trigger: :process)

      assert {:error, %{reason: :missing_option, option: :trigger}} =
               AshOban.Schedule.run(%{record: record, continuation: %{}}, %{}, [])
    end
  end
end
