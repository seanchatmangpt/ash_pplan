defmodule AshPPlan.Reactor.Durable.StoreWalIntegrityTest do
  use ExUnit.Case, async: false
  alias AshPPlan.Reactor.Durable.Store.Wal

  @t0 ~U[2026-01-01 00:00:00Z]

  defp fresh_wal do
    path = Path.join(System.tmp_dir!(), "wal-itg-#{System.unique_integer([:positive])}.log")
    {:ok, wal} = Wal.open(path)

    case Wal.start_run(wal, %{id: "r1"}) do
      {:ok, _} -> :ok
      {:error, reason} -> flunk("fresh_wal: start_run failed: #{inspect(reason)}")
    end

    {wal, path}
  end

  defp cleanup({wal, path}) do
    Wal.close(wal)
    File.rm(path)
    :ok
  end

  test "reopen survives a consumed signal frame (V5 P1)" do
    ctx = fresh_wal()
    {wal, path} = ctx
    assert {:ok, sig} = Wal.deliver_signal(wal, "r1", "go", :p)
    assert {:ok, _} = Wal.consume_signal(wal, sig.id, @t0)
    Wal.close(wal)

    assert {:ok, reopened} = Wal.open(path)
    assert length(Wal.signals(reopened, "r1")) == 1
    assert Wal.pending_signal(reopened, "r1", "go") == nil
    assert Wal.consume_signal(reopened, sig.id, @t0) == :taken
    cleanup(ctx)
  end

  test "mid-stream CRC corruption refuses open with typed wal_integrity" do
    ctx = fresh_wal()
    {wal, path} = ctx
    assert {:ok, _} = Wal.deliver_signal(wal, "r1", "a", 1)
    assert {:ok, _} = Wal.deliver_signal(wal, "r1", "b", 2)
    Wal.close(wal)

    # flip one payload byte inside the first frame (offset 8 + 4 => into payload)
    bytes = File.read!(path)
    <<head::binary-size(10), rest::binary>> = bytes
    <<bad, tail::binary>> = rest
    File.write!(path, <<head::binary, :erlang.bxor(bad, 0xFF), tail::binary>>)

    assert {:error, {:wal_integrity, {:crc_mismatch, 0}}} = Wal.open(path)
    cleanup(ctx)
  end

  test "torn append tail truncates at last good frame and reopens clean" do
    ctx = fresh_wal()
    {wal, path} = ctx
    assert {:ok, _} = Wal.deliver_signal(wal, "r1", "a", 1)
    Wal.close(wal)
    good_size = byte_size(File.read!(path))

    # append a torn 5-byte pseudo-frame
    File.write!(path, <<1, 2, 3, 4, 5>>, [:append])
    assert {:ok, reopened} = Wal.open(path)
    assert byte_size(File.read!(path)) == good_size
    assert length(Wal.signals(reopened, "r1")) == 1
    cleanup(ctx)
  end

  test "record refuses new checkpoints on :cancelling, adopts existing keys" do
    ctx = fresh_wal()
    {wal, _path} = ctx
    {:ok, _} = Wal.transition(wal, "r1", :any, :cancelling, %{})
    assert {:error, :cancelling} = Wal.record(wal, "r1", "new", "n", 1, %{})
    assert {:ok, _} = Wal.transition(wal, "r1", :any, :cancelled, %{})
    assert {:error, :terminal} = Wal.record(wal, "r1", "new2", "n", 2, %{})
    cleanup(ctx)
  end

  # =================================================================
  # Z6: batched append writer
  # =================================================================

  defp wait_until(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until: condition not met within deadline")
      else
        Process.sleep(5)
        do_wait_until(fun, deadline)
      end
    end
  end

  test "Z6: every ACKED write survives a kill mid-burst (F1 338/338 pattern)" do
    ctx = fresh_wal()
    {wal, path} = ctx

    tasks =
      for i <- 1..60 do
        Task.async(fn ->
          # An acked record (returns {:ok, _}) MUST survive any crash; a caller still
          # blocked when the writer dies may lose its frame (that caller gets an exit).
          try do
            case Wal.record(wal, "r1", "z6-#{i}", "s", {:out, i}, %{name: "n#{i}"}) do
              {:ok, _cp} -> "z6-#{i}"
              _ -> :not_acked
            end
          catch
            :exit, _ -> :not_acked
          end
        end)
      end

    # wait until a real ack lands (observable via the index), then kill mid-burst
    wait_until(
      fn ->
      wal
      |> Wal.checkpoints("r1")
      |> Map.keys()
      |> Enum.any?(&String.starts_with?(&1, "z6-"))
    end, 15_000)

    # kill the writer mid-burst (no grace, no flush-on-stop); unlink first — the writer
    # is linked to the opener, and we want the store's crash semantics, not ours.
    Process.unlink(wal.writer)
    Process.exit(wal.writer, :kill)

    results = Task.await_many(tasks, 10_000)

    acked_keys = Enum.filter(results, &is_binary/1)

    assert acked_keys != [], "burst must have produced at least one ack before the kill"

    assert {:ok, reopened} = Wal.open(path)
    cps = Wal.checkpoints(reopened, "r1")

    # every ACKED write must be present after reopen (crash window: unacked only)
    Enum.each(acked_keys, fn k ->
      assert Map.has_key?(cps, k), "acked write #{k} lost across crash+reopen"
    end)

    Wal.close(reopened)
    cleanup(ctx)
  end

  test "Z6: acked record is durable across reopen (force-flush durability)" do
    ctx = fresh_wal()
    {wal, path} = ctx

    assert {:ok, cp} = Wal.record(wal, "r1", "z6-durable", "s", 1, %{name: "d"})
    Wal.close(wal)

    assert {:ok, reopened} = Wal.open(path)
    assert Map.has_key?(Wal.checkpoints(reopened, "r1"), "z6-durable")
    assert cp.seq == Wal.checkpoints(reopened, "r1")["z6-durable"].seq
    Wal.close(reopened)
    cleanup(ctx)
  end

  test "Z6: async frames flush at the N-frame trigger without any ack call" do
    ctx = fresh_wal()
    {wal, path} = ctx
    before = File.stat!(path).size

    # > @batch_frames (32) nack frames buffered in the writer
    for i <- 1..40 do
      Wal.Writer.append_async(wal.writer, signal_frame_bytes(wal, i))
    end

    wait_until(fn -> File.stat!(path).size > before end)
    assert File.stat!(path).size > before
    cleanup(ctx)
  end

  test "Z6: async frames flush at the deadline trigger (25ms)" do
    ctx = fresh_wal()
    {wal, path} = ctx
    before = File.stat!(path).size

    Wal.Writer.append_async(wal.writer, signal_frame_bytes(wal, 1))

    # deadline is 25ms; poll within a generous bounded budget (no-sleep law: poll, don't fix-sleep)
    wait_until(fn -> File.stat!(path).size > before end, 2_000)
    cleanup(ctx)
  end

  # A well-formed {:signal, %Signal{}} frame built by hand (bypasses the store callbacks,
  # which are all ack-class) so the writer's async path can be exercised in isolation.
  defp signal_frame_bytes(_wal, i) do
    sig = %AshPPlan.Reactor.Durable.Signal{
      id: "sig-z6-#{i}",
      run_id: "r1",
      name: "z6-async",
      payload: i,
      seq: 10_000 + i
    }

    payload = :erlang.term_to_binary({:signal, sig})
    len = byte_size(payload)
    crc = :erlang.crc32(payload)
    <<len::unsigned-integer-32, crc::unsigned-integer-32, payload::binary>>
  end
end
