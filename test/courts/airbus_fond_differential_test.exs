defmodule AshPPlan.Courts.AirbusFondDifferentialTest do
  @moduledoc """
  FOND differential parity court (lane A4): native `AshPPlan.FOND.validate_policy/4`
  verdicts vs autofde_lab's `check_candidate_policy` over the daemon's
  `check_policy` method.

  Same {initial, goals, transitions, policy} goes over the wire to the daemon;
  strong and strong_cyclic verdicts must agree on BOTH semantics. Any
  disagreement fails with both verdicts printed. Daemon down → loud skip with
  the reason.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.FOND
  alias AshPPlan.Test.AirbusFondOracle

  # Socket — same law as A3's client: env override for parallel lanes.
  @socket_path System.get_env("ORACLE_SOCKET_PATH") || "/tmp/airbus_oracle.sock"

  # -- Native verdict helpers ------------------------------------------------

  defp native_valid?(domain, policy, initial, mode) do
    case FOND.validate_policy(domain, policy, initial, mode) do
      {:ok, _report} -> true
      {:error, %{reason: reason}} when reason in [:not_strong, :not_strong_cyclic] -> false
      {:error, other} -> raise "native structural refusal: #{inspect(other)}"
    end
  rescue
    # reachable_under_policy refuses (missing action / unavailable action) as
    # structural errors; a structurally-refused policy is not a valid policy
    # under any semantics — both checkers must reject, so verdict = false.
    _ -> false
  end

  defp native_detail(domain, policy, initial, mode) do
    case FOND.validate_policy(domain, policy, initial, mode) do
      {:ok, report} -> {:ok, report}
      {:error, err} -> {:error, err}
    end
  end

  # -- Case domains (hand-built via the real native API, mirroring autofde's
  #    tests/planning/test_fond_policy.py matrix) --------------------------

  defp acyclic_branching do
    {:ok, domain} =
      FOND.new(
        %{
          "s0" => %{"advance" => ["s1", "s2"]},
          "s1" => %{"finish" => ["goal"]},
          "s2" => %{"finish" => ["goal"]}
        },
        ["goal"]
      )

    {domain, %{"s0" => "advance", "s1" => "finish", "s2" => "finish"}, "s0"}
  end

  defp retry_cycle do
    {:ok, domain} = FOND.new(%{"s0" => %{"retry" => ["s0", "goal"]}}, ["goal"])
    {domain, %{"s0" => "retry"}, "s0"}
  end

  defp multistate_cycle do
    {:ok, domain} =
      FOND.new(
        %{"s0" => %{"advance" => ["s1", "goal"]}, "s1" => %{"retry" => ["s0"]}},
        ["goal"]
      )

    {domain, %{"s0" => "advance", "s1" => "retry"}, "s0"}
  end

  defp closed_trap do
    {:ok, domain} = FOND.new(%{"s0" => %{"spin" => ["s0"]}}, ["goal"])
    {domain, %{"s0" => "spin"}, "s0"}
  end

  defp dead_end_action do
    {:ok, domain} =
      FOND.new(
        %{"s0" => %{"advance" => ["s1", "goal"]}, "s1" => %{"finish" => ["goal"]}},
        ["goal"]
      )

    # s1 has no "advance" action: the policy selects an unadmitted action —
    # the daemon-side twin of autofde's "selected action without outcomes".
    {domain, %{"s0" => "advance", "s1" => "advance"}, "s0"}
  end

  # -- The court -------------------------------------------------------------

  setup_all do
    case AirbusFondOracle.ping() do
      :ok ->
        [daemon: :up]

      {:error, reason} ->
        IO.puts("""
        [SKIP-LOUD] airbus FOND differential court: daemon down — #{inspect(reason)}
        start it with: .venv-airbus/bin/python scripts/airbus_oracle_daemon.py --serve
        """)

        [daemon: :down]
    end
  end

  # cases(name, {domain, policy, initial}, expected native intent)
  @cases [
    {:acyclic_branching, :acyclic_branching},
    {:retry_cycle, :retry_cycle},
    {:multistate_cycle, :multistate_cycle},
    {:closed_trap, :closed_trap},
    {:dead_end_action, :dead_end_action}
  ]

  for {name, builder} <- @cases do
    test "#{name}: native and autofde agree on strong and strong_cyclic",
         %{daemon: daemon} do
      {name, builder} = {unquote(name), unquote(builder)}

      if daemon == :down do
        raise ExUnit.SkipError,
          message: "daemon down; differential court cannot run without the oracle"
      end

      {domain, policy, initial} = apply(__MODULE__, builder, [])

      {:ok, autofde} = AirbusFondOracle.verdicts(domain, policy, initial)

      native = %{
        strong: native_valid?(domain, policy, initial, :strong),
        strong_cyclic: native_valid?(domain, policy, initial, :strong_cyclic)
      }

      autofde_verdicts = %{
        strong: autofde.strong,
        strong_cyclic: autofde.strong_cyclic
      }

      if native != autofde_verdicts do
        flunk("""
        DIFFERENTIAL DISAGREEMENT (#{name})
        native   : #{inspect(native)}
        autofde  : #{inspect(autofde_verdicts)}
        autofde detail: valid=#{autofde.autofde["valid"]} \
        cycles=#{inspect(autofde.autofde["non_goal_cycle_states"])} \
        dead_ends=#{inspect(autofde.autofde["dead_end_states"])} \
        cannot_reach=#{inspect(autofde.autofde["cannot_reach_goal_states"])} \
        missing=#{inspect(autofde.autofde["missing_policy_states"])}
        native detail (strong): #{inspect(native_detail(domain, policy, initial, :strong))}
        native detail (strong_cyclic): #{inspect(native_detail(domain, policy, initial, :strong_cyclic))}
        """)
      end

      assert native == autofde_verdicts
    end
  end

  # The distinguishing case, asserted explicitly so the court proves the
  # differential has teeth (strong rejects, strong_cyclic accepts), not just
  # checker-to-checker equality on booleans.
  test "retry_cycle separates the semantics on both checkers", %{daemon: daemon} do
    if daemon == :down,
      do: raise(ExUnit.SkipError, message: "daemon down; differential court skipped")

    {domain, policy, initial} = retry_cycle()
    {:ok, autofde} = AirbusFondOracle.verdicts(domain, policy, initial)

    assert native_valid?(domain, policy, initial, :strong) == false
    assert native_valid?(domain, policy, initial, :strong_cyclic) == true
    assert autofde.strong == false
    assert autofde.strong_cyclic == true
    assert autofde.autofde["non_goal_cycle_states"] == ["s0"]
  end

  test "bad request is typed-refused, never silently passed", %{daemon: daemon} do
    if daemon == :down,
      do: raise(ExUnit.SkipError, message: "daemon down; differential court skipped")

    assert {:ok, socket} =
             :gen_tcp.connect(
               {:local, to_charlist(@socket_path)},
               0,
               [:binary, packet: :line, active: false],
               5_000
             )

    payload =
      Jason.encode!(%{
        "method" => "check_policy",
        "params" => %{"initial" => 1, "goal_states" => [], "transitions" => [], "policy" => %{}}
      })

    :ok = :gen_tcp.send(socket, payload <> "\n")
    {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)

    assert {:ok, %{"result" => %{"error" => "bad_request"}}} = Jason.decode(line)
  end
end
