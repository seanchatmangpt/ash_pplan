defmodule GgenGateHygieneTest do
  @moduledoc """
  Chicago court over the repo's own ggen gate queries (`priv/ggen/*/gates/*.rq`),
  so the burn-in pack is judged by the same law as the existing packs.

  Rules:
    (a) every query has a complete PREFIX block: every namespace prefix used in
        the body is declared on a PREFIX line;
    (b) any ORDER BY is deterministic: every ORDER BY term is a projected
        (SELECT) variable, and the query projects the full tuple (DISTINCT) so
        the ORDER BY key is the whole unique projected row;
    (c) no positional SPARQL filter args: string-comparison filter functions
        (STRSTARTS/STRENDS/STRBEF/CONTAINS/REGEX-style traps) must take a
        variable in the subject position, never a bare string literal;
    (d) where a pack ships a verify/ dir, every gates/*.rq has a sibling
        verify/<name>.unbound.rq companion (verify-only files are allowed).
  """

  use ExUnit.Case, async: true

  @repo File.cwd!()
  @ggen_root Path.join(@repo, "priv/ggen")

  packs =
    @ggen_root
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(@ggen_root, &1)))

  for pack <- packs do
    gates_dir = Path.join(@ggen_root, pack <> "/gates")
    verify_dir = Path.join(@ggen_root, pack <> "/verify")

    gate_files =
      if File.dir?(gates_dir), do: Path.wildcard(Path.join(gates_dir, "*.rq")), else: []

    unless gate_files == [] do
      # ---- Rule (a): complete PREFIX block -----------------------------------
      describe "#{pack} PREFIX hygiene" do
        for path <- gate_files do
          @path path
          @name Path.basename(path)

          test "#{@name} declares every namespace prefix it uses" do
            body = File.read!(@path)
            declared = prefixes(body)

            used =
              Regex.scan(~r/(?:^|[\s({,<])(([A-Za-z_][\w-]*)):[A-Za-z_][\w-]*/m, body)
              |> Enum.map(fn [_, _, p] -> p end)
              |> MapSet.new()

            undeclared =
              used
              |> MapSet.difference(declared)
              |> MapSet.delete("http")
              |> MapSet.delete("https")
              |> Enum.sort()

            assert undeclared == [],
                   "#{@name}: prefixes used but not declared: #{inspect(undeclared)}"
          end

          # ---- Rule (b): deterministic ORDER BY --------------------------------
          test "#{@name} ORDER BY is deterministic (projected + DISTINCT)" do
            body = File.read!(@path)

            case order_by_vars(body) do
              [] ->
                :ok

              terms ->
                projected = select_vars(body)

                Enum.each(terms, fn v ->
                  assert v in projected,
                         "#{@name}: ORDER BY #{v} is not a projected variable " <>
                           "(nondeterministic key): #{inspect(projected)}"
                end)

                assert Regex.match?(~r/SELECT\s+DISTINCT/i, body) or
                         Enum.any?(projected, &(&1 in ["?s", "?subject", "?row", "?key", "?id"])),
                       "#{@name}: ORDER BY over #{inspect(terms)} lacks DISTINCT and a " <>
                         "unique key var (s/subject/row/key/id) in projection"
            end
          end

          # ---- Rule (c): no positional filter args ----------------------------
          test "#{@name} has no positional (non-variable) filter subject args" do
            body = File.read!(@path)

            bad =
              Regex.scan(
                ~r/(?:STRSTARTS|STRENDS|STRBEF|STRAFTER|CONTAINS|REGEX)\s*\(\s*("[^"]*"|'[^']*')/i,
                body
              )
              |> Enum.map(&hd/1)

            assert bad == [],
                   "#{@name}: positional string-literal first arg in filter fn: #{inspect(bad)} " <>
                     "(repo trap: string fns must take a variable, not a literal, in subject position)"
          end
        end
      end

      # ---- Rule (d): verify companions ---------------------------------------
      if File.dir?(verify_dir) do
        describe "#{pack} verify companions" do
          @verify_dir verify_dir
          @gates_dir gates_dir
          test "every gate has a sibling verify/<name>.unbound.rq" do
            shipped =
              MapSet.new(Path.wildcard(Path.join(@verify_dir, "*.rq")))

            missing =
              Path.wildcard(Path.join(@gates_dir, "*.rq"))
              |> Enum.map(fn p ->
                Path.join(@verify_dir, Path.basename(p, ".rq") <> ".unbound.rq")
              end)
              |> Enum.reject(&MapSet.member?(shipped, &1))
              |> Enum.map(&Path.basename/1)
              |> Enum.sort()

            assert missing == [],
                   "gates without verify/*.unbound.rq companions: #{inspect(missing)}"
          end
        end
      end
    end
  end

  test "court is non-vacuous: at least one gate file exists" do
    gates = Path.wildcard(Path.join(@ggen_root, "*/gates/*.rq"))
    assert length(gates) > 0, "no gate files found under priv/ggen/*/gates"
    IO.puts("ggen gate hygiene court: #{length(gates)} gate files under judgment")
  end

  # -- helpers ---------------------------------------------------------------

  defp prefixes(body) do
    Regex.scan(~r/PREFIX\s+([A-Za-z_][\w-]*):/i, body)
    |> Enum.map(fn [_, p] -> p end)
    |> MapSet.new()
  end

  defp order_by_vars(body) do
    case Regex.run(~r/ORDER\s+BY\s+(.+)$/im, body) do
      [_, terms] ->
        Regex.scan(~r/\?([A-Za-z_]\w*)/, terms)
        |> Enum.map(fn [_, v] -> "?#{v}" end)

      nil ->
        []
    end
  end

  defp select_vars(body) do
    case Regex.run(~r/SELECT\s+(?:DISTINCT\s+)?(.+?)\s*WHERE/is, body) do
      [_, sel] ->
        Regex.scan(~r/\?([A-Za-z_]\w*)/, sel)
        |> Enum.map(fn [_, v] -> "?#{v}" end)

      nil ->
        []
    end
  end
end
