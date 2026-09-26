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

  @doc "Returns `:ok` or `{:unavailable, reason}` for skip tagging."
  def availability do
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
  def verify_jar! do
    digest = :crypto.hash(:sha256, File.read!(jar_path())) |> Base.encode16(case: :lower)

    if digest != @jar_sha256 do
      raise "tla2tools digest mismatch at #{jar_path()}: #{digest} != #{@jar_sha256}"
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

  defp classify!(output, status) do
    cond do
      status == 0 and output =~ "Model checking completed. No error has been found." ->
        %{verdict: :admitted, kind: :no_error, exit_status: status, output: output}

      status != 0 and output =~ "Deadlock reached" ->
        %{verdict: :refused, kind: :deadlock, exit_status: status, output: output}

      status != 0 and output =~ "Temporal properties were violated" ->
        %{verdict: :refused, kind: :liveness, exit_status: status, output: output}

      true ->
        raise "TLC produced no classifiable verdict (exit #{status}):\n" <> output
    end
  end
end
