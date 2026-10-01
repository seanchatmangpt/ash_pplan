defmodule AshPPlan.Reactor.Durable.Key do
  @moduledoc """
  Step identity for the checkpoint ledger.

  A step is identified by the deterministic encoding of its Reactor name, so a reordered step
  replays and a renamed step re-runs. Design derived from mbuhot/magma (MIT per its mix.exs),
  re-implemented; `minor_version: 2` is pinned so float encoding cannot re-key across OTP releases.
  """

  @spec for_name(term()) :: binary()
  def for_name(name),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(name, [:deterministic, minor_version: 2]))

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
      :crypto.hash(:sha256, [parent_id, 0, for_name(step_name)])

    <<h1::32, h2::16, h3::16, h4::16, h5::48>> = <<a::48, 7::4, b::12, 2::2, c::62>>

    [h1, h2, h3, h4, h5]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {n, w} ->
      n |> Integer.to_string(16) |> String.pad_leading(w, "0")
    end)
    |> String.downcase()
  end
end
