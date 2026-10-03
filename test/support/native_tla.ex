defmodule AshPPlan.Test.NativeTLA do
  @moduledoc """
  JVM-free TLA+ court helper: runs the pinned `tla-rs` (tla v0.11.1, Rust) binary as a
  real subprocess over a `.tla`/`.cfg` pair.

  The binary is fetched from
  `https://github.com/fabracht/tla-rs/releases/download/v0.11.1/tla-macos-arm64`
  into `tools/tla-rs` (gitignored, not packaged: `lib/` and `priv/` stay clean) and is
  admitted only when its SHA-256 equals the pinned digest — a present binary with another
  digest raises, so a wrong checker never decides verdicts.

  Classification fails closed: only tla-rs's explicit completion line ("No errors found")
  counts as `:admitted`; only an explicit "violated!" + counterexample counts as `:refused`;
  anything else raises, so a broken run can never masquerade as a pass. (tla-rs v0.11.1
  exits 0 even on an invariant violation, so the exit status is NOT load-bearing.)

  Skip semantics mirror `AshPPlan.Test.TLCCourt`: the checker is optional locally (named
  skip when the binary is absent) and mandatory under `ASH_PPLAN_REQUIRE_TLA=1`, where an
  unavailable checker raises.
  """

  @version "0.11.1"
  @sha256 "11fbbca865e030fa0a6e0182ced339d911a9581ebe1f0e092834955b16f34d5a"

  @doc "Pinned tla-rs version."
  def version, do: @version

  @doc "Pinned SHA-256 of the checker binary."
  def binary_sha256, do: @sha256

  @doc "Path of the pinned checker binary (overridable via ASH_PPLAN_TLA_RS)."
  def binary_path do
    System.get_env("ASH_PPLAN_TLA_RS") ||
      Path.expand("tools/tla-rs", File.cwd!())
  end

  @doc """
  Returns `:ok` or `{:unavailable, reason}` for skip tagging. Under
  `ASH_PPLAN_REQUIRE_TLA=1` an unavailable checker raises instead of skipping.
  """
  def availability do
    decide_availability(observe_availability(), System.get_env("ASH_PPLAN_REQUIRE_TLA"))
  end

  @doc false
  def decide_availability({:unavailable, reason}, "1") when is_binary(reason) do
    raise "ASH_PPLAN_REQUIRE_TLA=1 but the native tla-rs court is unavailable: " <> reason
  end

  def decide_availability({:unavailable, _reason} = unavailable, _require), do: unavailable

  def decide_availability(:ok, _require), do: :ok

  @doc false
  def observe_availability do
    path = binary_path()

    cond do
      not File.regular?(path) ->
        {:unavailable, "tla-rs #{@version} binary absent at #{path}"}

      not executable?(path) ->
        {:unavailable, "tla-rs binary at #{path} is not executable"}

      true ->
        :ok
    end
  end

  @doc "Verifies the pinned digest; raises on mismatch."
  def verify_binary!(path \\ binary_path()) do
    digest = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

    if digest != @sha256 do
      raise "tla-rs digest mismatch at #{path}: #{digest} != #{@sha256}"
    end

    digest
  end

  @doc """
  Runs tla-rs on `spec_path` with `cfg_path`. Returns
  `%{verdict: :admitted | :refused, kind: atom, output: binary, stats: %{states, transitions, depth}}`.
  Raises on unavailable checker, digest mismatch or unclassifiable output (fail closed).
  """
  def check!(spec_path, cfg_path) when is_binary(spec_path) and is_binary(cfg_path) do
    :ok = availability()
    verify_binary!()

    args = [Path.absname(spec_path), "--config", Path.absname(cfg_path)]

    {output, _status} =
      System.cmd(binary_path(), args, stderr_to_stdout: true, env: [{"NO_COLOR", "1"}])

    Map.put(classify!(output), :output, output)
  end

  @doc """
  Writes `cfg_text`/`spec_text` into a scratch dir and checks them.
  Takes `name` (module name), `spec` and `cfg` strings.
  """
  def check_string!(name, spec, cfg) when is_binary(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_tlars_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}"
      )

    File.mkdir_p!(dir)

    try do
      File.write!(Path.join(dir, name <> ".tla"), spec)
      File.write!(Path.join(dir, name <> ".cfg"), cfg)
      check!(Path.join(dir, name <> ".tla"), Path.join(dir, name <> ".cfg"))
    after
      File.rm_rf!(dir)
    end
  end

  # tla-rs v0.11.1 output classification, fail closed.
  # - admitted: "Model checking complete. No errors found."
  # - refused:  "violated!" plus a "Counterexample trace"
  # - anything else raises: parse errors, crashes, missing output never decide verdicts.
  defp classify!(output) when is_binary(output) do
    cond do
      line?(output, "No errors found") ->
        %{verdict: :admitted, kind: :no_error, stats: stats(output)}

      line?(output, "violated!") and line?(output, "Counterexample trace") ->
        %{verdict: :refused, kind: :counterexample, stats: stats(output)}

      true ->
        raise "unclassifiable tla-rs output (fail closed): #{inspect(binary_part(output, 0, min(byte_size(output), 400)))}"
    end
  end

  defp line?(output, needle), do: output =~ needle

  defp stats(output) do
    states = match_int(output, ~r/Reachable states:\s*(\d+)/)
    transitions = match_int(output, ~r/Transitions:\s*(\d+)/)
    depth = match_int(output, ~r/Max depth:\s*(\d+)/)
    %{states: states, transitions: transitions, depth: depth}
  end

  defp match_int(output, re) do
    case Regex.run(re, output) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end
end
