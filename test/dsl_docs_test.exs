defmodule AshPPlan.DslDocsTest do
  @moduledoc """
  Backlog [98]: DSL doc generator emits audit-safe cells. Real gate: the
  task's render over the live DSL surface, asserting on final state.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.AshPplan.DslDocs

  test "render/1 is a fixed point over its own output" do
    for ext <- [AshPPlan.Workflow.Dsl, AshPPlan.Dsl.PPlan] do
      doc = DslDocs.render(ext)
      assert DslDocs.unbacktick_option_cells(doc) == doc
    end
  end

  test "name and type cells emit un-backticked" do
    doc = DslDocs.render(AshPPlan.Workflow.Dsl)

    assert doc =~ "| [name](#workflow-name){: #workflow-name } |"
    refute doc =~ ~r/^\| \[`[^`]+`\]/
    refute doc =~ ~r/^\| \S+ \| `[^`]+` \|/m
  end

  test "default term literals emit un-backticked" do
    doc = DslDocs.render(AshPPlan.Workflow.Dsl)
    refute doc =~ ~s{| `:construct` |}
    refute doc =~ ~s{| `[]` |}
  end

  test "docs cell keeps code-verified symbols backticked" do
    doc = DslDocs.render(AshPPlan.Workflow.Dsl)

    assert doc =~ "`AshPPlan.Workflow.Task.depends_on`"
  end

  test "docs cell un-backticks spec vocabulary that names no code symbol" do
    doc = DslDocs.render(AshPPlan.Workflow.Dsl)

    refute doc =~ "`Family.Name`"
    assert doc =~ "Family.Name"
  end

  test "--check exits 0 when docs are current, raises on stale" do
    assert Mix.Task.run("ash_pplan.dsl_docs", ["--check"]) == :ok
  end
end
