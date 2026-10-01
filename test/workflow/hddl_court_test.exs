defmodule AshPPlan.Workflow.HDDLCourtTest do
  @moduledoc """
  HDDL Court. Falsifies: a decomposition that drifts from the model. The
  render/parse round-trip must preserve methods and preconditions; the
  anti-vacuity mutations drop a subtask, a method and an ordering precondition,
  and the court must detect each.
  """
  use ExUnit.Case, async: true

  alias AshPPlan.Workflow.{Model, Subject}
  alias AshPPlan.Workflow.Project.HDDL

  defp model do
    {:ok, m} =
      Model.new(
        name: :hd_wf,
        tasks: [
          [id: :observe, capability: "Work.Select"],
          [id: :plan, capability: "Work.Select", depends_on: [:observe]],
          [id: :build, capability: "Work.Select", depends_on: [:plan]]
        ],
        methods: [[id: :deliver, task: :ship, subtasks: [:observe, :plan, :build]]]
      )

    m
  end

  test "render parses and round-trips the decomposition" do
    m = model()
    text = HDDL.render(m)
    assert {:ok, parsed} = HDDL.parse(text)
    assert parsed.domain == "wf-hd_wf"
    assert parsed.top_subtasks == ["t_observe", "t_plan", "t_build"]
    assert [%{id: "m-deliver", subtasks: ["t_observe", "t_plan", "t_build"]}] = parsed.methods
    assert parsed.actions["t_build"].pre == ["t_plan"]
    assert :ok = HDDL.court(m, text)
  end

  test "agrees with Subject.verify_projection" do
    m = model()
    assert :ok = Subject.verify_projection(m, :hddl, HDDL.render(m))
  end

  test "mutation: dropping a top-level subtask is detected" do
    m = model()
    text = String.replace(HDDL.render(m), ~r/\n\s+\(s3 \(t_build\)\)\)\)/, "))", global: false)
    refute text == HDDL.render(m)
    assert {:error, %{reason: :decomposition_diverges}} = HDDL.court(m, text)
  end

  test "mutation: dropping a method subtask is detected" do
    m = model()

    text =
      String.replace(
        HDDL.render(m),
        "      (s2 (t_plan))\n      (s3 (t_build))))\n\n  (:action",
        "      (s3 (t_build))))\n\n  (:action"
      )

    refute text == HDDL.render(m)
    assert {:error, %{reason: :method_diverges}} = HDDL.court(m, text)
  end

  test "mutation: dropping a precondition is detected" do
    m = model()

    text =
      String.replace(HDDL.render(m), ":precondition (and (d-t_plan))", ":precondition (and )")

    refute text == HDDL.render(m)
    assert {:error, %{reason: :precondition_diverges}} = HDDL.court(m, text)
  end

  test "garbage is a typed parse error" do
    assert {:error, %{reason: :hddl_parse_error}} = HDDL.parse("(define (domain")
  end
end
