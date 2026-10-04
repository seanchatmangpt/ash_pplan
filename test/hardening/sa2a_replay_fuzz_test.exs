defmodule AshPPlan.SA2A.ReplayFuzzTest do
  @moduledoc """
  Fuzz court: `AshPPlan.SA2A.Replay.fond/3` is total.

  Hostile requests, malformed candidates, wrong-type domains/initials and
  hostile opts always return `{:error, refusal}` with a closed
  `AshPPlan.SA2A.Refusal.codes/0` code and `authority: :none` — never raise.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.FOND
  alias AshPPlan.SA2A.{PolicyCandidate, Refusal, Replay}

  @subject "sha256:caller"

  defp domain do
    {:ok, d} = FOND.new(%{pending: %{attempt: [:pending, :done]}, done: %{}}, [:done])
    d
  end

  defp good_request(extra \\ []) do
    Map.merge(
      %{subject: @subject, formalism: :fond, domain: domain(), initial: :pending},
      Map.new(extra)
    )
  end

  defp good_candidate(request) do
    {:ok, c} = PolicyCandidate.fond(request, seed: {11, 29, 47})
    c
  end

  defp fuzz(term, request_fn, candidate) do
    request = request_fn.()

    candidate =
      case candidate do
        :good -> good_candidate(good_request())
        other -> other
      end

    fuzz_1(term, request, candidate)
  end

  # totality wrapper, same idiom as policy_offers_fuzz_test's total/1: capture a
  # raise/throw as data so each law below can assert on the result shape itself
  defp total(fun) do
    try do
      fun.()
    rescue
      e -> {:raise, Exception.message(e), __STACKTRACE__}
    catch
      kind, value -> {:raise, {kind, value}, __STACKTRACE__}
    end
  end

  # totality contract: never raise. Valid-shape garbage may be admitted as
  # standing :candidate evidence (native_verdict :refused, authority :none);
  # malformed shapes must be typed-refused.
  defp fuzz_1(term, request, candidate) do
    result = total(fn -> Replay.fond(request, candidate) end)

    case result do
      {:error, %{code: code, authority: :none}} ->
        assert code in Refusal.codes()

      {:ok, %{authority: :none, standing: :candidate, replay_fingerprint: "sha256:" <> d}} ->
        assert byte_size(d) == 64

      other ->
        flunk("not total on #{inspect(term, limit: 5)}: #{inspect(other, limit: 3)}")
    end
  end

  # ---------------------------------------------------------------- requests

  test "malformed requests never raise" do
    hostile = [
      nil,
      :atom,
      42,
      "binary",
      %{},
      [],
      [%{}],
      {:tuple, 1},
      %{subject: @subject},
      %{subject: "", domain: domain(), initial: :pending},
      %{subject: :ok, domain: domain(), initial: :pending},
      %{subject: 42, domain: domain(), initial: :pending},
      %{subject: @subject, domain: nil, initial: :pending},
      %{subject: @subject, domain: domain()},
      %{subject: @subject, initial: :pending},
      %{subject: @subject, domain: domain(), initial: nil},
      %{subject: @subject, domain: domain(), initial: 42},
      %{subject: @subject, domain: domain(), initial: "pending"},
      %{subject: @subject, domain: domain(), initial: {:weird, :tuple}},
      %{subject: @subject, domain: domain(), initial: :unknown_state},
      %{subject: @subject, domain: :not_a_domain, initial: :pending},
      %{subject: @subject, domain: [], initial: :pending},
      %{
        subject: @subject,
        domain: %FOND{states: MapSet.new(), goals: MapSet.new(), transitions: %{}},
        initial: :pending
      },
      %{
        subject: @subject,
        domain: %FOND{states: MapSet.new([:pending]), goals: MapSet.new(), transitions: %{}},
        initial: :pending
      }
    ]

    for request <- hostile, do: fuzz(request, fn -> request end, :good)
  end

  # --------------------------------------------------------------- candidates

  test "malformed candidates never raise" do
    d = domain()

    good_request = good_request()

    hostile_candidates = [
      nil,
      :atom,
      42,
      "binary",
      [],
      %{},
      %{subject: nil},
      %{subject: @subject},
      %{subject: @subject, domain: d, initial: :pending},
      %{subject: @subject, policy: :garbage, mode: :strong_cyclic},
      %{subject: @subject, policy: nil, mode: :strong_cyclic},
      %{subject: @subject, policy: %{}, mode: nil},
      %{subject: @subject, policy: %{}, mode: {:bad, :mode}},
      %{subject: @subject, policy: %{}, mode: "strong"},
      %{subject: @subject, policy: %{}, mode: :strong_cyclic},
      %{subject: "sha256:other", policy: :garbage, mode: :strong_cyclic}
    ]

    for candidate <- hostile_candidates,
        do: fuzz(candidate, fn -> good_request end, candidate)
  end

  # --------------------------------------------------------------------- opts

  test "hostile opts never raise" do
    request = good_request()
    candidate = good_candidate(request)

    hostile_opts = [
      nil,
      42,
      "opts",
      %{seed: 1},
      [:not_a_pair],
      [{:seed, 1}, :loose],
      [{"key", 1}],
      [seed: {11, 29, 47}, extra: :garbage],
      [seed: self()],
      [seed: {:garbage, fn -> :ok end}],
      [unknown_key: %MapSet{}]
    ]

    for opts <- hostile_opts do
      result = total(fn -> Replay.fond(request, candidate, opts) end)

      case result do
        {:error, %{code: code, authority: :none}} ->
          assert code in Refusal.codes()

        {:ok, %{authority: :none}} ->
          :ok

        other ->
          flunk("not total on opts #{inspect(opts, limit: 5)}: #{inspect(other, limit: 3)}")
      end
    end
  end

  test "legitimate happy path still admitted with authority :none" do
    request = good_request()
    candidate = good_candidate(request)

    assert {:ok,
            %{
              subject: @subject,
              authority: :none,
              standing: :candidate,
              replay_fingerprint: "sha256:" <> digest,
              bundle: %{native_verdict: :admitted}
            }} = Replay.fond(request, candidate, seed: {11, 29, 47})

    assert byte_size(digest) == 64
  end

  test "fuzz round-trip: garbage request x garbage candidate x garbage opts is total" do
    requests = [nil, 42, %{}, good_request(), good_request(initial: :nope)]

    candidates = [
      nil,
      %{},
      %{subject: @subject},
      good_candidate(good_request()),
      %{subject: @subject, policy: 0, mode: 0}
    ]

    opts = [[], :garbage, [seed: nil]]

    for r <- requests, c <- candidates, o <- opts do
      result = total(fn -> if is_list(o), do: Replay.fond(r, c, o), else: Replay.fond(r, c) end)

      assert match?({:error, %{authority: :none}}, result) or
               match?({:ok, %{authority: :none}}, result),
             "not total: #{inspect(result, limit: 3)}"
    end
  end
end
