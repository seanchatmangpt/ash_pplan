defmodule AshPPlan.Hardening.AuthorityCeilingFuzzTest do
  @moduledoc """
  P2a fuzz court for `AshPPlan.PolicyClosure.AuthorityCeiling.admit/1`. Law:
  members `[:observe, :select, :construct]` admit `{:ok, x}`; everything else
  — every other atom, every garbage term — refuses typed
  `{:error, :authority_ceiling}`. Never a raise. Seeded deterministic sweep
  (no stream_data in deps).
  """

  use ExUnit.Case, async: true

  alias AshPPlan.PolicyClosure.AuthorityCeiling

  @members [:observe, :select, :construct]

  @garbage [
    nil,
    true,
    false,
    42,
    0,
    -1,
    1.5,
    "observe",
    "select",
    "",
    <<0, 255>>,
    :observe_alias,
    self(),
    [],
    [:observe],
    %{},
    %{op: :observe},
    {:observe},
    {:ok, :construct},
    &String.length/1,
    MapSet.new([:observe]),
    <<1::1>>,
    Date.utc_today()
  ]

  test "every member admits itself" do
    for m <- @members do
      assert AuthorityCeiling.admit(m) == {:ok, m}
    end
  end

  test "every non-member atom in a broad pool refuses typed" do
    :rand.seed(:exsss, {31, 300_000, 200_000})

    atoms =
      Enum.uniq(
        @garbage ++
          for i <- 1..500 do
            String.to_atom("authority_fuzz_#{i}_#{:rand.uniform(4096)}")
          end
      )

    assert length(atoms) >= 500

    for a <- atoms do
      assert AuthorityCeiling.admit(a) == {:error, :authority_ceiling},
             "atom #{inspect(a)} escaped the ceiling"
    end
  end

  test "every garbage non-atom term refuses typed" do
    for g <- @garbage do
      assert AuthorityCeiling.admit(g) == {:error, :authority_ceiling},
             "term #{inspect(g)} escaped the ceiling"
    end
  end

  test "lookalike terms near members still refuse" do
    near =
      for m <- @members,
          v <- [Atom.to_string(m), String.to_atom("#{m}s"), {:ok, m}, [m], %{x: m}, :"#{m} "] do
        v
      end

    for v <- near do
      assert AuthorityCeiling.admit(v) == {:error, :authority_ceiling}
    end
  end

  test "never raises across a seeded random term stream" do
    :rand.seed(:exsss, {9, 100_000, 700_000})

    for _ <- 1..500 do
      term =
        case :rand.uniform(5) do
          1 -> :rand.uniform(1_000_000)
          2 -> :crypto.strong_rand_bytes(8)
          3 -> String.to_atom("fuzz_#{:rand.uniform(100_000)}")
          4 -> {make_ref(), self()}
          _ -> %{:rand.uniform(9) => make_ref()}
        end

      assert AuthorityCeiling.admit(term) in [{:error, :authority_ceiling}, {:ok, term}]
    end
  end
end
