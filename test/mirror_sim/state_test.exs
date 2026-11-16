defmodule AshPPlan.MirrorSim.StateTest do
  # Wire courts for the `state` mirror-sim area: real Bandit listener, real :httpc
  # client, real AshPPlan.{StateMachine,Obligation,Realization,Digest,Config,ControlPlane}.
  use ExUnit.Case, async: false

  alias AshPPlan.MirrorSim.{Server, State}
  alias AshPPlan.{ControlPlane, Config, Digest, Obligation, Realization, StateMachine}

  @res "integration"
  @res_mod AshPPlan.StateMachineIntegrationResource

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, pid} = Server.start_link(port: 0)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    {:ok, base: Server.base_url(pid)}
  end

  defp post(base, path, body) do
    req = {String.to_charlist(base <> path), [], ~c"application/json", Jason.encode!(body)}
    reply(:httpc.request(:post, req, [], body_format: :binary))
  end

  defp get(base, path) do
    reply(:httpc.request(:get, {String.to_charlist(base <> path), []}, [], body_format: :binary))
  end

  defp reply({:ok, {{_, status, _}, _h, body}}), do: {status, Jason.decode!(body)}

  defp ok!(base, path, body) do
    assert {200, %{"ok" => true, "result" => result}} = post(base, path, body)
    result
  end

  defp refused!(base, path, body, term) do
    assert {422, %{"refused" => true, "broken_term" => ^term} = resp} = post(base, path, body)
    resp
  end

  defp parity(term), do: term |> State.encode() |> Jason.encode!() |> Jason.decode!()

  # ---- surface inventory ---------------------------------------------------

  test "surfaces/0 names every public function of the mirrored modules" do
    funs = for s <- State.surfaces(), do: {s.module, s.fun, s.arity}

    for mod <- [StateMachine, Obligation, Realization, Digest, Config, ControlPlane] do
      assert {:module, ^mod} = Code.ensure_loaded(mod)
    end

    for {mod, fun, arity} <- funs do
      assert function_exported?(mod, fun, arity), "#{inspect(mod)}.#{fun}/#{arity} not exported"
    end

    for mod <- [StateMachine, Obligation, Realization, Digest, Config, ControlPlane] do
      for {fun, arity} <- mod.__info__(:functions), fun != :__struct__ do
        assert {mod, fun, arity} in funs, "unmirrored #{inspect(mod)}.#{fun}/#{arity}"
      end
    end
  end

  test "router lists the state area as mounted", %{base: base} do
    assert {200, %{"mounted" => mounted}} = get(base, "/surfaces")
    assert Enum.any?(mounted, &(&1["area"] == "state"))
  end

  # ---- state machine: legal and illegal transitions ------------------------

  test "from_transitions legal projection equals the direct call", %{base: base} do
    wire =
      ok!(base, "/state/projection/from_transitions", %{
        states: ["pending", "complete", "cancelled"],
        transitions: [
          %{action: "advance", from: "pending", to: "complete"},
          %{action: "cancel", from: "*", to: "cancelled"}
        ],
        goals: ["complete"]
      })

    {:ok, direct} =
      StateMachine.from_transitions(
        [:pending, :complete, :cancelled],
        [
          %{action: :advance, from: :pending, to: :complete},
          %{action: :cancel, from: :*, to: :cancelled}
        ],
        [:complete]
      )

    assert wire == parity(direct)
    assert wire["transitions"]["pending"]["advance"] == ["complete"]
    assert wire["transitions"]["pending"]["cancel"] == ["cancelled"]
  end

  test "from_transitions /2 and /3 arities have wire parity", %{base: base} do
    body = %{
      states: ["a", "b"],
      transitions: [%{action: "go", from: "a", to: "b"}]
    }

    trans = [%{action: :go, from: :a, to: :b}]

    {:ok, d2} = StateMachine.from_transitions([:a, :b], trans)
    assert ok!(base, "/state/projection/from_transitions", body) == parity(d2)
    assert d2.goals == MapSet.new()

    {:ok, d3} = StateMachine.from_transitions([:a, :b], trans, [:b])
    wire3 = ok!(base, "/state/projection/from_transitions", Map.put(body, :goals, ["b"]))
    assert wire3 == parity(d3)
    assert wire3["goals"] == ["b"]
    refute wire3 == parity(d2)
  end

  test "illegal projections are typed refusals matching direct reasons", %{base: base} do
    cases = [
      {%{states: [], transitions: []}, "empty_state_machine",
       fn -> StateMachine.from_transitions([], [], []) end},
      {%{states: ["a"], transitions: [], goals: ["zzz"]}, "unknown_goal_states",
       fn -> StateMachine.from_transitions([:a], [], [:zzz]) end},
      {%{states: ["a"], transitions: [%{action: "go", from: "a", to: "nope"}]},
       "unknown_state_in_transition",
       fn -> StateMachine.from_transitions([:a], [%{action: :go, from: :a, to: :nope}], []) end},
      {%{states: ["a"], transitions: ["garbage"]}, "invalid_state_machine_transition",
       fn -> StateMachine.from_transitions([:a], ["garbage"], []) end},
      {%{states: ["a"], transitions: [%{action: "*", from: "a", to: "a"}]},
       "wildcard_action_requires_actions",
       fn -> StateMachine.from_transitions([:a], [%{action: :*, from: :a, to: :a}], []) end}
    ]

    for {body, term, direct} <- cases do
      resp = refused!(base, "/state/projection/from_transitions", body, term)
      assert {:error, %{reason: reason}} = direct.()
      assert Atom.to_string(reason) == term
      assert resp["detail"]["reason"] == term
    end
  end

  test "wildcard universes are honoured over the wire", %{base: base} do
    wire =
      ok!(base, "/state/projection/from_transitions", %{
        states: ["a", "b", "old"],
        transitions: [%{action: "*", from: "*", to: "b"}],
        wildcard_states: ["a", "b"],
        wildcard_actions: ["go"]
      })

    {:ok, direct} =
      StateMachine.from_transitions(
        [:a, :b, :old],
        [%{action: :*, from: :*, to: :b}],
        [],
        wildcard_states: [:a, :b],
        wildcard_actions: [:go]
      )

    assert wire == parity(direct)
    assert wire["transitions"]["old"] == %{}

    refused!(
      base,
      "/state/projection/from_transitions",
      %{states: ["a"], transitions: [], wildcard_actions: ["*"]},
      "wildcard_action_must_be_concrete"
    )
  end

  # ---- resource-level lifecycle -------------------------------------------

  test "describe_resource / capabilities / from_resource parity", %{base: base} do
    {:ok, direct} = StateMachine.describe_resource(@res_mod)
    wire = ok!(base, "/state/resource/describe", %{resource: @res})
    assert wire == parity(direct)
    assert wire["initial_states"] == ["pending"]
    assert "legacy" in wire["deprecated_states"]

    {:ok, caps} = StateMachine.capabilities(@res_mod)
    assert ok!(base, "/state/resource/capabilities", %{resource: @res}) == parity(caps)

    {:ok, fond} = StateMachine.from_resource(@res_mod, [:complete])

    assert ok!(base, "/state/resource/project", %{resource: @res, goals: ["complete"]}) ==
             parity(fond)

    refused!(
      base,
      "/state/resource/project",
      %{resource: @res, goals: ["bogus"]},
      "unknown_goal_states"
    )
  end

  test "non-resources and unconfigured resources are typed refusals", %{base: base} do
    refused!(base, "/state/resource/describe", %{resource: "String"}, "not_an_ash_resource")

    refused!(
      base,
      "/state/resource/describe",
      %{resource: "NoSuchModuleAnywhereXyz"},
      "unknown_resource"
    )

    refused!(base, "/state/resource/describe", %{}, "resource_required")
    refused!(base, "/state/resource/capabilities", %{resource: "String"}, "not_an_ash_resource")
    assert {:error, %{reason: :not_an_ash_resource}} = StateMachine.describe_resource(String)
  end

  test "possible_next_states legal and illegal parity", %{base: base} do
    pending = struct(@res_mod, state: :pending)
    {:ok, all} = StateMachine.possible_next_states(pending)

    assert ok!(base, "/state/resource/possible_next_states", %{resource: @res, state: "pending"}) ==
             parity(all)

    {:ok, adv} = StateMachine.possible_next_states(pending, :advance)

    assert ok!(base, "/state/resource/possible_next_states", %{
             resource: @res,
             state: "pending",
             action: "advance"
           }) == parity(adv)

    assert :complete in adv

    # unknown action: refused, never silently []
    refused!(
      base,
      "/state/resource/possible_next_states",
      %{resource: @res, state: "pending", action: "nonexistent_action_zzz"},
      "invalid_state_machine_action"
    )

    assert {:error, %{reason: :invalid_state_machine_action}} =
             StateMachine.possible_next_states(pending, "nonexistent_action_zzz")

    # no record at all
    refused!(
      base,
      "/state/resource/possible_next_states",
      %{resource: @res},
      "invalid_state_machine_record"
    )

    # state from a terminal state: complete cannot advance
    {:ok, from_complete} =
      StateMachine.possible_next_states(struct(@res_mod, state: :complete), :advance)

    assert ok!(base, "/state/resource/possible_next_states", %{
             resource: @res,
             state: "complete",
             action: "advance"
           }) == parity(from_complete)

    refute :complete in from_complete
  end

  # ---- obligation lifecycle -----------------------------------------------

  test "obligation mint is content-addressed and verifies; tamper is detected", %{base: base} do
    body = %{
      run_id: "run-1",
      step_name: "send_sms",
      intent: "dispatch",
      payload: %{"to" => "+15550100", "n" => 1},
      metadata: %{"k" => "v"}
    }

    first = ok!(base, "/state/obligation/mint", body)
    second = ok!(base, "/state/obligation/mint", body)

    direct =
      Obligation.mint("run-1", "send_sms", "dispatch", %{"to" => "+15550100", "n" => 1},
        metadata: %{"k" => "v"}
      )

    assert first["digest"] == direct.digest
    assert first["id"] == direct.id
    assert first["digest"] == second["digest"]
    assert String.starts_with?(first["id"], "obl-")
    assert String.starts_with?(first["digest"], "sha256:")

    assert ok!(base, "/state/obligation/verify", %{obligation: first}) == %{"valid" => true}
    assert Obligation.verify_digest(direct)

    tampered = put_in(first, ["payload", "to"], "+15550199")
    assert ok!(base, "/state/obligation/verify", %{obligation: tampered}) == %{"valid" => false}
    refute Obligation.verify_digest(%{direct | payload: %{"to" => "+15550199", "n" => 1}})

    other = ok!(base, "/state/obligation/mint", %{body | step_name: "other"})
    refute other["digest"] == first["digest"]

    assert ok!(base, "/state/obligation/verify", %{obligation: 42}) == %{"valid" => false}

    assert ok!(base, "/state/obligation/verify", %{obligation: %{"id" => "x"}}) ==
             %{"valid" => false}
  end

  test "obligation mint refuses a non-map payload", %{base: base} do
    refused!(
      base,
      "/state/obligation/mint",
      %{run_id: "r", step_name: "s", intent: "i", payload: "str"},
      "payload_must_be_map"
    )
  end

  # ---- realization ---------------------------------------------------------

  test "adapters and op_for parity", %{base: base} do
    assert {200, %{"ok" => true, "result" => adapters}} = get(base, "/state/realization/adapters")
    assert adapters == parity(Realization.adapters())
    assert adapters != []

    assert ok!(base, "/state/realization/op_for", %{capability: "File.Write"}) == "file_write"
    assert Realization.op_for("File.Write") == :file_write
    refused!(base, "/state/realization/op_for", %{capability: 5}, "capability_must_be_string")
  end

  test "realization new: legal binding admitted, illegal binding refused", %{base: base} do
    [adapter | _] = Realization.adapters()
    adapter_s = Atom.to_string(adapter)

    legal = %{
      capability: "File.Write",
      realization: %{provider: "prov", binding: %{adapter: adapter_s, op: "file_write"}}
    }

    wire = ok!(base, "/state/realization/new", legal)

    {:ok, direct} =
      Realization.new(
        %{provider: :prov, binding: %{adapter: adapter, op: :file_write}},
        "File.Write"
      )

    assert wire == parity(direct)
    assert ok!(base, "/state/realization/validate", legal) == %{"valid" => true}

    mismatch = put_in(legal, [:realization, :binding, :op], "wrong_op")
    resp = refused!(base, "/state/realization/new", mismatch, "invalid_binding")

    assert {:error, {:invalid_binding, {:op_mismatch, :wrong_op, :file_write}}} =
             Realization.new(
               %{provider: :prov, binding: %{adapter: adapter, op: :wrong_op}},
               "File.Write"
             )

    assert is_list(resp["detail"])

    unknown = put_in(legal, [:realization, :binding, :adapter], "no_such_adapter_zzz")
    refused!(base, "/state/realization/new", unknown, "invalid_binding")
    refused!(base, "/state/realization/validate", unknown, "invalid_binding")

    # legacy shape without binding is refused: providers describe, never name a step
    legacy = %{capability: "File.Write", realization: %{provider: "prov"}}
    refused!(base, "/state/realization/new", legacy, "invalid_binding")

    assert {:error, {:invalid_binding, nil}} =
             Realization.new(%{provider: :prov}, "File.Write")

    # from_map never validates
    fm = ok!(base, "/state/realization/from_map", legacy)
    assert fm["binding"] == nil
    assert fm["capability"] == "File.Write"

    refused!(
      base,
      "/state/realization/new",
      %{capability: "File.Write", realization: %{}},
      "provider_required"
    )

    refused!(
      base,
      "/state/realization/new",
      %{realization: %{provider: "p"}},
      "capability_must_be_string"
    )
  end

  # ---- digest --------------------------------------------------------------

  test "digest hash is deterministic and equals sha256 by default", %{base: base} do
    a = ok!(base, "/state/digest/hash", %{input: "hello"})
    b = ok!(base, "/state/digest/hash", %{input: "hello"})
    c = ok!(base, "/state/digest/hash", %{input: "hellp"})

    assert a == b
    refute a["hash_hex"] == c["hash_hex"]
    assert a["bytes"] == 32
    assert a["hash_hex"] == Digest.hex(Digest.hash("hello"))
    assert a["hash_hex"] == Base.encode16(:crypto.hash(:sha256, "hello"), case: :lower)

    assert ok!(base, "/state/digest/hex", %{base64: Base.encode64(<<0, 255, 16>>)}) ==
             %{"hex" => "00ff10"}

    assert Digest.hex(<<0, 255, 16>>) == "00ff10"

    refused!(base, "/state/digest/hash", %{input: 5}, "input_must_be_string")
    refused!(base, "/state/digest/hex", %{base64: "!!!"}, "base64_required")
  end

  # ---- config --------------------------------------------------------------

  test "config snapshot equals direct reads", %{base: base} do
    assert {200, %{"ok" => true, "result" => wire}} = get(base, "/state/config")

    assert wire["durable_halt_timeout"] == Config.durable_halt_timeout()
    assert wire["standing_flight_timeout_ms"] == Config.standing_flight_timeout_ms()
    assert wire["digest_module"] == Atom.to_string(Config.digest_module())
    assert wire["extra_capability_families"] == parity(Config.extra_capability_families())
    assert wire["extra_adapters"] == parity(Config.extra_adapters())
    assert wire["durable_store_module"] == parity(Config.durable_store_module())
  end

  test "config durable_store_module nil is a fail-closed refusal over the wire", %{base: base} do
    prior = Application.fetch_env(:ash_pplan, :durable_store_module)
    Application.put_env(:ash_pplan, :durable_store_module, nil)

    on_exit(fn ->
      case prior do
        {:ok, v} -> Application.put_env(:ash_pplan, :durable_store_module, v)
        :error -> Application.delete_env(:ash_pplan, :durable_store_module)
      end
    end)

    assert {:error, %{reason: :durable_store_unconfigured}} = Config.durable_store_module()

    assert {200, %{"result" => %{"durable_store_module" => ["error", %{"reason" => reason}]}}} =
             get(base, "/state/config")

    assert reason == "durable_store_unconfigured"
  end

  # ---- control plane -------------------------------------------------------

  test "control plane describe and action_catalog parity", %{base: base} do
    {:ok, direct} = ControlPlane.describe(@res_mod)
    wire = ok!(base, "/state/control_plane/describe", %{resource: @res})
    assert wire == parity(direct)
    assert wire["gaps"]["planner_actuation?"] == false
    assert wire["state_machine"]["available?"] == true
    assert wire["authority"]["lifecycle_legality"] == "Elixir.AshStateMachine"

    assert ok!(base, "/state/control_plane/action_catalog", %{resource: @res}) ==
             parity(ControlPlane.action_catalog(@res_mod))

    cp = ok!(base, "/state/control_plane/describe", %{resource: "control_plane"})
    {:ok, cp_direct} = ControlPlane.describe(AshPPlan.ControlPlaneIntegrationResource)
    assert cp == parity(cp_direct)
  end

  test "control plane refuses non-resources; action_catalog yields []", %{base: base} do
    refused!(base, "/state/control_plane/describe", %{resource: "String"}, "not_an_ash_resource")
    assert {:error, %{reason: :not_an_ash_resource}} = ControlPlane.describe(String)
    assert ok!(base, "/state/control_plane/action_catalog", %{resource: "String"}) == []
    assert ControlPlane.action_catalog(String) == []
  end

  # ---- robustness ----------------------------------------------------------

  test "malformed bodies and unknown routes never 500", %{base: base} do
    req =
      {String.to_charlist(base <> "/state/projection/from_transitions"), [], ~c"application/json",
       "{not json"}

    assert {400, %{"refused" => true}} =
             reply(:httpc.request(:post, req, [], body_format: :binary))

    assert {404, %{"refused" => true}} = get(base, "/state/no_such_route")

    # wrong-typed fields hit the handler's typed refusals, not a crash
    assert {422, %{"refused" => true}} =
             post(base, "/state/projection/from_transitions", %{states: "x", transitions: 5})
  end
end
