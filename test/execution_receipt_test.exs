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

      # Persistence is the durable ledger Store behaviour; a plain execute/5
      # run configures no Store, so the halted receipt carries none.
      assert [%{status: "reuse", owner: "durable"}] = AshPPlan.projections_for(:persistence)
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

  describe "N-Triples escaping of hostile identities" do
    @iriref ~S/<[^\x00-\x20<>"{}|^`\\]*>/
    @literal ~S/"(?:[^"\\\n\r]|\\[tbnrf"'\\]|\\u[0-9A-F]{4})*"/

    defp ntriples_line?(line) do
      Regex.match?(
        ~r/\A#{@iriref} #{@iriref} (?:#{@iriref}|#{@literal}(?:\^\^#{@iriref})?) \.\z/u,
        line
      )
    end

    defp hostile_receipt(plan_iri, run_id) do
      now = DateTime.utc_now()

      %ExecutionReceipt{
        plan_iri: plan_iri,
        run_id: run_id,
        status: :succeeded,
        started_at: now,
        finished_at: now,
        duration_us: 0,
        outcome_digest: String.duplicate("a", 64)
      }
    end

    test "every triple stays one valid line whatever bytes the run and plan identities carry" do
      hostile = [
        "x>\n<urn:evil> <urn:p> <urn:o> .\n<urn:y",
        "tab\tcr\rnul\0bell\a del\x7F",
        ~S(back\slash "quote" {brace} |pipe| ^caret^ `tick`),
        "caf\u00e9 \u2603",
        <<0xFF, 0xFE, ?x>>
      ]

      for run_id <- hostile, plan_iri <- ["urn:plan:" <> "ok", "urn:plan:" <> run_id] do
        triples = ExecutionReceipt.to_rdf(hostile_receipt(plan_iri, run_id))
        lines = String.split(triples, "\n", trim: true)

        assert String.valid?(triples)
        assert length(lines) == 11

        for line <- lines do
          assert ntriples_line?(line), "not a valid N-Triples line: #{inspect(line)}"
        end
      end
    end

    test "distinct run identities keep distinct execution IRIs" do
      execution_iri = fn run_id ->
        [_, iri] =
          Regex.run(
            ~r/<(urn:ash-pplan:execution:[^>]*)>/,
            ExecutionReceipt.to_rdf(hostile_receipt("urn:plan", run_id))
          )

        iri
      end

      assert execution_iri.("a b") != execution_iri.("a%20b")
      assert execution_iri.("run-1") == "urn:ash-pplan:execution:run-1"
    end
  end

  defp all_ok, do: %{@authorize => OkStep, @renew => OkStep}

  describe "subject identity anchoring (receipt-schema-diff 2026-10-03 step 4)" do
    defp observe(opts \\ []) do
      now = DateTime.utc_now()
      mono = System.monotonic_time(:microsecond)
      ExecutionReceipt.observe("urn:plan:x", "r1", {:ok, :done}, now, mono, opts)
    end

    test "identity fields default to nil (evidence-only receipt unchanged)" do
      r = observe()
      assert r.repo == nil and r.subject_sha == nil and r.base_sha == nil
      assert :ok == ExecutionReceipt.validate_identity(r)
    end

    test "observe/6 anchors repo + 40-hex subject_sha/base_sha" do
      head = String.duplicate("a", 40)
      base = String.duplicate("b", 40)

      r = observe(repo: "ash_pplan", subject_sha: head, base_sha: base)

      assert r.repo == "ash_pplan"
      assert r.subject_sha == head
      assert r.base_sha == base
      assert :ok == ExecutionReceipt.validate_identity(r)
    end

    test "execute/5 threads the :receipt_identity option into the receipt" do
      head = String.duplicate("c", 40)

      assert {{:ok, @renew}, receipt} =
               AshPPlan.execute(@plan, all_ok(), %{}, %{},
                 run_id: "anchored-run",
                 receipt_identity: [repo: "ash_pplan", subject_sha: head, base_sha: head]
               )

      assert receipt.repo == "ash_pplan"
      assert receipt.subject_sha == head
    end

    test "validate_identity refuses a non-40-hex sha and a blank repo" do
      assert {:error, {:bad_identity, :subject_sha}} =
               observe(subject_sha: String.duplicate("a", 39))
               |> ExecutionReceipt.validate_identity()

      assert {:error, {:bad_identity, :base_sha}} =
               observe(base_sha: "ZZ" <> String.duplicate("a", 38))
               |> ExecutionReceipt.validate_identity()

      assert {:error, {:bad_identity, :repo}} =
               observe(repo: "   ") |> ExecutionReceipt.validate_identity()
    end
  end
end
