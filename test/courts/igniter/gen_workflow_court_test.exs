defmodule AshPPlan.Courts.Igniter.GenWorkflowCourtTest do
  @moduledoc """
  Chicago court for the GENERATED `mix ash_pplan.gen.workflow` Igniter task.

  No mocks: the task runs through the real `Igniter.compose_task/4` path in a
  real Igniter test project; results are written to a real tmp directory and
  re-parsed FROM DISK; the scaffolded Model literal is executed for real
  (`AshPPlan.Workflow.Model.new/1`).
  """
  use ExUnit.Case, async: false

  @task "ash_pplan.gen.workflow"

  defp run_task(args) do
    Igniter.Test.test_project(app_name: "my_app")
    |> Igniter.compose_task(@task, args)
    |> Igniter.Test.apply_igniter!()
  end

  defp dump_and_reread(igniter) do
    files =
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.map(fn s -> {to_string(s.path), Rewrite.Source.get(s, :content)} end)
      |> Map.new()

    tmp =
      Path.join(System.tmp_dir!(), "ash_pplan_court_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    for {path, content} <- files do
      full = Path.join(tmp, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    {tmp, files}
  end

  defp on_disk_read(tmp, path), do: File.read!(Path.join(tmp, path))

  # Evaluate the generated def bodies for real WITHOUT defining a module
  # (defining MyApp.Workflows.* at runtime races the module registry).
  defp eval_def_bodies!(content, funs) do
    ast = Code.string_to_quoted!(content)

    for fun <- funs, into: %{} do
      {:def, _, [{^fun, _, nil}, [do: body]]} =
        Macro.prewalk(ast, nil, fn
          {:def, _, [{^fun, _, nil}, [do: _]]} = node, _ -> {node, node}
          node, acc -> {node, acc}
        end)
        |> elem(1)

      code = "alias AshPPlan.Workflow.Model\n" <> Macro.to_string(body)
      {result, _} = Code.eval_string(code)
      {fun, result}
    end
  end

  # Extract the VALUE of a module attribute literal (`@name value`) from the
  # parsed module source.
  defp literal_of!(content, name) do
    ast = Code.string_to_quoted!(content)

    Macro.prewalk(ast, nil, fn
      {:@, _, [{^name, _, [value]}]} = node, _ -> {node, value}
      node, acc -> {node, acc}
    end)
    |> elem(1)
    |> case do
      nil -> flunk("no @#{name} literal in:\n" <> content)
      value -> strip_block(value)
    end
  end

  defp strip_block({:__block__, _, [only]}), do: strip_block(only)
  defp strip_block(other), do: other

  describe "scaffold mode" do
    test "creates a real workflow module whose Model literal validates" do
      igniter =
        run_task(["etl", "--goal", "Ingest then publish", "--providers", "file,network"])

      {tmp, _files} = dump_and_reread(igniter)

      # Real file on real disk, re-parsed from the bytes on disk.
      content = on_disk_read(tmp, "lib/my_app/workflows/etl.ex")
      assert {:defmodule, _, _} = Code.string_to_quoted!(content)

      # Real execution: the scaffolded Model literal must actually validate.
      results = eval_def_bodies!(content, [:model])

      assert {:ok, %AshPPlan.Workflow.Model{} = model} = results[:model]
      assert model.name == "etl"
      assert model.goal == "Ingest then publish"
      assert :ok = AshPPlan.Workflow.Model.validate(model)

      # Attribute literals asserted from the parsed AST (the @-forms cannot be
      # evaluated outside a module context).
      providers = literal_of!(content, :providers)
      assert providers == [:file, :network]

      selection_ast = literal_of!(content, :selection)
      assert match?({:%{}, _, [{"start", [:file, :network]}]}, selection_ast)
    end
  end

  describe "--add-provider AST modify" do
    test "rewrites @providers and @selection via AST, not string append" do
      scaffolded =
        Igniter.Test.test_project(app_name: "my_app")
        |> Igniter.compose_task(@task, ["replicate", "--providers", "file,network"])
        |> Igniter.Test.apply_igniter!()

      content_first =
        scaffolded.rewrite
        |> Rewrite.sources()
        |> Enum.find(&(&1.path == "lib/my_app/workflows/replicate.ex"))
        |> then(&Rewrite.Source.get(&1, :content))

      igniter =
        Igniter.Test.test_project(
          app_name: "my_app",
          files: %{"lib/my_app/workflows/replicate.ex" => content_first}
        )
        |> Igniter.compose_task(@task, ["replicate", "--add-provider", "durability"])

      {tmp, _} = dump_and_reread(igniter)
      # re-read the MODIFIED bytes from disk
      content = on_disk_read(tmp, "lib/my_app/workflows/replicate.ex")

      ast = Code.string_to_quoted!(content)

      providers =
        Macro.prewalk(ast, nil, fn
          {:@, _, [{:providers, _, [list]}]} = node, _ -> {node, list}
          node, acc -> {node, acc}
        end)
        |> elem(1)

      selection =
        Macro.prewalk(ast, nil, fn
          {:@, _, [{:selection, _, [map_node]}]} = node, _ -> {node, map_node}
          node, acc -> {node, acc}
        end)
        |> elem(1)

      {:%{}, _, pairs} = selection
      selection_values = Enum.map(pairs, fn {k, v} -> {k, v} end)

      assert providers == [:durability, :file, :network]

      assert selection_values == [{"start", [:file, :network, :durability]}]

      # and the modified file still evaluates for real
      results = eval_def_bodies!(content, [:model])
      assert {:ok, %AshPPlan.Workflow.Model{}} = results[:model]
    end
  end

  describe "compose_task proof" do
    test "--with_resource composes ash.gen.resource for real" do
      # Compose WITHOUT apply_igniter!: the composed task's real output lives in
      # the project rewrite; dump_and_reread writes it to disk for re-parse.
      igniter =
        Igniter.Test.test_project(app_name: "my_app")
        |> Igniter.compose_task(@task, ["etl", "--with-resource", "Things.Thing"])

      {tmp, _} = dump_and_reread(igniter)

      # The composed task really created its file in the project.
      resource_source = on_disk_read(tmp, "lib/things/thing.ex")
      assert {:defmodule, _, _} = Code.string_to_quoted!(resource_source)
      assert resource_source =~ "use Ash.Resource"

      # the composed domain landed too (compose_task really ran its own igniter)
      assert on_disk_read(tmp, "lib/things.ex") =~ "defmodule Things"

      # The scaffolded workflow is also there, and both files coexist.
      workflow_source = on_disk_read(tmp, "lib/my_app/workflows/etl.ex")
      assert workflow_source =~ "defmodule MyApp.Workflows.Etl"
    end
  end
end
