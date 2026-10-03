defmodule AshPPlan.FOND.TLADifferentialEdgeTest do
  @moduledoc """
  Edge extension of the durable TLA+ differential court
  (`test/durable/tla_trace_test.exs`, `test/durable/tla_court_test.exs`).

  Every typed refusal hardened this wave is probed on its REAL collaborator
  (real `Engine` over real `Store.Ets`/`Store.Dets`, real `PolicySupervisor`),
  and the generated model `priv/tla/durable/transitions.exs` (read-only, ggen
  output of `priv/ggen/ash-pplan-durable-tla-pack/ontology.ttl`) must agree
  with `Status.can?/2` on the resulting status pairs:

  - orphan signal (`:no_such_run`): a delivery to a run that does not exist
    writes NO status pair; the parked-delivery counterpart is legal in both
    sources.
  - `{:error, {:path_in_use, path}}`: a second DETS open on the same path is a
    typed refusal, not a silent double open; no run row is created.
  - `unwind_blocked -> unwind_blocked` self-transition: a second failed
    rollback re-records the blockage. This pair is the wave's NEW legal pair
    and is asserted true in BOTH sources, witnessed by a real engine attempt,
    and refuses illegal neighbours in both.
  - `{:horizon_exceeded, k, witness}`: the supervisor's typed exhaustion
    refusal, deterministic and non-crashing, on the real supervisor.

  On the `.cfg` side, the committed `DurableProtocol.cfg` properties must
  refuse the edge mutants: cancelling a terminal run (TerminalAbsorbing) and
  parking out of `:cancelling` (CancelNeverOverwritten, which is the property
  that carries `unwind_blocked` as a legal cancelling successor). Signal
  honesty (`NoLostWakeup`) is pinned by requiring `guard:deliver_once` on
  `Deliver` -- the guard whose removal turns a phantom delivery into a lost
  wakeup.

  Anti-vacuity: negative controls assert the pairs the wave did NOT add are
  refused by both sources, and each probe's refusal is distinct from an
  admitted control path run in the same test.
  """
  use ExUnit.Case, async: false

  Code.require_file("lane_b_fixture.exs", Path.expand("../durable", __DIR__))

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Test.Effects

  alias AshPPlan.FOND
  alias AshPPlan.FOND.PolicySupervisor
  alias AshPPlan.Reactor.Durable.{Clock, Engine, Status}
  alias AshPPlan.Reactor.Durable.Store.{Dets, Ets}
  alias AshPPlan.Test.TLAReader

  @dir Path.expand("../../priv/tla/durable", __DIR__)
  @model Code.eval_file(Path.join(@dir, "transitions.exs")) |> elem(0)
  @protocol File.read!(Path.join(@dir, "DurableProtocol.tla"))
  @cfg File.read!(Path.join(@dir, "DurableProtocol.cfg"))

  # The wave's NEW legal pair, and the edge pairs the refusals live on.
  @new_pairs [unwind_blocked: :unwind_blocked]
  @unwind_edge_pairs [
    unwinding: :unwind_blocked,
    cancelling: :unwind_blocked,
    unwind_blocked: :unwinding,
    unwind_blocked: :cancelling,
    unwind_blocked: :failed,
    unwind_blocked: :cancelled
  ]
  # Pairs the wave did NOT add: both sources must refuse them.
  @refused_pairs [
    completed: :waiting,
    failed: :pending,
    cancelled: :waiting,
    pending: :cancelled,
    unwinding: :completed
  ]

  describe "generated model == Status.can?/2 on the refusal-edge pairs" do
    test "every status pair agrees, including the new unwind_blocked self-transition" do
      for from <- Status.all(), to <- Status.all() do
        assert {from, to} in @model.transitions == Status.can?(from, to),
               "ontology drift on #{inspect(from)} -> #{inspect(to)}"
      end
    end

    test "the NEW pair (unwind_blocked self-transition) is legal in both sources" do
      for {from, to} <- @new_pairs ++ @unwind_edge_pairs do
        assert {from, to} in @model.transitions,
               "generated model dropped #{inspect(from)} -> #{inspect(to)}"

        assert Status.can?(from, to), "Status.can? refused #{inspect(from)} -> #{inspect(to)}"
      end
    end

    test "pairs the wave did not add are refused by BOTH sources (negative controls)" do
      for {from, to} <- @refused_pairs do
        refute {from, to} in @model.transitions,
               "generated model grew #{inspect(from)} -> #{inspect(to)}"

        refute Status.can?(from, to), "Status.can? admits #{inspect(from)} -> #{inspect(to)}"
      end
    end

    test "statuses and terminal sets agree" do
      assert Enum.sort(@model.statuses) == Enum.sort(Status.all())

      assert Enum.sort(@model.terminal) ==
               Enum.sort(Enum.filter(Status.all(), &Status.terminal?/1))
    end
  end

  describe "real refusal probes agree with the generated model" do
    setup do
      LaneBFx.install_adapter!()
      Clock.use_test_clock()
      on_exit(&Clock.reset/0)
      name = :"tla_edge_fx_#{System.unique_integer([:positive])}"
      {:ok, _} = Effects.start_link(name: name)
      {:ok, ets} = Ets.start_link()
      %{store: ets, fx: name}
    end

    test "orphan signal: {:error, :no_such_run}, no status pair written", %{store: store, fx: fx} do
      assert {:error, :no_such_run} = Engine.signal(store, "missing-run", "go", :now)

      # No run row was created: the refusal happened before any status write.
      assert Engine.fetch(store, "missing-run") == nil

      # Differential: the parked counterpart IS legal in both sources
      # (waiting -> waiting), and a real delivery to a parked run succeeds.
      assert {:waiting, :waiting} in @model.transitions
      assert Status.can?(:waiting, :waiting)

      opts = [store_module: Ets]
      {:ok, _} = Engine.start(store, parked_attrs("edge-orphan-ctl", fx), opts)
      assert {:parked, :waiting} = Engine.attempt(store, "edge-orphan-ctl", opts)
      assert {:ok, _signal} = Engine.signal(store, "edge-orphan-ctl", "go", :now, opts)
      assert Engine.fetch(store, "edge-orphan-ctl").status == :waiting
    end

    test "path_in_use: the second open of a DETS path is refused, not silently shared" do
      # a failed start_link exits its child non-normally; trap so the assert on
      # the error tuple decides the outcome instead of a poisoned link
      Process.flag(:trap_exit, true)
      path = edge_dets_path()
      on_exit(fn -> File.rm(path) end)
      {:ok, s} = Dets.start_link(path: path)

      assert {:error, {:path_in_use, _}} = Dets.start_link(path: path)
      assert {:error, {:path_in_use, _}} = Dets.start_link(path: String.to_charlist(path))

      # The refusal created no run: the first store's rows are untouched and
      # the model/Status still agree that a fresh run starts at :pending.
      assert Engine.fetch(s, "never-started") == nil

      # a fresh run still starts at :pending in both sources
      assert Status.can?(:pending, :waiting) and {:pending, :waiting} in @model.transitions
    end

    test "unwind_blocked self-transition: witnessed by a real second failed rollback" do
      log = :"tla_edge_unwind_#{System.unique_integer([:positive])}"
      {:ok, _} = Agent.start_link(fn -> %{order: [], fail?: true} end, name: log)

      {:ok, store} = Ets.start_link([])

      run_id = "edge-self-loop"
      ctx = %{AshPPlan.Reactor.context_key() => %{subject: "sha256:edge", workflow: :edge}}
      {:ok, _} = Engine.start(store, %{id: run_id, context: ctx})

      # Plant one standing undo that fails while `fail?` is true.
      {:ok, _cp} =
        Ets.record(store, run_id, AshPPlan.Reactor.Durable.Key.for_name(:a), "a", :out, %{
          impl: {EdgeUndoStep, [name: log]},
          args: %{}
        })

      assert {:ok, _} = Engine.cancel(store, run_id)
      assert {:failed, _} = Engine.attempt(store, run_id)
      assert Engine.fetch(store, run_id).status == :unwind_blocked

      # Second failed rollback: the engine re-records the SAME status, i.e.
      # the unwind_blocked -> unwind_blocked self-transition on real state.
      before = Engine.fetch(store, run_id).status
      assert {:failed, _} = Engine.attempt(store, run_id)
      after_status = Engine.fetch(store, run_id).status

      assert before == :unwind_blocked and after_status == :unwind_blocked

      # Differential: the witnessed pair is the NEW legal pair in BOTH sources,
      # and its illegal neighbours are refused by both.
      assert {:unwind_blocked, :unwind_blocked} in @model.transitions
      assert Status.can?(:unwind_blocked, :unwind_blocked)

      refute Status.can?(:unwind_blocked, :waiting)
      refute {:unwind_blocked, :waiting} in @model.transitions

      # Store-level: the same guarded write is legal, the wide one is not.
      assert {:ok, _} =
               Ets.transition(store, run_id, [:unwind_blocked], :unwind_blocked, %{error: :fresh})

      assert {:error, _} = Ets.transition(store, run_id, [:unwind_blocked], :waiting, %{})
    end

    test "horizon_exceeded: typed, deterministic refusal from the real supervisor" do
      {:ok, domain} = FOND.new(%{a: %{go: [:b]}, b: %{}}, [:b])
      {:ok, sup0} = PolicySupervisor.start(domain, :a, :strong_cyclic, horizon: 1)
      refute PolicySupervisor.horizon_exceeded?(sup0)

      assert {:ok, %{kind: :fond_action, action: :go}} = PolicySupervisor.intent(sup0)

      # The one allowed attempt...
      assert {:ok, sup1} = PolicySupervisor.observe(sup0, sup0.epoch, :b)
      assert PolicySupervisor.horizon_exceeded?(sup1)

      # ...then the next observe is the typed refusal, twice, byte-identical.
      assert {:error, {:horizon_exceeded, 1, witness}} =
               PolicySupervisor.observe(sup1, sup1.epoch, :b)

      assert {:error, {:horizon_exceeded, 1, ^witness}} =
               PolicySupervisor.observe(sup1, sup1.epoch, :b)

      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, witness)

      # Differential: the refusal moved nothing; the underlying model and
      # Status.can? still agree on every pair (the refusal lives outside the
      # status relation, as designed).
      for from <- Status.all(), to <- Status.all() do
        assert {from, to} in @model.transitions == Status.can?(from, to)
      end
    end
  end

  describe "FOND x TLA differential over the generated durable edge graph" do
    test "the ontology edge graph validates as a FOND domain and renders; reader == elixir" do
      # The generated transition map IS a domain: every legal pair becomes a
      # deterministic action "to_<to>"; terminal states are absorbing.
      outgoing =
        Enum.group_by(@model.transitions, &elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {from, tos} -> {from, Map.new(tos, &{"to_#{&1}", [&1]})} end)

      transitions = Map.new(Status.all(), &{&1, Map.get(outgoing, &1, %{})})
      goals = [:cancelled]

      assert {:ok, domain} = FOND.new(transitions, goals)

      policy = %{
        pending: "to_cancelling",
        cancelling: "to_unwind_blocked",
        unwind_blocked: "to_cancelled"
      }

      initial = :pending

      elixir =
        case FOND.validate_policy(domain, policy, initial, :strong) do
          {:ok, _report} -> :admitted
          {:error, _refusal} -> :refused
        end

      assert elixir == :admitted

      assert {:ok, rendered} = FOND.to_tla(domain, policy, initial, :strong)
      assert TLAReader.check!(rendered).verdict == elixir

      # The NEW pair is carried into the rendered model as a concrete edge.
      assert rendered.module =~ "B_"
      assert Map.has_key?(transitions, :unwind_blocked)
      assert transitions[:unwind_blocked]["to_unwind_blocked"] == [:unwind_blocked]
    end
  end

  describe "DurableProtocol.cfg properties refuse the edge mutants" do
    test "every cfg property and the signal guard are present" do
      for prop <- ~w(TerminalAbsorbing CancelNeverOverwritten NoLostWakeup) do
        assert @cfg =~ "PROPERTY #{prop}"
        assert @protocol =~ ~r/^#{prop} ==/m
      end

      # The signal-delivery guard that keeps a phantom/orphan delivery from
      # becoming a lost wakeup.
      assert @protocol =~ ~r/^Deliver ==/m
      assert Regex.match?(~r/^Deliver ==.*\n(.*guard:deliver_once\n)/m, @protocol)
      assert @protocol =~ "guard:cancel_from"
      assert @protocol =~ "guard:settle_from"
      # unwind_blocked is a legal cancelling successor in the property itself.
      assert @protocol =~
               ~S|"cancelling", "cancelled", "unwind_blocked"|
    end

    defp mutate(guard_id) do
      re = ~r/^  \/\\ .* \\\* guard:#{guard_id}$/m
      assert Regex.match?(re, @protocol), "guard #{guard_id} absent"
      Regex.replace(re, @protocol, "  /\\ TRUE \\* guard:#{guard_id}")
    end

    test "guard-dropping mutants differ from the spec only at their guard line" do
      for guard <- ~w(cancel_from deliver_once settle_from) do
        mutant = mutate(guard)
        refute mutant == @protocol

        diff =
          Enum.zip(String.split(@protocol, "\n"), String.split(mutant, "\n"))
          |> Enum.reject(fn {a, b} -> a == b end)

        assert diff != []
        assert Enum.all?(diff, fn {a, b} -> a =~ "guard:#{guard}" and b =~ "/\\ TRUE" end)
      end
    end

    case AshPPlan.Test.TLCCourt.availability() do
      :ok ->
        @describetag :tlc

        for {guard, property} <- [
              {"cancel_from", "TerminalAbsorbing"},
              {"settle_from", "CancelNeverOverwritten"}
            ] do
          test "TLC: mutant dropping guard:#{guard} is refused via #{property}" do
            alias AshPPlan.Test.TLCCourt

            TLCCourt.verify_jar!()

            rendered = %{
              module_name: "DurableProtocol",
              module: mutate(unquote(guard)),
              cfg: @cfg
            }

            assert %{verdict: :refused} = TLCCourt.check!(rendered)
          end
        end

      {:unavailable, reason} ->
        @describetag skip: "TLC court unavailable: " <> reason
    end
  end

  defp edge_dets_path do
    Path.join(
      System.tmp_dir!(),
      "ash_pplan_tla_edge_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}.dets"
    )
  end

  defp parked_attrs(id, fx) do
    AshPPlan.Durable.LaneBFx.attrs(id, fx, kinds: %{integrate: :await})
  end
end

defmodule EdgeUndoStep do
  @moduledoc false
  use Reactor.Step

  @impl true
  def run(_args, _ctx, _opts), do: {:ok, :done}

  @impl true
  def undo(_value, _args, _ctx, opts) do
    if Agent.get(Keyword.fetch!(opts, :name), & &1.fail?),
      do: {:error, :refused},
      else: :ok
  end
end
