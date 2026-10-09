defmodule Mix.Tasks.AshPplan.DslDocs do
  @shortdoc "Regenerate DSL cheat-sheet docs (un-backticked spec cells)"

  @moduledoc """
  Regenerates documentation/dsls/DSL-*.md from the Spark DSL surface with
  audit-safe cell emission (backlog [98]).

  Upstream `mix spark.cheat_sheets` backticks every Name and Type cell.
  Identifier-shaped backticked cells naming nothing on the code surface are
  table_row_scaffold audit phantoms (the [83] phantom class). This task
  renders via Spark.CheatSheet.cheat_sheet/1, then emits spec/vocabulary
  cells un-backticked, reserving backticks for code symbols verified against
  the code surface (loaded modules / exported functions):

  - Name cells: backticked link text emits plain (DSL vocabulary, not a
    code-symbol claim).
  - Type cells: fully-backticked Type cells emit un-backticked (spec
    notation, never a code-symbol claim).
  - Default cells: fully-backticked term literals (`:construct`, `[]`, `1`)
    emit un-backticked (literals, not identifier claims).
  - Docs cells: backticked identifier-shaped spans are kept only when they
    verify against the code surface (a loaded module, or an exported
    function with or without /arity); anything else emits un-backticked.

  Idempotent: re-running over its own output is a fixed point.

      mix ash_pplan.dsl_docs          # regenerate documentation/dsls/DSL-*.md
      mix ash_pplan.dsl_docs --check  # exit 1 on drift, writes nothing
  """

  use Mix.Task

  @extensions [AshPPlan.Workflow.Dsl, AshPPlan.Dsl.PPlan]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")
    check = "--check" in args

    for ext <- @extensions do
      content = render(ext)
      path = "documentation/dsls/DSL-#{extension_name(ext)}.md"

      if check do
        if File.read!(path) == content do
          Mix.shell().info("ok #{path}")
        else
          Mix.raise("#{path} is stale; run `mix ash_pplan.dsl_docs`")
        end
      else
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
        Mix.shell().info("generated #{path}")
      end
    end

    :ok
  end

  @doc """
  Render one extension's DSL doc with audit-safe cells.
  """
  def render(extension) do
    extension
    |> Spark.CheatSheet.cheat_sheet()
    |> unbacktick_option_cells()
  end

  @doc false
  def unbacktick_option_cells(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.map(&unbacktick_row/1)
    |> Enum.join("\n")
  end

  defp extension_name(extension) do
    extension
    |> inspect()
    |> String.trim_trailing(".Dsl")
  end

  # One option-table row: de-backtick the Name cell (link text), every
  # fully-backticked cell after it (Type/Default/Docs), and in the last
  # (Docs) cell also backticked identifier-shaped spans that do not verify
  # against the code surface.
  defp unbacktick_row(line) do
    if String.starts_with?(line, "| ") and String.contains?(line, " | ") do
      [name_cell | rest] = String.split(line, " | ")
      name_cell = de_backtick_name_cell(name_cell)
      cells = Enum.map(rest, &de_backtick_wrapped_cell/1)
      docs_cell = de_backtick_doc_cell(List.last(cells))
      cells = List.replace_at(cells, length(cells) - 1, docs_cell)
      Enum.join([name_cell | cells], " | ")
    else
      line
    end
  end

  # "| [`id`](#workflow-task-id){: ...}" -> "| [id](#workflow-task-id){: ...}"
  defp de_backtick_name_cell(cell) do
    Regex.replace(~r{^\| \[`([^`]+)`\]}, cell, "| [\\1]")
  end

  # "| `atom`" -> "| atom"  (a cell that is exactly one backticked span)
  defp de_backtick_wrapped_cell(cell) do
    if String.starts_with?(cell, "`") and String.ends_with?(cell, "`") and
         not String.contains?(String.slice(cell, 1..-2//1), "`") do
      String.slice(cell, 1..-2//1)
    else
      cell
    end
  end

  # "`Family.Name`." -> "Family.Name." unless the span verifies as a code
  # symbol (loaded module or exported function, /arity optional).
  defp de_backtick_doc_cell(cell) do
    Regex.replace(~r{`([^`\n]+)`}, cell, fn _, span ->
      if code_symbol?(span), do: "`#{span}`", else: span
    end)
  end

  # Code-surface verification: loaded module (full path or any dotted
  # suffix chain), optionally an exported function with or without /arity.
  defp code_symbol?(span) do
    case parse_symbol(span) do
      {mod_parts, nil} -> module_loaded?(mod_parts)
      {mod_parts, fun} -> module_loaded?(mod_parts) and fun_exported?(mod_parts, fun)
    end
  end

  defp parse_symbol(span) do
    {body, _arity} =
      case String.split(span, "/") do
        [body, arity] ->
          case Integer.parse(arity) do
            {n, ""} -> {body, n}
            _ -> {span, nil}
          end

        _ ->
          {span, nil}
      end

    parts = String.split(body, ".")

    if fun_name?(List.last(parts)) and length(parts) > 1 do
      {Enum.drop(parts, -1), List.last(parts)}
    else
      {parts, nil}
    end
  end

  defp fun_name?(segment) do
    match?("_" <> _, segment) or
      (match?(<<c, _::binary>> when c in ?a..?z, segment) and
         String.match?(segment, ~r{^[a-z][A-Za-z0-9_]*[!?]?$}))
  end

  defp module_loaded?(parts) do
    try do
      mod = Module.safe_concat(parts)
      Code.ensure_loaded?(mod)
    rescue
      _ -> false
    end
  end

  defp fun_exported?(mod_parts, fun) do
    try do
      mod = Module.safe_concat(mod_parts)
      f = String.to_atom(fun)
      info = mod.module_info(:functions)

      Enum.any?(info, fn {name, _arity} -> name == f end)
    rescue
      _ -> false
    end
  end
end
