defmodule AshPPlan.Reactor.Durable.Store.WalCrcCourtTest do
  @moduledoc """
  ARD Tier 2 §4 court: `Store.Wal` CRC fail-closed.

  Real files in a tmp dir, real `Wal` store, no doubles, no fixed sleeps. Every
  mutation is applied to the bytes on disk after `Wal.close/1` (which flushes the
  writer), then `Wal.open/1` is the subject under test.

  Pinned shapes (from `lib/ash_pplan/reactor/durable/store/wal.ex`):

    * frame = `<<len::32, crc32::32, payload::binary>>`, crc = `:erlang.crc32(payload)`
    * mid-stream CRC mismatch  -> `{:error, {:wal_integrity, {:crc_mismatch, frame_offset}}}`
    * undecodable payload      -> `{:error, {:wal_integrity, :undecodable_frame}}`
    * torn tail (len > remain) -> file truncated at last good frame, open proceeds

  Non-vacuity: the SAME byte flip that is refused in the CRC-mismatch court is
  ACCEPTED when the frame's CRC is recomputed the way `append_frame/2` does. The
  court therefore keys on the CRC, not on byte equality with what was written.
  """
  use ExUnit.Case, async: false

  alias AshPPlan.Reactor.Durable.Store.Wal

  @run_id "crc-court-r1"
  @record_count 5
  # 64-byte run of "a" inside each checkpoint output: a flipped byte inside this run
  # keeps the external term format decodable (binary length header unchanged), so the
  # CRC is the only thing deciding accept vs refuse.
  @filler String.duplicate("a", 64)
  @probe "aaaaaaaa"

  # ---------------------------------------------------------------------------
  # setup
  # ---------------------------------------------------------------------------

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "wal-crc-court-#{System.unique_integer([:positive])}.wal"
      )

    on_exit(fn -> File.rm(path) end)

    {:ok, wal} = Wal.open(path)
    {:ok, _run} = Wal.start_run(wal, %{id: @run_id, inputs: %{court: :crc}})

    written =
      for i <- 1..@record_count, into: %{} do
        key = "s#{i}"

        {:ok, cp} =
          Wal.record(wal, @run_id, key, "Step #{i}", "body-#{i}-" <> @filler, %{name: "n#{i}"})

        {key, cp}
      end

    run = Wal.get_run(wal, @run_id)
    :ok = Wal.close(wal)

    %{path: path, written: written, run: run, bytes: File.read!(path)}
  end

  # ---------------------------------------------------------------------------
  # courts
  # ---------------------------------------------------------------------------

  test "untouched file replays byte-identical records and leaves the file bytes unchanged",
       %{path: path, written: written, run: run, bytes: bytes} do
    assert {:ok, reopened} = Wal.open(path)

    replayed = Wal.checkpoints(reopened, @run_id)
    assert map_size(replayed) == @record_count
    assert replayed == written
    assert Wal.get_run(reopened, @run_id) == run

    # replaying a clean log must not rewrite it (no spurious truncate_tail)
    assert File.read!(path) == bytes

    :ok = Wal.close(reopened)
  end

  test "one flipped payload byte mid-stream refuses open with the typed crc_mismatch error at the frame offset",
       %{path: path, bytes: bytes} do
    frames = parse_frames(bytes)
    {frame_offset, len, _crc, payload} = checkpoint_frame(frames, "s3")
    # the frame must be MID-STREAM, not the tail, to exercise the refuse path (not truncate)
    assert frame_offset + 8 + len < byte_size(bytes)

    flip_at = frame_offset + 8 + probe_pos(payload)
    File.write!(path, flip_byte(bytes, flip_at))

    result = Wal.open(path)
    assert {:error, {:wal_integrity, {:crc_mismatch, ^frame_offset}}} = result
    refute result == :error
    refute match?({:error, :wal_integrity}, result)

    # refusal is fail-closed: the log is left exactly as found, never "repaired"
    assert File.read!(path) == flip_byte(bytes, flip_at)
  end

  test "the same flipped byte with a recomputed CRC is ACCEPTED and the flipped value replays (non-vacuity)",
       %{path: path, bytes: bytes, written: written} do
    frames = parse_frames(bytes)
    {frame_offset, len, _crc, payload} = checkpoint_frame(frames, "s3")

    pos = probe_pos(payload)
    forged_payload = flip_byte(payload, pos)
    forged_crc = :erlang.crc32(forged_payload)

    forged_frame =
      <<len::unsigned-integer-32, forged_crc::unsigned-integer-32, forged_payload::binary>>

    <<head::binary-size(frame_offset), _old::binary-size(8 + len), tail::binary>> = bytes
    File.write!(path, head <> forged_frame <> tail)

    assert {:ok, reopened} = Wal.open(path)
    replayed = Wal.checkpoints(reopened, @run_id)
    assert map_size(replayed) == @record_count

    # the forged record is what replays: the index trusts the CRC, not the original bytes
    forged = replayed["s3"]
    original = written["s3"]
    refute forged.output == original.output
    assert String.length(forged.output) == String.length(original.output)
    assert String.contains?(forged.output, flipped_probe())
    assert Map.delete(forged, :output) == Map.delete(original, :output)

    # every other record is untouched
    for k <- Map.keys(written) -- ["s3"], do: assert(replayed[k] == written[k])

    :ok = Wal.close(reopened)
  end

  test "a CRC-valid frame whose payload does not decode refuses open with :undecodable_frame",
       %{path: path, bytes: bytes} do
    frames = parse_frames(bytes)
    {frame_offset, len, _crc, _payload} = checkpoint_frame(frames, "s2")

    garbage = :binary.copy(<<0xFF>>, len)
    garbage_crc = :erlang.crc32(garbage)
    frame = <<len::unsigned-integer-32, garbage_crc::unsigned-integer-32, garbage::binary>>
    <<head::binary-size(frame_offset), _old::binary-size(8 + len), tail::binary>> = bytes
    File.write!(path, head <> frame <> tail)

    assert {:error, {:wal_integrity, :undecodable_frame}} = Wal.open(path)
  end

  test "file truncated mid-record (torn tail) drops only the torn record and truncates to the last good frame boundary",
       %{path: path, bytes: bytes, written: written} do
    frames = parse_frames(bytes)
    {last_offset, last_len, _crc, _payload} = List.last(frames)
    assert last_offset + 8 + last_len == byte_size(bytes)

    # cut inside the last frame's payload: header is intact, body is short
    cut = last_offset + 8 + div(last_len, 2)
    <<torn::binary-size(cut), _::binary>> = bytes
    File.write!(path, torn)

    assert {:ok, reopened} = Wal.open(path)

    # pinned law: torn tail is crash recovery, truncated at the last good boundary
    assert byte_size(File.read!(path)) == last_offset
    assert File.read!(path) == binary_part(bytes, 0, last_offset)

    replayed = Wal.checkpoints(reopened, @run_id)
    assert map_size(replayed) == @record_count - 1
    refute Map.has_key?(replayed, "s#{@record_count}")
    for k <- Map.keys(replayed), do: assert(replayed[k] == written[k])

    :ok = Wal.close(reopened)
  end

  test "file truncated inside the last frame HEADER (< 8 bytes left) truncates to the last good boundary",
       %{path: path, bytes: bytes} do
    frames = parse_frames(bytes)
    {last_offset, _len, _crc, _payload} = List.last(frames)

    <<torn::binary-size(last_offset + 5), _::binary>> = bytes
    File.write!(path, torn)

    assert {:ok, reopened} = Wal.open(path)
    assert byte_size(File.read!(path)) == last_offset
    assert map_size(Wal.checkpoints(reopened, @run_id)) == @record_count - 1
    :ok = Wal.close(reopened)
  end

  test "frame layout on disk matches the pinned <<len::32, crc32::32, payload>> framing",
       %{bytes: bytes, written: written} do
    frames = parse_frames(bytes)
    # start_run + N checkpoints, nothing else
    assert length(frames) == 1 + @record_count

    Enum.each(frames, fn {_off, len, crc, payload} ->
      assert byte_size(payload) == len
      assert :erlang.crc32(payload) == crc
    end)

    decoded = Enum.map(frames, fn {_, _, _, p} -> :erlang.binary_to_term(p, [:safe]) end)
    assert [{:start_run, %{id: @run_id}} | cps] = decoded

    assert Enum.map(cps, fn {:checkpoint, cp} -> {cp.step_key, cp} end) |> Map.new() == written
  end

  # ---------------------------------------------------------------------------
  # helpers: the on-disk frame grammar, implemented independently of wal.ex
  # ---------------------------------------------------------------------------

  # [{offset, len, crc, payload}] for a well-formed log
  defp parse_frames(bytes), do: parse_frames(bytes, 0, [])

  defp parse_frames(<<>>, _offset, acc), do: Enum.reverse(acc)

  defp parse_frames(
         <<len::unsigned-integer-32, crc::unsigned-integer-32, payload::binary-size(len),
           rest::binary>>,
         offset,
         acc
       ) do
    parse_frames(rest, offset + 8 + len, [{offset, len, crc, payload} | acc])
  end

  defp checkpoint_frame(frames, step_key) do
    Enum.find(frames, fn {_off, _len, _crc, payload} ->
      match?({:checkpoint, %{step_key: ^step_key}}, :erlang.binary_to_term(payload, [:safe]))
    end) || flunk("no checkpoint frame for #{step_key}")
  end

  # byte position inside `payload` of the 4th byte of the "aaaaaaaa" probe run
  defp probe_pos(payload) do
    {start, _} = :binary.match(payload, @probe)
    start + 3
  end

  defp flip_byte(bin, pos) do
    <<head::binary-size(pos), b, tail::binary>> = bin
    <<head::binary, :erlang.bxor(b, 0x03), tail::binary>>
  end

  # "a" (0x61) bxor 0x03 == "b" (0x62): the flipped probe reads "aaabaaaa"
  defp flipped_probe, do: "aaab" <> "aaaa"
end
