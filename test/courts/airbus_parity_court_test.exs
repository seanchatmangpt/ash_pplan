defmodule AshPPlan.Courts.AirbusParityCourtTest do
  @moduledoc """
  Chicago-style cross-engine parity court between the Airbus deliberation stack
  (`scikit-decide`, `unified-planning`, `PRP`, FDC) and native `ash_pplan`.

  Evaluates real benchmark domains, asserts bit-for-bit decision parity,
  solvability region alignment, STNU dynamic controllability, and durable
  replay safety.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.FOND
  alias AshPPlan.FOND.Synthesis
  alias AshPPlan.Airbus.Transpiler
  alias AshPPlan.Test.AirbusOracle.{Client, Provisioner, Assertions}
  alias AshPPlan.Test.TLAReader
  alias AshPPlan.Reactor.Durable.Store

  setup_all do
    case Provisioner.availability() do
      :ok ->
        :ok

      {:unavailable, reason} ->
        {:skip, "Airbus Oracle daemon unavailable: #{inspect(reason)}"}
    end
  end

  describe "FOND Policy Synthesis Parity" do
    test "strong-cyclic policy parity: aerospace fastener torque recovery" do
      # State space:
      # :seated -> :torque -> [:torqued (goal), :stripped]
      # :stripped -> :extract -> [:extracted]
      # :extracted -> :retap -> [:seated]
      # :torqued -> goal
      {:ok, domain} =
        FOND.new(
          %{
            seated: %{torque: [:torqued, :stripped]},
            stripped: %{extract: [:extracted]},
            extracted: %{retap: [:seated]},
            torqued: %{}
          },
          [:torqued]
        )

      initial = :seated
      mode = :strong_cyclic

      # Native BEAM synthesis
      assert {:ok, ash_policy} = Synthesis.synthesize(domain, initial, mode)
      assert {:ok, ash_solvable} = Synthesis.solvable_states(domain, mode)

      # Airbus Oracle synthesis
      oracle_params = Transpiler.to_oracle_fond(domain, initial, mode)
      assert {:ok, oracle_resp} = Client.call("solve_fond", oracle_params)

      assert oracle_resp["solvable"] == true
      assert oracle_resp["mode"] == "strong_cyclic"

      # Cross-engine parity assertions
      Assertions.assert_winning_region_parity(oracle_resp["winning_region"], ash_solvable)
      Assertions.assert_policy_parity(oracle_resp["policy"], ash_policy, domain)

      # Cross-verify with in-process TLA+ model checking
      assert {:ok, tla_spec} =
               FOND.to_tla(domain, ash_policy, initial, mode, name: "FastenerTorqueParity")

      assert %{verdict: :admitted} = TLAReader.check!(tla_spec)
    end

    test "strong non-looping policy parity: finite layered attractor" do
      {:ok, domain} =
        FOND.new(
          %{
            s0: %{step: [:s1, :s2]},
            s1: %{finish: [:done]},
            s2: %{finish: [:done]},
            done: %{}
          },
          [:done]
        )

      initial = :s0
      mode = :strong

      assert {:ok, ash_policy} = Synthesis.synthesize(domain, initial, mode)
      assert {:ok, ash_solvable} = Synthesis.solvable_states(domain, mode)

      oracle_params = Transpiler.to_oracle_fond(domain, initial, mode)
      assert {:ok, oracle_resp} = Client.call("solve_fond", oracle_params)

      assert oracle_resp["solvable"] == true
      Assertions.assert_winning_region_parity(oracle_resp["winning_region"], ash_solvable)
      Assertions.assert_policy_parity(oracle_resp["policy"], ash_policy, domain)
    end

    test "adversarial deadlock falsification parity: dead end witness matching" do
      # :trap has no outgoing action, :s0 can transition into :trap or :goal
      {:ok, domain} =
        FOND.new(
          %{
            s0: %{risky_act: [:trap, :goal]},
            trap: %{},
            goal: %{}
          },
          [:goal]
        )

      initial = :s0
      mode = :strong

      # Native BEAM must refuse
      assert {:error, {:unsolvable, :strong, ash_witness}} =
               Synthesis.synthesize(domain, initial, mode)

      # Airbus Oracle must refuse with matching witness
      oracle_params = Transpiler.to_oracle_fond(domain, initial, mode)
      assert {:ok, oracle_resp} = Client.call("solve_fond", oracle_params)

      assert oracle_resp["solvable"] == false
      Assertions.assert_witness_parity(oracle_resp["witness"], ash_witness)
    end
  end

  describe "STNU Dynamic Controllability Parity" do
    test "composite wing autoclave cure temporal network is dynamically controllable" do
      stnu_path =
        Path.expand("../../priv/courts/airbus_parity/corpus/composite_cure.stnu", __DIR__)

      assert File.exists?(stnu_path)

      stnu_spec = Jason.decode!(File.read!(stnu_path))

      assert {:ok, oracle_resp} = Client.call("check_stnu_dc", stnu_spec)
      assert oracle_resp["dynamically_controllable"] == true
      assert oracle_resp["conflicts"] == []
    end

    test "temporal contradiction injects negative cycle and fails closed" do
      contradictory_stnu = %{
        "nodes" => ["start", "cure_end"],
        "requirement_links" => [
          # Requires finishing by minute 30
          %{"from" => "start", "to" => "cure_end", "min" => 0, "max" => 30}
        ],
        "contingent_links" => [
          # But cure takes at least 60 minutes
          %{
            "from" => "start",
            "to" => "cure_end",
            "min" => 60,
            "max" => 90,
            "is_contingent" => true
          }
        ]
      }

      assert {:ok, oracle_resp} = Client.call("check_stnu_dc", contradictory_stnu)
      assert oracle_resp["dynamically_controllable"] == false
      assert length(oracle_resp["conflicts"]) > 0
    end
  end

  describe "HTN Task Expansion Parity" do
    test "AOG turnaround expansion preserves precedence order" do
      spec = %{
        "initial_task" => "turnaround_engine",
        "tasks" => [
          "task_isolate_bay",
          "task_remove_engine",
          "inspect_and_certify",
          "task_install_engine",
          "task_ground_run_test"
        ],
        "methods" => [
          %{
            "task" => "turnaround_engine",
            "subtasks" => [
              "task_isolate_bay",
              "task_remove_engine",
              "inspect_and_certify",
              "task_install_engine",
              "task_ground_run_test"
            ]
          }
        ]
      }

      assert {:ok, resp} = Client.call("expand_htn", spec)
      assert resp["admissible"] == true
      assert resp["topology"] == spec["tasks"]
      assert length(resp["precedence"]) == 4
    end
  end

  describe "Durable Replay & Crash Safety Assertion" do
    @tag :crash_injection
    test "simulated process restart restores exact DETS checkpoint tape without side effects" do
      test_dir =
        Path.join([
          System.tmp_dir!(),
          "airbus_parity_crash_test_#{:erlang.unique_integer([:positive])}"
        ])

      File.mkdir_p!(test_dir)
      dets_file = Path.join(test_dir, "durable_run.dets")

      on_exit(fn -> File.rm_rf!(test_dir) end)

      {:ok, store} = Store.Dets.start_link(path: dets_file)

      run_id = "aog_flight_942"
      assert {:ok, _} = Store.Dets.start_run(store, %{id: run_id, status: :running})

      # Record checkpoint 1
      assert {:ok, _} =
               Store.Dets.record(store, run_id, "key_1", "isolate_bay", %{status: :cleared}, %{})

      # Simulate crash by unlinking and stopping store process
      Process.unlink(store)
      Process.exit(store, :kill)
      :timer.sleep(50)

      # Re-open store from disk
      {:ok, recovered_store} = Store.Dets.start_link(path: dets_file)

      # Verify step 1 checkpoint exists and was not lost across crash
      standing = Store.Dets.standing(recovered_store, run_id)
      assert length(standing) == 1
      assert hd(standing).label == "isolate_bay"
      assert hd(standing).output == %{status: :cleared}

      # Advance to step 2 after recovery
      assert {:ok, _} =
               Store.Dets.record(
                 recovered_store,
                 run_id,
                 "key_2",
                 "remove_engine",
                 %{status: :engine_on_stand},
                 %{}
               )

      standing_after = Store.Dets.standing(recovered_store, run_id)
      assert length(standing_after) == 2
    end
  end
end
