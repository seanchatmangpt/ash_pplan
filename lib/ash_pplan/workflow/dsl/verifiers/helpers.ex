defmodule AshPPlan.Workflow.Dsl.Verifiers.Helpers do
  @moduledoc false
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  def module(dsl_state), do: Transformer.get_persisted(dsl_state, :module)

  def error(dsl_state, path, message) do
    {:error, DslError.exception(module: module(dsl_state), path: path, message: message)}
  end
end
