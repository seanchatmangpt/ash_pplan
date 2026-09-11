defmodule AshPPlan.SemanticExecutionTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Compiler
  alias AshPPlan.Compiler.Error

  @plan "https://w3id.org/ash-pplan#SubscriptionRenewal"
  @authorize "https://w3id.org/ash-pplan#AuthorizePayment"
  @renew "https://w3id.org/ash-pplan#RenewSubscription"
  @subscription "https://w3id.org/ash-pplan#Subscription"
  @payment_authorization "https://w3id.org/ash-pplan#PaymentAuthorization"

  defmodule AuthorizePayment do
    use Reactor.Step

    @impl true
    def run(%{input: input}, context, _options) do
      send(input.test_pid, {:authorized, context.ash_pplan.step_iri, context.run_id})
      {:ok, :authorized}
    end
  end

  defmodule RenewSubscription do
    use Reactor.Step

    @impl true
    def run(arguments, context, _options) do
      predecessors = AshPPlan.predecessor_results(arguments, context)

      send(
        arguments.input.test_pid,
        {:renewed, Map.get(predecessors, "https://w3id.org/ash-pplan#AuthorizePayment"),
         context.ash_pplan.input_variables}
      )

      {:ok, :renewed}
    end
  end

  defmodule IdentifyStep do
    use Reactor.Step

    @impl true
    def run(_arguments, context, _options), do: {:ok, context.ash_pplan.step_iri}
  end

  test "a step observes both halves of its manufactured variable flow" do
    defmodule ReportVariables do
      use Reactor.Step

      @impl true
      def run(_arguments, context, _options) do
        {:ok, {context.ash_pplan.input_variables, context.ash_pplan.output_variables}}
      end
    end

    assert {{:ok, _}, _receipt} =
             AshPPlan.execute(
               @plan,
               %{@authorize => ReportVariables, @renew => ReportVariables},
               %{}
             )

    assert {:ok, reactor} =
             AshPPlan.compile_plan(@plan, %{
               @authorize => ReportVariables,
               @renew => ReportVariables
             })

    assert {:ok, {[@payment_authorization, @subscription], []}} =
             Reactor.run(reactor, %{input: %{}})
  end

  test "ggen_igniter manufactures P-PLAN topology and variable flow" do
    assert %{iri: @plan, label: "Subscription renewal", steps: [authorize, renew]} =
             AshPPlan.plan(@plan)

    assert authorize == %{
             iri: @authorize,
             label: "AuthorizePayment",
             predecessors: [],
             inputs: [@subscription],
             outputs: [@payment_authorization]
           }

    assert renew == %{
             iri: @renew,
             label: "RenewSubscription",
             predecessors: [@authorize],
             inputs: [@payment_authorization, @subscription],
             outputs: []
           }
  end

  test "compiles and executes P-PLAN precedence through Reactor with a receipt" do
    handlers = handlers()

    assert {{:ok, :renewed}, receipt} =
             AshPPlan.execute(@plan, handlers, %{test_pid: self()}, %{}, run_id: "run-1")

    assert_receive {:authorized, @authorize, "run-1"}
    assert_receive {:renewed, :authorized, [@payment_authorization, @subscription]}

    assert receipt.plan_iri == @plan
    assert receipt.run_id == "run-1"
    assert receipt.status == :succeeded
    assert receipt.duration_us >= 0
    assert String.match?(receipt.outcome_digest, ~r/^[0-9a-f]{64}$/)
  end

  test "preserves an existing context run identity when no option overrides it" do
    assert {{:ok, :renewed}, receipt} =
             AshPPlan.execute(
               @plan,
               handlers(),
               %{test_pid: self()},
               %{run_id: "context-run"}
             )

    assert_receive {:authorized, @authorize, "context-run"}
    assert receipt.run_id == "context-run"
  end

  test "explicit run identity overrides context consistently" do
    assert {{:ok, :renewed}, receipt} =
             AshPPlan.execute(
               @plan,
               handlers(),
               %{test_pid: self()},
               %{run_id: "old-run"},
               run_id: "new-run"
             )

    assert_receive {:authorized, @authorize, "new-run"}
    assert receipt.run_id == "new-run"
  end

  test "refuses missing handlers before Reactor execution" do
    assert {:error, %Error{reason: :missing_handlers, details: %{steps: [@renew]}}} =
             AshPPlan.compile_plan(@plan, %{@authorize => AuthorizePayment})
  end

  test "refuses non-IRI dependency fields before topology analysis" do
    malformed = %{
      iri: "urn:plan:malformed",
      steps: [
        %{
          iri: "urn:step:a",
          label: "a",
          predecessors: [:not_an_iri],
          inputs: [],
          outputs: []
        }
      ]
    }

    assert {:error, %Error{reason: :invalid_step_spec}} =
             Compiler.compile_spec(malformed, %{"urn:step:a" => IdentifyStep})
  end

  test "refuses dangling predecessors and cycles before graph construction" do
    dangling = %{
      iri: "urn:plan:dangling",
      steps: [step("urn:step:a", ["urn:step:missing"])]
    }

    assert {:error, %Error{reason: :dangling_predecessors}} =
             Compiler.compile_spec(dangling, %{"urn:step:a" => IdentifyStep})

    cyclic = %{
      iri: "urn:plan:cycle",
      steps: [step("urn:step:a", ["urn:step:b"]), step("urn:step:b", ["urn:step:a"])]
    }

    assert {:error, %Error{reason: :cyclic_plan}} =
             Compiler.compile_spec(cyclic, %{
               "urn:step:a" => IdentifyStep,
               "urn:step:b" => IdentifyStep
             })
  end

  test "collects multiple terminal results without inventing another executor" do
    plan = %{
      iri: "urn:plan:parallel",
      steps: [step("urn:step:a"), step("urn:step:b")]
    }

    assert {:ok, reactor} =
             Compiler.compile_spec(plan, %{
               "urn:step:a" => IdentifyStep,
               "urn:step:b" => IdentifyStep
             })

    assert {:ok, %{"urn:step:a" => "urn:step:a", "urn:step:b" => "urn:step:b"}} =
             Reactor.run(reactor, %{input: %{}})
  end

  defp handlers do
    %{@authorize => AuthorizePayment, @renew => RenewSubscription}
  end

  defp step(iri, predecessors \\ []) do
    %{iri: iri, label: iri, predecessors: predecessors, inputs: [], outputs: []}
  end
end
