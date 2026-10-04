defmodule AshPPlan.Workflow.Dsl.Transformers.GenerateModel do
  @moduledoc "Generates `__ash_pplan_workflow__/0` returning the normalized `Model`."
  use Spark.Dsl.Transformer

  alias AshPPlan.Workflow.Dsl.Info
  alias Spark.Dsl.Transformer

  @verifiers [
    AshPPlan.Workflow.Dsl.Verifiers.UniqueIds,
    AshPPlan.Workflow.Dsl.Verifiers.CapabilitiesParse,
    AshPPlan.Workflow.Dsl.Verifiers.AcyclicDependencies,
    AshPPlan.Workflow.Dsl.Verifiers.OutcomeClosure
  ]

  @impl true
  def transform(dsl_state) do
    # This transformer is the SINGLE enforcement point for the four workflow
    # verifiers: Spark downgrades after_verify errors to warnings, so running
    # them here makes a violated property fail compilation. The extensions
    # (AshPPlan.Workflow.Dsl, AshPPlan.Dsl.PPlan) must not also list them in
    # `verifiers:` — that would only duplicate-scan already-accepted state.
    case Enum.find_value(@verifiers, &failure(&1, dsl_state)) do
      nil -> generate(dsl_state)
      error -> {:error, error}
    end
  end

  defp failure(verifier, dsl_state) do
    case verifier.verify(dsl_state) do
      {:error, error} -> error
      _ -> nil
    end
  end

  defp generate(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    escaped = dsl_state |> Info.build(module) |> Macro.escape()

    {:ok,
     Transformer.eval(
       dsl_state,
       [escaped: escaped],
       quote do
         @doc "The normalized workflow model declared by this module's DSL."
         def __ash_pplan_workflow__ do
           unquote(escaped)
         end
       end
     )}
  end
end
