defmodule AshPPlan.Test.TokyoDepeg.Affidavit do
  @moduledoc """
  Guarded seam to the real affidavit wasm host (`AshAffidavit.Host/Pool`,
  ops commit/verify). ash_affidavit is NOT a mix dep of ash_pplan, so the
  commit court is honest: when `AshAffidavit` is loadable the real wasm host
  is used; otherwise the court records `UNSUPPORTED(no-dep)` — never a fake
  commit.
  """

  # optional runtime-only dep; presence is probed with Code.ensure_loaded?/1
  @compile {:no_warn_undefined, AshAffidavit}

  @doc """
  Commit `payload_bytes` to the real affidavit host when available.

  Returns `{:ok, receipt}` on a real commit, or
  `{:unsupported, reason, message}` when ash_affidavit is not loadable.
  """
  @spec commit(binary(), keyword()) :: {:ok, term()} | {:unsupported, atom(), String.t()}
  def commit(payload, _opts \\ []) do
    if Code.ensure_loaded?(AshAffidavit) do
      cond do
        function_exported?(AshAffidavit, :commit, 1) ->
          AshAffidavit.commit(payload)

        function_exported?(AshAffidavit, :commit, 2) ->
          AshAffidavit.commit(payload, [])

        true ->
          {:unsupported, :no_commit_op, "AshAffidavit loaded but exports no commit/1,2 op"}
      end
    else
      {:unsupported, :no_dep,
       "ash_affidavit is not a mix dep of ash_pplan; BLAKE3 identity stays a " <>
         "documented :blake2b stand-in"}
    end
  end
end
