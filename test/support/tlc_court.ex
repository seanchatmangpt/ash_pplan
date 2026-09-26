defmodule AshPPlan.Test.TLCCourt do
  @moduledoc """
  Runs the pinned TLC model checker (tla2tools 1.7.4) as a real `java`
  subprocess over a model rendered by `AshPPlan.FOND.to_tla/4`.

  The jar is read from the autofde-lab cache and admitted only when its SHA-256
  equals the pinned digest. A present jar with another digest is a court error
  (raised), never a skip: a wrong checker must not silently decide verdicts.

  Verdict classification fails closed: only TLC's explicit completion line
  counts as `:admitted`, only an explicit temporal-property or deadlock
  violation counts as `:refused`; anything else (parse error, crash, missing
  output) raises, so a broken rendering cannot masquerade as a refusal.
  """

  @jar_version "1.7.4"
  @jar_sha256 "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"

  def jar_sha256, do: @jar_sha256

  def jar_path do
    System.get_env("ASH_PPLAN_TLA2TOOLS_JAR") ||
      Path.join([
        System.user_home!(),
        ".cache/autofde-lab/tla2tools",
        @jar_version,
        "tla2tools.jar"
      ])
  end

  @doc """
  Returns `:ok` or `{:unavailable, reason}` for skip tagging.

  With `ASH_PPLAN_REQUIRE_TLC=1` (set by CI) an unavailable checker raises
  instead: the court is mandatory there, so a missing jar or JVM must fail the
  run rather than turn every differential test into a skip.
  """
  def availability do
    result = observe_availability()

    case {result, System.get_env("ASH_PPLAN_REQUIRE_TLC")} do
      {{:unavailable, reason}, "1"} ->
        raise "ASH_PPLAN_REQUIRE_TLC=1 but the TLC court is unavailable: " <> reason

      _ ->
        result
    end
  end

  @doc false
  def observe_availability do
    cond do
      System.find_executable("java") == nil ->
        {:unavailable, "java executable not on PATH"}

      not File.regular?(jar_path()) ->
        {:unavailable, "tla2tools #{@jar_version} jar absent at #{jar_path()}"}

      true ->
        :ok
    end
  end

  @doc "Verifies the pinned digest; raises on mismatch."
  def verify_jar!(path \\ jar_path()) do
    digest = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

    if digest != @jar_sha256 do
      raise "tla2tools digest mismatch at #{path}: #{digest} != #{@jar_sha256}"
    end

    digest
  end

  @doc """
  Checks a rendered model. Returns `%{verdict: :admitted | :refused, kind: ...,
  exit_status: integer, output: binary}`.
  """
  def check!(%{module_name: name, module: module, cfg: cfg}) do
    verify_jar!()

    dir =
      Path.join(
        System.tmp_dir!(),
        "ash_pplan_tlc_#{System.unique_integer([:positive])}_#{:os.getpid()}"
      )

    File.mkdir_p!(dir)

    try do
      File.write!(Path.join(dir, name <> ".tla"), module)
      File.write!(Path.join(dir, name <> ".cfg"), cfg)

      {output, status} =
        System.cmd(
          "java",
          [
            "-XX:+UseSerialGC",
            "-Xmx256m",
            "-cp",
            jar_path(),
            "tlc2.TLC",
            "-workers",
            "1",
            "-nowarning",
            "-metadir",
            Path.join(dir, "states"),
            "-config",
            name <> ".cfg",
            name <> ".tla"
          ],
          cd: dir,
          stderr_to_stdout: true
        )

      classify!(output, status)
    after
      File.rm_rf!(dir)
    end
  end

  # Exit codes are TLC 1.7.4's (witnessed in autofde-lab
  # tests/iec/fixtures/tlc/v1.7.4/MANIFEST.json): 0 success, 11 deadlock,
  # 13 liveness violation. A verdict needs both the exit code and TLC's own
  # message on a line of its own; a message echoed elsewhere (a state term in a
  # trace, a parse error quoting source) or a code without its message raises.
  @doc false
  def classify!(output, status) when is_binary(output) and is_integer(status) do
    cond do
      status == 0 and line?(output, "Model checking completed. No error has been found.") ->
        %{verdict: :admitted, kind: :no_error, exit_status: status, output: output}

      status == 11 and line?(output, "Deadlock reached.") ->
        %{verdict: :refused, kind: :deadlock, exit_status: status, output: output}

      status == 13 and line?(output, "Temporal properties were violated.") ->
        %{verdict: :refused, kind: :liveness, exit_status: status, output: output}

      true ->
        raise "TLC produced no classifiable verdict (exit #{status}):\n" <> output
    end
  end

  defp line?(output, message) do
    output
    |> String.split(~r/\R/)
    |> Enum.any?(&(String.trim(&1) in [message, "Error: " <> message]))
  end
end
