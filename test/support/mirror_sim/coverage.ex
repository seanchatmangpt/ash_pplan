defmodule AshPPlan.MirrorSim.Coverage do
  @moduledoc """
  Coverage compiler for the mirror-sim. Derives the public surface inventory of `lib/ash_pplan`
  mechanically (exported functions of every `AshPPlan.*` module in the application, minus
  `@doc false`/hidden and compiler-generated functions), unions every mirror area's
  `surfaces/0`, and classifies each inventory cell as:

    * `:pass` - some mirror area declares the surface
    * `:divergence` - a valid `KD-nn` row in `docs/MIRROR-SIM-KNOWN-DIVERGENCES.md` covers it
    * `:missing` - neither (loud; the gate exits 1)

  A KD row only registers if surface, divergence, evidence and close condition are all
  non-empty. Mirror surfaces naming a nonexistent `AshPPlan.*` function are `phantom`
  and also fail the gate.

  Mounted at `/coverage/*`: `GET /report`, `/inventory`, `/divergences`, `/missing`.
  """
  use Plug.Router
  alias AshPPlan.MirrorSim.Json

  plug(:match)
  plug(:dispatch)

  @type key :: {module(), atom(), non_neg_integer()}
  @type kd :: %{
          id: String.t(),
          surface: String.t(),
          divergence: String.t(),
          evidence: String.t(),
          close: String.t()
        }

  @register_path "docs/MIRROR-SIM-KNOWN-DIVERGENCES.md"
  @generated ~w(__info__ module_info behaviour_info __struct__ __changeset__ __spark_metadata__
                exception __exception__)a

  ## ---- pure compiler ----

  @doc "Default KD register path (relative to project root)."
  @spec register_path() :: String.t()
  def register_path, do: @register_path

  @doc """
  Parse KD rows from markdown text. Returns `{valid, invalid}`; a row is invalid when any
  of its four cells is blank.

      iex> text = "| KD-01 | `A.b/1` | differs | receipt x | when fixed |"
      iex> {[row], []} = AshPPlan.MirrorSim.Coverage.parse_register(text)
      iex> row.surface
      "A.b/1"
  """
  @spec parse_register(String.t()) :: {[kd()], [kd()]}
  def parse_register(text) when is_binary(text) do
    rows =
      text
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(String.trim(&1), "| KD-"))
      |> Enum.map(&parse_row/1)

    Enum.split_with(rows, fn r ->
      Enum.all?([r.surface, r.divergence, r.evidence, r.close], &(&1 != ""))
    end)
  end

  defp parse_row(line) do
    cells =
      line
      |> String.trim()
      |> String.trim("|")
      |> String.split("|")
      |> Enum.map(&String.trim/1)

    [id, surface, divergence, evidence, close] = Enum.take(cells ++ List.duplicate("", 5), 5)

    %{
      id: id,
      surface: String.replace(surface, "`", ""),
      divergence: divergence,
      evidence: evidence,
      close: close
    }
  end

  @doc """
  Expand a KD surface cell into matchers: `{:exact, key}` or `{:module, mod}`.
  Comma-separated; forms `Mod.fun/arity` and `Mod.*`.
  """
  @spec matchers(String.t()) :: [{:exact, key()} | {:module, module()}]
  def matchers(cell) do
    cell
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn s ->
      cond do
        m = Regex.run(~r/^(.+)\.\*$/, s) ->
          [{:module, Module.concat([Enum.at(m, 1)])}]

        m = Regex.run(~r/^(.+)\.([^.\/]+)\/(\d+)$/, s) ->
          [_, mod, fun, ar] = m
          [{:exact, {Module.concat([mod]), String.to_atom(fun), String.to_integer(ar)}}]

        true ->
          []
      end
    end)
  end

  @doc """
  Classify inventory keys against mirror surface keys and valid KD rows.

  Returns `%{cells: [%{key:, status:, kd:}], phantoms: [key]}` where `kd` is the covering
  row id for `:divergence` cells.

      iex> inv = [{A, :f, 1}, {A, :g, 0}, {B, :h, 2}]
      iex> kds = [%{id: "KD-01", surface: "B.*", divergence: "d", evidence: "e", close: "c"}]
      iex> r = AshPPlan.MirrorSim.Coverage.classify(inv, [{A, :f, 1}], kds)
      iex> Enum.map(r.cells, & &1.status)
      [:pass, :missing, :divergence]
  """
  @spec classify([key()], [key()], [kd()]) :: %{cells: [map()], phantoms: [key()]}
  def classify(inventory, mirror_keys, kds) do
    # a mirror name/N covers inventory name/M for M <= N (default-arg arities)
    max_arity =
      Enum.reduce(mirror_keys, %{}, fn {m, f, a}, acc ->
        Map.update(acc, {m, f}, a, &max(&1, a))
      end)

    expanded = Enum.map(kds, fn kd -> {kd.id, matchers(kd.surface)} end)

    cells =
      Enum.map(inventory, fn {mod, f, a} = key ->
        cond do
          a <= Map.get(max_arity, {mod, f}, -1) ->
            %{key: key, status: :pass, kd: nil}

          kd = covering(expanded, key, mod) ->
            %{key: key, status: :divergence, kd: kd}

          true ->
            %{key: key, status: :missing, kd: nil}
        end
      end)

    phantoms =
      mirror_keys
      |> Enum.filter(fn {mod, _, _} -> ashpplan_module?(mod) end)
      |> Enum.reject(fn {m, f, a} -> Code.ensure_loaded?(m) and function_exported?(m, f, a) end)
      |> Enum.uniq()
      |> Enum.sort()

    %{cells: cells, phantoms: phantoms}
  end

  defp covering(expanded, key, mod) do
    Enum.find_value(expanded, fn {id, ms} ->
      if Enum.any?(ms, &(&1 == {:exact, key} or &1 == {:module, mod})), do: id
    end)
  end

  defp ashpplan_module?(mod) do
    s = Atom.to_string(mod)

    String.starts_with?(s, "Elixir.AshPPlan.") and
      not String.starts_with?(s, "Elixir.AshPPlan.MirrorSim")
  end

  ## ---- inventory derivation ----

  @doc "Public `{module, fun, arity}` inventory of `lib/ash_pplan`, sorted."
  @spec inventory() :: [key()]
  def inventory do
    {:ok, mods} = :application.get_key(:ash_pplan, :modules) |> ok_modules()

    mods
    |> Enum.filter(&inventory_module?/1)
    |> Enum.flat_map(&module_keys/1)
    |> Enum.sort()
  end

  defp ok_modules({:ok, mods}), do: {:ok, mods}
  defp ok_modules(_), do: {:ok, []}

  defp inventory_module?(mod) do
    s = Atom.to_string(mod)

    String.starts_with?(s, "Elixir.AshPPlan.") and
      not String.starts_with?(s, "Elixir.AshPPlan.MirrorSim") and
      not String.contains?(s, ".ProcessWorker") and
      Code.ensure_loaded?(mod) and under_lib?(mod)
  end

  # compile source must live under the repo lib/ dir
  defp under_lib?(mod) do
    case mod.module_info(:compile)[:source] do
      nil ->
        false

      src ->
        String.starts_with?(Path.expand(to_string(src)), Path.join(File.cwd!(), "lib") <> "/")
    end
  rescue
    _ -> false
  end

  defp generated_framework?(mod),
    do:
      function_exported?(mod, :__ash_resource__, 0) or
        function_exported?(mod, :__spark_dsl_config__, 0)

  defp module_keys(mod) do
    {mod_hidden, docs} = doc_info(mod)
    framework? = generated_framework?(mod)

    for {f, a} <- mod.__info__(:functions),
        not mod_hidden,
        f not in @generated,
        not String.starts_with?(Atom.to_string(f), "_"),
        doc_ok?(Map.get(docs, {f, a}), framework?),
        do: {mod, f, a}
  end

  # hidden docs are never inventory; on Ash/Spark modules only explicitly documented functions are
  defp doc_ok?(:hidden, _), do: false
  defp doc_ok?(doc, true), do: is_map(doc)
  defp doc_ok?(_, false), do: true

  defp doc_info(mod) do
    case Code.fetch_docs(mod) do
      {:docs_v1, _, _, _, mdoc, _, docs} ->
        {mdoc == :hidden,
         for({{:function, f, a}, _, _, d, _} <- docs, into: %{}, do: {{f, a}, d})}

      _ ->
        {false, %{}}
    end
  end

  @doc "Union of every mirror area's declared surfaces as `{module, fun, arity}`."
  @spec mirror_keys() :: [key()]
  def mirror_keys do
    AshPPlan.MirrorSim.Router.areas()
    |> Enum.reject(fn {name, _} -> name == "coverage" end)
    |> Enum.flat_map(fn {_name, mod} -> area_surfaces(mod) end)
    |> Enum.uniq()
  end

  defp area_surfaces(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :surfaces, 0) do
      for %{module: m, fun: f, arity: a} <- mod.surfaces(), do: {m, f, a}
    else
      []
    end
  rescue
    _ -> []
  end

  @doc "Load the KD register from `path`; a missing file is an empty register."
  @spec load_register(Path.t()) :: {[kd()], [kd()]}
  def load_register(path \\ @register_path) do
    case File.read(path) do
      {:ok, text} -> parse_register(text)
      {:error, _} -> {[], []}
    end
  end

  @doc "Full report over the live tree."
  @spec report(Path.t()) :: map()
  def report(path \\ @register_path) do
    inv = inventory()
    {valid, invalid} = load_register(path)
    %{cells: cells, phantoms: phantoms} = classify(inv, mirror_keys(), valid)

    by = Enum.group_by(cells, & &1.status)
    count = fn s -> length(Map.get(by, s, [])) end

    covered =
      cells |> Enum.map(& &1.kd) |> Enum.reject(&is_nil/1) |> MapSet.new()

    %{
      total: length(cells),
      pass: count.(:pass),
      divergence: count.(:divergence),
      missing: count.(:missing),
      missing_cells: by |> Map.get(:missing, []) |> Enum.map(&fmt(&1.key)),
      divergence_cells:
        by |> Map.get(:divergence, []) |> Enum.map(&%{surface: fmt(&1.key), kd: &1.kd}),
      phantoms: Enum.map(phantoms, &fmt/1),
      invalid_kd_rows: Enum.map(invalid, & &1.id),
      stale_kd_rows: valid |> Enum.map(& &1.id) |> Enum.reject(&MapSet.member?(covered, &1)),
      ok: count.(:missing) == 0 and phantoms == []
    }
  end

  @doc "Render `Mod.fun/arity`."
  @spec fmt(key()) :: String.t()
  def fmt({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"

  ## ---- routes ----

  get "/report" do
    Json.send_json(conn, 200, report())
  end

  get "/inventory" do
    Json.send_json(conn, 200, %{"inventory" => Enum.map(inventory(), &fmt/1)})
  end

  get "/divergences" do
    {valid, invalid} = load_register()
    Json.send_json(conn, 200, %{"valid" => valid, "invalid" => invalid})
  end

  get "/missing" do
    r = report()
    Json.send_json(conn, 200, %{"missing" => r.missing_cells, "phantoms" => r.phantoms})
  end

  match _ do
    Json.refuse(
      conn,
      "unknown_route",
      "no coverage route #{conn.method} #{conn.request_path}",
      404
    )
  end

  @doc "Surfaces this area itself exposes (none of lib/ash_pplan)."
  @spec surfaces() :: [map()]
  def surfaces, do: []
end
