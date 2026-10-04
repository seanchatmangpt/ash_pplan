# Golden-vector driver (elixir). Usage: elixir -r lib/es/chain.ex driver.exs <golden.vec>
defmodule Driver do
  def run(path) do
    path |> File.read!() |> String.split("\n") |> Enum.reduce([], &step/2)
  end

  defp step("", chain), do: chain
  defp step("#" <> _, chain), do: chain
  defp step("case " <> name, _chain) do
    IO.puts("case " <> name)
    []
  end
  defp step(line, chain) do
    case String.split(line, "|") do
      ["pending", id, su, ac] -> res(Es.Chain.append_pending(chain, id, su, ac), chain)
      ["outcome", id, st, su, ac] -> res(Es.Chain.append_outcome(chain, id, st, su, ac), chain)
      ["seal", id, st, su] -> res(Es.Chain.seal(chain, id, st, su), chain)
      ["forge", id, ph, st, su, ac, i] ->
        i = String.to_integer(i)
        ref = if i >= 0, do: Enum.at(chain, i).hash, else: ""
        parent = case List.last(chain) do nil -> Es.Chain.genesis(); p -> p.hash end
        e = %{entry_id: id, parent_hash: parent, phase: ph, standing: st, subject: su, action: ac, pending_ref: ref, seal: false}
        e = Map.put(e, :hash, Es.Chain.digest(Es.Chain.canonical(e)))
        IO.puts("ok " <> e.hash)
        chain ++ [e]
      ["unpaired"] ->
        IO.puts("unpaired " <> Enum.join(Es.Chain.unpaired(chain), ","))
        chain
      ["verify"] ->
        IO.puts("verify " <> to_string(Es.Chain.verify(chain)))
        chain
      ["tamper"] ->
        IO.puts("tampered")
        [%{hd(chain) | subject: "tampered"} | tl(chain)]
    end
  end

  defp res({:ok, c}, _old) do
    IO.puts("ok " <> List.last(c).hash)
    c
  end
  defp res({:error, _}, old) do
    IO.puts("err")
    old
  end
end

Driver.run(hd(System.argv()))
