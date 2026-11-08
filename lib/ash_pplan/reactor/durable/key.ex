defmodule AshPPlan.Reactor.Durable.Key do
  @moduledoc """
  Step identity for the checkpoint ledger.

  A step is identified by the deterministic encoding of its Reactor name, so a reordered step
  replays and a renamed step re-runs. Design derived from mbuhot/magma (MIT per its mix.exs),
  re-implemented; `minor_version: 2` is pinned so float encoding cannot re-key across OTP releases.
  """

  @spec for_name(term()) :: binary()
  def for_name(name),
    do: AshPPlan.Digest.hash(:erlang.term_to_binary(name, [:deterministic, minor_version: 2]))

  @doc """
  Deterministic intent token for one (run, step): the stable external idempotency
  key a step may derive from `context.durable_intent_token`. Reuses the Digest seam
  with a separator byte so `("run1", "ab")` and `("run2", "a")`-style splits stay
  distinct (same law as `child_id/2`). The token is identical on every attempt of
  the same step in the same run — including the replay after a kill between the
  effect and the record — because it is a pure function of `(run_id, step name)`,
  and the standing `$intent` checkpoint row adopts exactly this value.
  """
  @spec intent_id(String.t(), term()) :: String.t()
  def intent_id(run_id, step_name) when is_binary(run_id) do
    AshPPlan.Digest.hex(AshPPlan.Digest.hash([run_id, 0, for_name(step_name)]))
  end

  @doc "Label prefix marking an intent checkpoint row (never a step output; filtered from replay)."
  @spec intent_label_prefix() :: String.t()
  def intent_label_prefix, do: "$intent"

  @doc "True when a checkpoint row is an intent row (keyed on the LABEL, not the key shape)."
  @spec intent_row?(%{label: term()}) :: boolean()
  def intent_row?(%{label: label}) when is_binary(label),
    do: String.starts_with?(label, intent_label_prefix())

  def intent_row?(_), do: false

  @doc "Human-readable label for a step name (never used for identity)."
  @spec label(term()) :: String.t()
  def label(name) when is_atom(name), do: inspect(name)
  def label(name), do: inspect(name, limit: :infinity, printable_limit: 4000)

  @doc """
  Deterministic UUIDv7-shaped child run id derived from the parent id and the dispatching step key.
  A separator keeps `("ab", "c")` and `("a", "bc")` distinct.
  """
  @spec child_id(String.t(), term()) :: String.t()
  def child_id(parent_id, step_name) when is_binary(parent_id) do
    <<a::48, _v::4, b::12, _var::2, c::62, _::binary>> =
      AshPPlan.Digest.hash([parent_id, 0, for_name(step_name)])

    <<h1::32, h2::16, h3::16, h4::16, h5::48>> = <<a::48, 7::4, b::12, 2::2, c::62>>

    [h1, h2, h3, h4, h5]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {n, w} ->
      n |> Integer.to_string(16) |> String.pad_leading(w, "0")
    end)
    |> String.downcase()
  end
end
