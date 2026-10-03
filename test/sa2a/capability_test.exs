defmodule AshPPlan.SA2A.CapabilityTest do
  use ExUnit.Case, async: true

  alias AshPPlan.SA2A.Capability

  test "planner capability is candidate-only and has no DO authority" do
    assert Capability.supports?(:fond)
    assert Capability.supports?(:powl)
    refute Capability.supports?(:hddl)

    assert %{
             authority: :none,
             standing: :candidate,
             select: true,
             construct: true,
             do: false
           } = Capability.descriptor(:fond)
  end

  test "supported formalisms and the powl descriptor are candidate-only" do
    assert Capability.supported() == [:fond, :powl]

    assert %{authority: :none, standing: :candidate, select: true, construct: true, do: false} =
             Capability.descriptor(:powl)

    # descriptor/1 keeps the candidate-only, no-DO shape for every supported formalism
    for f <- Capability.supported() do
      assert %{authority: :none, standing: :candidate, do: false} = Capability.descriptor(f)
    end
  end

  test "consumer adapter's hardcoded supports?/1 list matches owner capability discovery" do
    port = Path.expand("~/ash_a2a/lib/ash_a2a/replan/port/ash_pplan.ex")

    assert File.exists?(port),
           "consumer adapter checkout missing at #{port} — the supports?/1 duplication " <>
             "court (notes/sa2a-adapter-verdict-2026-10-03.md watch item) cannot run"

    source = File.read!(port)

    hardcoded =
      Regex.scan(~r/supports\?\(formalism\), do: formalism in \[([^\]]*)\]/, source)
      |> Enum.flat_map(&tl/1)
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim(&1))
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.to_atom(String.trim_leading(&1, ":")))
      |> Enum.uniq()

    assert hardcoded != [],
           "no hardcoded supports?/1 capability list found in the consumer adapter"

    assert hardcoded == Capability.supported(),
           "consumer adapter supports?/1 drifted from AshPPlan.SA2A.Capability.supported/0: " <>
             "adapter=#{inspect(hardcoded)} owner=#{inspect(Capability.supported())} — " <>
             "move the consumer to owner capability discovery or update both sides together"
  end
end
