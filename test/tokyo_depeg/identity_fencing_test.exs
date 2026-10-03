defmodule AshPPlan.TokyoDepeg.IdentityTest do
  @moduledoc """
  Tokyo-Depeg W3 stage 1 — the identity court.

  The order payload is canonicalized (JCS RFC 8785) by the pure-Elixir helper in
  test/support/tokyo_depeg/ and hashed to an effect identity. Identity stand-in
  documented on `AshPPlan.Test.TokyoDepeg.Canonical`: :blake2b stands in for the
  affidavit wasm kernel's BLAKE3 (ash_affidavit is not a mix dep here — the
  commit seam records UNSUPPORTED(no-dep) instead of faking a commit).

  Chicago: real functions over real payloads; the mutants are REAL broken
  implementations, detected via `AshPPlan.Test.Chicago.assert_detected!/4`.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Test.Chicago
  alias AshPPlan.Test.TokyoDepeg.{Affidavit, Canonical}

  @order %{
    "account" => "tokyo-fund-desk-7",
    "instrument" => "USDJPY",
    "notional" => 250_000_000,
    "price" => 158.42,
    "qty" => 1_000_000,
    "side" => "sell",
    "ts" => "2026-10-03T09:30:00Z"
  }

  # -- canonical form ----------------------------------------------------------

  test "key insertion order does not change the canonical form or identity" do
    a = %{"a" => 1, "b" => 2, "c" => %{"x" => 1, "y" => 2}}
    b = %{"c" => %{"y" => 2, "x" => 1}, "b" => 2, "a" => 1}

    assert Canonical.canonical_string(a) == Canonical.canonical_string(b)
    assert Canonical.identity(a) == Canonical.identity(b)
  end

  test "whitespace in a received JSON document is erased by canonicalization" do
    noisy = ~s({ "side" : "sell" ,\n\t "instrument" :  "USDJPY" , "qty" : 1000000 })
    clean = %{"instrument" => "USDJPY", "qty" => 1_000_000, "side" => "sell"}

    assert Canonical.identity(Jason.decode!(noisy)) == Canonical.identity(clean)
  end

  test "numbers serialize in ES6 canonical form (JCS)" do
    assert Canonical.canonical_string(%{"a" => 1.0}) == ~s({"a":1})
    assert Canonical.canonical_string(%{"a" => 100.0}) == ~s({"a":100})
    assert Canonical.canonical_string(%{"a" => 0.001}) == ~s({"a":0.001})
    assert Canonical.canonical_string(%{"a" => 1.5}) == ~s({"a":1.5})
    assert Canonical.canonical_string(%{"a" => 1.0e21}) == ~s({"a":1e21})
    assert Canonical.canonical_string(%{"a" => 1.0e-7}) == ~s({"a":1e-7})
    assert Canonical.canonical_string(%{"a" => -0.0}) == ~s({"a":0})
  end

  test "strings escape per JSON; non-ASCII passes through as UTF-8" do
    assert Canonical.canonical_string(%{"s" => "a\"b\\c\nd"}) ==
             ~S({"s":"a\"b\\c\nd"})

    assert Canonical.canonical_string(%{"s" => "円-¥"}) == ~s({"s":"円-¥"})
    assert Canonical.canonical_string(%{"s" => "\u0001"}) == ~s({"s":"\\u0001"})
  end

  test "representation variance that JCS erases does not change identity" do
    assert Canonical.identity(%{"q" => 1}) == Canonical.identity(%{"q" => 1.0})
    assert Canonical.identity(%{q: 1}) == Canonical.identity(%{"q" => 1})
  end

  test "identity is deterministic and total over the order corpus" do
    id = Canonical.identity(@order)

    assert id == Canonical.identity(@order)
    assert String.length(id) == 128

    for i <- 1..1_000 do
      order = Map.put(@order, "qty", @order["qty"] + i)
      assert Canonical.identity(order) == Canonical.identity(order)
    end
  end

  test "semantically different orders get different identities (no collisions in the corpus)" do
    variants = [
      @order,
      Map.put(@order, "side", "buy"),
      Map.put(@order, "qty", @order["qty"] + 1),
      Map.put(@order, "instrument", "EURJPY"),
      Map.put(@order, "price", 158.43),
      Map.put(@order, "account", "frankfurt-clearing-1")
    ]

    ids = Enum.map(variants, &Canonical.identity/1)
    assert length(Enum.uniq(ids)) == length(variants)
  end

  # -- mutant witness (anti-vacuity) --------------------------------------------

  test "a non-canonical identity function is detected (mutant witness)" do
    property = fn hasher ->
      same_order_a = %{"a" => 1, "b" => [1, %{"x" => 1.0}], "c" => "q\"s"}
      same_order_b = %{"b" => [1, %{"x" => 1}], "a" => 1, "c" => "q\"s"}

      different_order = Map.put(same_order_a, "side", "buy")

      # identity must be invariant under JCS-erased representation variance
      # (key order, 1 vs 1.0) and must change when content changes.
      if hasher.(same_order_a) == hasher.(same_order_b) and
           hasher.(same_order_a) != hasher.(different_order) do
        :pass
      else
        {:fail, :identity}
      end
    end

    sabotages = [
      # naive hasher over term_to_binary: distinguishes 1 from 1.0 — a
      # re-serialized duplicate would mint a second effect identity and
      # double-execute.
      {"term_to_binary hasher (no canonicalization)", &:erlang.term_to_binary/1},
      # naive inspect-concat hasher: same defect class.
      {"inspect-concat hasher", fn t -> inspect(t, limit: :infinity) end}
    ]

    assert :detected =
             Chicago.assert_detected!("jcs identity", &Canonical.identity/1, sabotages, property)
  end

  # -- the affidavit commit seam --------------------------------------------------

  test "effect identity commits to the real affidavit wasm host when it is a dep" do
    case Affidavit.commit(Canonical.canonical_string(@order)) do
      {:ok, receipt} ->
        # Real kernel path: a commit receipt exists for the canonical bytes.
        assert receipt != nil

      {:unsupported, reason, message} ->
        # Honest record, not a fake pass: ash_affidavit is not a mix dep of
        # ash_pplan, so the BLAKE3 path is UNSUPPORTED here by design.
        assert reason in [:no_dep, :no_commit_op]
        assert message =~ "ash_affidavit"
    end
  end
end

defmodule AshPPlan.TokyoDepeg.FencingTest do
  @moduledoc """
  Tokyo-Depeg W3 stage 2 — the fencing court.

  200 concurrent duplicate orders (identical JCS identity -> identical run id)
  hit the real durable Engine claim-CAS (`Store.Ets.claim/5` lease): exactly one
  attempt executes the trade lifecycle; every duplicate replays prior evidence
  (`:taken` while held, `:ended` once terminal) and re-executes nothing.
  Mutant witness: a REAL naive check-then-act dedup (`BrokenFence`, no CAS)
  lets multiple executors through and is DETECTED.

  Real collaborators only: real Engine, real Store.Ets, real Reactor steps,
  real counting effects. No mocks.
  """
  use ExUnit.Case, async: false

  # LaneBFx is a test/ require fixture, not an elixirc_paths-compiled module.
  Code.require_file("../../test/durable/lane_b_fixture.exs", __DIR__)

  alias AshPPlan.Durable.LaneBFx
  alias AshPPlan.Reactor.Durable.Engine
  alias AshPPlan.Reactor.Durable.Store.Ets
  alias AshPPlan.Test.Chicago
  alias AshPPlan.Test.Effects
  alias AshPPlan.Test.TokyoDepeg.{BrokenFence, Canonical}

  @n 200

  setup do
    LaneBFx.install_adapter!()

    fx = :"tdb_fx_#{System.unique_integer([:positive])}"
    {:ok, _} = Effects.start_link(name: fx)
    {:ok, store} = Ets.start_link()

    {:ok, store: store, fx: fx}
  end

  defp order_id(payload), do: "tdb-run-" <> String.slice(Canonical.identity(payload), 0, 32)

  defp engine_barrage(store, fx, n, run_id) do
    tasks =
      Enum.map(1..n, fn _ ->
        Task.async(fn ->
          # duplicates converge on the identity-derived run id; Engine.start is
          # idempotent by attrs.id, so duplicate arrivals cannot mint a new run.
          LaneBFx.attrs(run_id, fx)
          |> then(&Engine.start(store, &1))

          Engine.attempt(store, run_id)
        end)
      end)

    Task.await_many(tasks, 30_000)
  end

  test "200 concurrent duplicate orders: exactly one executes, the rest replay prior evidence",
       %{store: store, fx: fx} do
    order = %{
      "account" => "tokyo-fund-desk-7",
      "instrument" => "USDJPY",
      "notional" => 250_000_000,
      "side" => "sell",
      "ts" => "2026-10-03T09:30:00.123456Z"
    }

    run_id = order_id(order)

    outcomes = engine_barrage(store, fx, @n, run_id)

    assert length(outcomes) == @n

    # exactly one executor; the duplicates never re-run the lifecycle
    assert Enum.count(outcomes, &match?({:completed, _}, &1)) == 1
    assert Enum.all?(outcomes, &(match?({:completed, _}, &1) or &1 in [:taken, :ended]))

    # the executed lifecycle ran each step exactly once
    assert LaneBFx.counts(fx) == %{
             observe: 1,
             select: 1,
             execute: 1,
             integrate: 1,
             verify: 1
           }

    assert Engine.fetch(store, run_id).status == :completed

    # replay of prior evidence AFTER the terminal write: a late duplicate is
    # answered from the durable record, not re-executed
    assert Engine.attempt(store, run_id) == :ended

    assert LaneBFx.counts(fx) == %{
             observe: 1,
             select: 1,
             execute: 1,
             integrate: 1,
             verify: 1
           }
  end

  test "distinct orders (different identities) each execute their own lifecycle",
       %{store: store, fx: fx} do
    o1 = %{"instrument" => "USDJPY", "qty" => 1_000_000, "ts" => "t1"}
    o2 = %{"instrument" => "USDJPY", "qty" => 2_000_000, "ts" => "t2"}

    for order <- [o1, o2] do
      run_id = order_id(order)

      assert outcomes = engine_barrage(store, fx, 4, run_id)
      assert outcomes |> Enum.filter(&match?({:completed, _}, &1)) |> Enum.uniq() |> length() == 1
    end

    assert %{observe: 2, select: 2, execute: 2, integrate: 2, verify: 2} = LaneBFx.counts(fx)
  end

  test "a broken dedup (no CAS) is DETECTED by the same barrage (mutant witness)",
       %{store: store, fx: fx} do
    order = %{"instrument" => "USDJPY", "qty" => 999, "ts" => "mutant"}
    run_id = order_id(order)

    property = fn subject ->
      case subject.run_barrage.(@n, run_id) do
        :pass -> :pass
        {:fail, _} = f -> f
      end
    end

    subject = %{run_barrage: fn n, id -> engine_barrage(store, fx, n, id) |> classify() end}

    sabotage = %{
      run_barrage: fn n, id -> BrokenFence.run_barrage(n, id) end
    }

    assert :detected =
             Chicago.assert_detected!("claim-CAS exactly-once", subject, [
               {"naive check-then-act dedup (no CAS)", sabotage}
             ], property)
  end

  defp classify(outcomes) do
    execs = Enum.count(outcomes, &match?({:completed, _}, &1))

    if execs == 1 and
         Enum.all?(outcomes, &(match?({:completed, _}, &1) or &1 in [:taken, :ended])),
      do: :pass,
      else: {:fail, execs}
  end
end
