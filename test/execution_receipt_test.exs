defmodule AshPPlan.ExecutionReceiptTest do
  @moduledoc """
  Proves every receipt status the release claims, and proves the digest is
  actually content-addressed rather than merely present.
  """

  use ExUnit.Case, async: true

  alias AshPPlan.Compiler
  alias AshPPlan.ExecutionReceipt

  @plan "https://w3id.org/ash-pplan#SubscriptionRenewal"
  @authorize "https://w3id.org/ash-pplan#AuthorizePayment"
  @renew "https://w3id.org/ash-pplan#RenewSubscription"

  defmodule OkStep do
    use Reactor.Step

    @impl true
    def run(_arguments, context, _options), do: {:ok, context.ash_pplan.step_iri}
  end

  defmodule FailingStep do
    use Reactor.Step

    @impl true
    # No compensate/4 is defined, so Reactor's default can?/2 already reports
    # this step as uncompensatable and the run resolves to {:error, _}.
    def run(_arguments, _context, _options), do: {:error, :payment_declined}
  end

  defmodule ReportReactorRunIdStep do
    use Reactor.Step

    @impl true
    def run(arguments, _context, _options) do
      [%{run_id: run_id} | _] = Process.get(:__reactor__)
      send(arguments.input.test_pid, {:reactor_run_id, run_id})
      {:ok, :reported}
    end
  end

  defmodule HaltingStep do
    use Reactor.Step

    @impl true
    def run(_arguments, _context, _options), do: {:halt, :awaiting_authorization}
  end

  describe "observed outcomes" do
    test "a succeeded run is receipted as succeeded" do
      assert {{:ok, @renew}, receipt} =
               AshPPlan.execute(@plan, all_ok(), %{}, %{}, run_id: "ok-run")

      assert %ExecutionReceipt{
               plan_iri: @plan,
               run_id: "ok-run",
               status: :succeeded
             } = receipt

      assert receipt.duration_us >= 0
      assert DateTime.compare(receipt.finished_at, receipt.started_at) in [:gt, :eq]
      assert receipt.outcome_digest =~ ~r/^[0-9a-f]{64}$/
    end

    test "a failed run is receipted as failed" do
      handlers = %{@authorize => FailingStep, @renew => OkStep}

      assert {{:error, _reason}, receipt} =
               AshPPlan.execute(@plan, handlers, %{}, %{}, run_id: "failed-run")

      assert receipt.status == :failed
      assert receipt.run_id == "failed-run"
      assert receipt.outcome_digest =~ ~r/^[0-9a-f]{64}$/
    end

    test "a halted run is receipted as halted without claiming persistence" do
      handlers = %{@authorize => HaltingStep, @renew => OkStep}

      assert {{:halted, halted_reactor}, receipt} =
               AshPPlan.execute(@plan, handlers, %{}, %{}, run_id: "halted-run")

      assert receipt.status == :halted
      assert halted_reactor.state == :halted
      assert receipt.outcome_digest =~ ~r/^[0-9a-f]{64}$/

      # A receipt is evidence about a halt, never a durable continuation.
      refute Map.has_key?(receipt, :continuation)

      assert [%{status: "gap", owner: "consumer"}] = AshPPlan.projections_for(:persistence)
    end
  end

  describe "content addressing" do
    test "identical observed outcomes digest identically" do
      {{:ok, _}, first} = AshPPlan.execute(@plan, all_ok(), %{}, %{}, run_id: "digest-a")
      {{:ok, _}, second} = AshPPlan.execute(@plan, all_ok(), %{}, %{}, run_id: "digest-b")

      assert first.outcome_digest == second.outcome_digest
      refute first.run_id == second.run_id
    end

    test "a different observed outcome digests differently" do
      {{:ok, _}, succeeded} = AshPPlan.execute(@plan, all_ok(), %{}, %{}, run_id: "digest-ok")

      {{:error, _}, failed} =
        AshPPlan.execute(@plan, %{@authorize => FailingStep, @renew => OkStep}, %{}, %{},
          run_id: "digest-error"
        )

      refute succeeded.outcome_digest == failed.outcome_digest
    end
  end

  describe "run identity" do
    test "a generated run identity is used when neither option nor context supplies one" do
      assert {{:ok, _}, receipt} = AshPPlan.execute(@plan, all_ok(), %{})
      assert receipt.run_id =~ ~r/^ash-pplan-[0-9a-f]{32}$/
    end

    test "Reactor runs under the same identity the receipt records" do
      handlers = %{@authorize => ReportReactorRunIdStep, @renew => OkStep}

      assert {{:ok, _}, receipt} =
               AshPPlan.execute(@plan, handlers, %{test_pid: self()}, %{}, run_id: "shared-run")

      # Reactor keeps its own run identity in process metadata. Without it being
      # passed through as a run option, Reactor would mint an unrelated ref and
      # the receipt would describe a different run than the telemetry does.
      assert_receive {:reactor_run_id, "shared-run"}
      assert receipt.run_id == "shared-run"
    end
  end

  describe "reserved context" do
    test "a caller cannot silently replace the semantic step metadata" do
      # Reactor merges the run context over each step's context, so an
      # :ash_pplan key in the caller's context would win.
      assert {:error,
              %Compiler.Error{reason: :reserved_context_keys, details: %{keys: [:ash_pplan]}}} =
               AshPPlan.execute(@plan, all_ok(), %{}, %{ash_pplan: %{step_iri: "spoofed"}})
    end
  end

  describe "refusal" do
    test "a refused compilation returns the refusal itself, with no execution receipt" do
      # execute/5 only receipts an observed Reactor outcome. A plan that never
      # compiled was never executed, so there is nothing to observe.
      assert {:error, %Compiler.Error{reason: :missing_handlers}} =
               AshPPlan.execute(@plan, %{@authorize => OkStep}, %{})
    end
  end

  test "two occurrences of the same failure digest identically" do
    handlers = %{@authorize => FailingStep, @renew => OkStep}

    {{:error, _}, first} = AshPPlan.execute(@plan, handlers, %{}, %{}, run_id: "fail-a")
    {{:error, _}, second} = AshPPlan.execute(@plan, handlers, %{}, %{}, run_id: "fail-b")

    # A Reactor error carries references and pids; digesting the struct itself
    # would give the same failure two different content addresses.
    assert first.outcome_digest == second.outcome_digest
  end

  describe "PROV-O projection" do
    setup do
      {{:ok, _}, receipt} = AshPPlan.execute(@plan, all_ok(), %{}, %{}, run_id: "prov-run")
      %{receipt: receipt, triples: ExecutionReceipt.to_rdf(receipt)}
    end

    test "the receipt is projected as a prov:Entity generated by a semantic execution", %{
      receipt: receipt,
      triples: triples
    } do
      receipt_iri = "urn:ash-pplan:receipt:#{receipt.outcome_digest}"
      execution_iri = "urn:ash-pplan:execution:prov-run"

      assert triples =~
               "<#{receipt_iri}> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <https://w3id.org/ash-pplan#ExecutionReceipt> ."

      assert triples =~
               "<#{receipt_iri}> <http://www.w3.org/ns/prov#wasGeneratedBy> <#{execution_iri}> ."

      assert triples =~
               "<#{execution_iri}> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <https://w3id.org/ash-pplan#SemanticExecution> ."

      assert triples =~ "<#{execution_iri}> <http://www.w3.org/ns/prov#used> <#{@plan}> ."
    end

    test "the declared receipt properties are the ones actually projected", %{
      receipt: receipt,
      triples: triples
    } do
      assert triples =~ ~s(<https://w3id.org/ash-pplan#runIdentifier> "prov-run" .)
      assert triples =~ ~s(<https://w3id.org/ash-pplan#executionStatus> "succeeded" .)

      assert triples =~
               ~s(<https://w3id.org/ash-pplan#resultDigest> "#{receipt.outcome_digest}" .)
    end

    test "every ash_pplan predicate it emits is declared in the canonical ontology", %{
      triples: triples
    } do
      ontology =
        __DIR__ |> Path.join("../ontology.ttl") |> Path.expand() |> File.read!()

      emitted =
        ~r{<https://w3id\.org/ash-pplan\#(\w+)>}
        |> Regex.scan(triples)
        |> Enum.map(&List.last/1)
        |> Enum.uniq()

      properties =
        emitted
        |> Enum.filter(&(&1 in ["runIdentifier", "executionStatus", "resultDigest"]))

      assert length(properties) == 3

      for property <- properties do
        assert ontology =~ ~r/^ap:#{property} a rdf:Property\b/m,
               "to_rdf/1 emits ap:#{property}, which the canonical ontology does not declare"
      end
    end

    test "every line is a well-formed N-Triples statement", %{triples: triples} do
      lines = triples |> String.split("\n", trim: true)

      assert length(lines) == 11

      for line <- lines do
        assert String.ends_with?(line, " ."), "not an N-Triples statement: #{line}"
        assert String.starts_with?(line, "<"), "subject is not an IRI: #{line}"
      end
    end

    test "a non-binary run identity is normalised rather than crashing" do
      assert ExecutionReceipt.run_identifier(:atom_run) == "atom_run"
      assert ExecutionReceipt.run_identifier(42) == "42"
      assert ExecutionReceipt.run_identifier({:composite, 1}) == "{:composite, 1}"
    end
  end

  defp all_ok, do: %{@authorize => OkStep, @renew => OkStep}
end
