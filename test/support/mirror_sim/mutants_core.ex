defmodule AshPPlan.MirrorSim.MutantsCore do
  @moduledoc """
  Mutant catalog A (core): compiler, standing, execution_receipt, obligation, digest.

  Pure data consumed by the mutation engine. Each entry is
  `%{id, file, anchor, replacement, court, expected_kill}` where `file` and `court`
  are repo-root-relative paths, `anchor` occurs exactly once in `file` (verified by
  `test/mirror_sim/mutants_core_test.exs` against the on-disk source), and
  `expected_kill` is `:killed` (court asserts the mutated behavior directly) or
  `:probable` (court exercises the path; kill not proven until run).
  """

  @compiler "lib/ash_pplan/compiler.ex"
  @standing "lib/ash_pplan/standing.ex"
  @receipt "lib/ash_pplan/execution_receipt.ex"
  @obligation "lib/ash_pplan/obligation.ex"
  @digest "lib/ash_pplan/digest.ex"

  @c_refusal "test/compiler_refusal_test.exs"
  @c_sem_court "test/courts/semantic_compiler_court_test.exs"
  @c_hard "test/hardening/compiler_options_hardening_test.exs"
  @c_powl "test/compiler_powl_seam_test.exs"
  @c_exec "test/semantic_execution_test.exs"
  @c_standing "test/standing_test.exs"
  @c_receipt "test/execution_receipt_test.exs"
  @c_g1 "test/workflow/g1_corresponds_to_step_court_test.exs"
  @c_oblig "test/durable/obligation_test.exs"
  @c_oblig_pm4 "test/pm4exunit/receipts_obligations_pm4_test.exs"
  @c_portable "test/standing/receipt_portable_projection_test.exs"

  @doc "The mutant catalog (list of specs)."
  @spec catalog() :: [map()]
  def catalog do
    compiler() ++ standing() ++ receipt() ++ obligation() ++ digest()
  end

  @doc "Distinct source files mutated by this catalog."
  def files, do: catalog() |> Enum.map(& &1.file) |> Enum.uniq()

  defp m(id, file, anchor, replacement, court, expected) do
    %{
      id: id,
      file: file,
      anchor: anchor,
      replacement: replacement,
      court: court,
      expected_kill: expected
    }
  end

  defp compiler do
    [
      m(
        "CMP-01-empty-plan-admitted",
        @compiler,
        ~S'defp validate_steps([]), do: {:error, error(:empty_plan, %{})}',
        ~S'defp validate_steps([]), do: :ok',
        @c_refusal,
        :killed
      ),
      m(
        "CMP-02-duplicates-admitted",
        @compiler,
        ~S'if duplicates == [] do',
        ~S'if true do',
        @c_refusal,
        :killed
      ),
      m(
        "CMP-03-dangling-admitted",
        @compiler,
        ~S'not MapSet.member?(known, predecessor),',
        ~S'false,',
        @c_hard,
        :probable
      ),
      m(
        "CMP-04-missing-handlers-admitted",
        @compiler,
        ~S'missing != [] -> {:error, error(:missing_handlers, %{steps: missing})}',
        ~S'missing != [] -> :ok',
        @c_sem_court,
        :probable
      ),
      m(
        "CMP-05-handler-behaviour-unchecked",
        @compiler,
        ~S'Code.ensure_loaded?(module) and Spark.implements_behaviour?(module, Reactor.Step)',
        ~S'Code.ensure_loaded?(module)',
        @c_refusal,
        :killed
      ),
      m(
        "CMP-06-handler-options-unchecked",
        @compiler,
        ~S'proper_list?(options) and Keyword.keyword?(options) and valid_handler?(module)',
        ~S'valid_handler?(module)',
        @c_refusal,
        :killed
      ),
      m(
        "CMP-07-root-indegree-off",
        @compiler,
        ~S'fn {_iri, degree} -> degree == 0 end',
        ~S'fn {_iri, degree} -> degree <= 1 end',
        @c_sem_court,
        :probable
      ),
      m(
        "CMP-08-cycle-check-bypassed",
        @compiler,
        ~S'if length(order) == length(steps) do',
        ~S'if true do',
        @c_sem_court,
        :probable
      ),
      m(
        "CMP-09-never-ready",
        @compiler,
        ~S'ready = if degree == 0, do: [dependent | ready], else: ready',
        ~S'ready = ready',
        @c_refusal,
        :killed
      ),
      m(
        "CMP-10-indegree-counts-duplicates",
        @compiler,
        ~S'{step.iri, step.predecessors |> Enum.uniq() |> length()}',
        ~S'{step.iri, length(step.predecessors)}',
        @c_refusal,
        :killed
      ),
      m(
        "CMP-11-predecessor-bound-off-by-one",
        @compiler,
        ~S'when length(predecessors) <= length(@predecessor_argument_names) do',
        ~S'when length(predecessors) < length(@predecessor_argument_names) do',
        @c_hard,
        :probable
      ),
      m(
        "CMP-12-predecessor-bound-zero",
        @compiler,
        ~S'when length(predecessors) <= length(@predecessor_argument_names) do',
        ~S'when length(predecessors) <= 0 do',
        @c_refusal,
        :killed
      ),
      m(
        "CMP-13-terminal-bound-off-by-one",
        @compiler,
        ~S'terminals when length(terminals) <= length(@terminal_argument_names) ->',
        ~S'terminals when length(terminals) <= length(@terminal_argument_names) + 1 ->',
        @c_refusal,
        :killed
      ),
      m(
        "CMP-14-context-dropped",
        @compiler,
        ~S'context: context,',
        ~S'context: %{},',
        @c_exec,
        :probable
      ),
      m(
        "CMP-15-predecessor-binding-value",
        @compiler,
        ~S'Argument.from_result(argument_name, predecessor)',
        ~S'Argument.from_value(argument_name, predecessor)',
        @c_exec,
        :probable
      ),
      m(
        "CMP-16-input-argument-dropped",
        @compiler,
        ~S'[{:input, {:input, :input}}] ++',
        ~S'[] ++',
        @c_exec,
        :probable
      ),
      m(
        "CMP-17-terminals-inverted",
        @compiler,
        ~S'|> Enum.reject(&MapSet.member?(depended_on, &1))',
        ~S'|> Enum.filter(&MapSet.member?(depended_on, &1))',
        @c_refusal,
        :killed
      ),
      m(
        "CMP-18-powl-always-refused",
        @compiler,
        ~S'defp validate_powl(_plan), do: :ok',
        ~S'defp validate_powl(_plan), do: {:error, error(:invalid_plan_spec, %{})}',
        @c_refusal,
        :killed
      ),
      m(
        "CMP-19-unsupported-powl-shape-refused",
        @compiler,
        ~S'defp admit_powl({:error, %{reason: :unsupported_powl_shape}}), do: :ok',
        ~S'defp admit_powl({:error, %{reason: :unsupported_powl_shape}}), do: {:error, error(:unsupported_powl_shape, %{})}',
        @c_powl,
        :probable
      ),
      m(
        "CMP-20-empty-iri-admitted",
        @compiler,
        ~S'when is_binary(iri) and byte_size(iri) > 0 do',
        ~S'when is_binary(iri) do',
        @c_hard,
        :probable
      )
    ]
  end

  defp standing do
    [
      m(
        "STD-01-always-alive",
        @standing,
        ~S'if broken == [], do: :alive, else: {:lost, broken}',
        ~S':alive',
        @c_standing,
        :killed
      ),
      m(
        "STD-02-verdict-inverted",
        @standing,
        ~S'v != :ok, do: layer',
        ~S'v == :ok, do: layer',
        @c_standing,
        :killed
      ),
      m(
        "STD-03-execution-always-ok",
        @standing,
        ~S'do: if(observed == wanted, do: :ok, else: {:error, {observed, wanted}})',
        ~S'do: :ok',
        @c_standing,
        :killed
      ),
      m(
        "STD-04-consequence-misses-false",
        @standing,
        ~S'case for({name, false} <- checks, do: name) do',
        ~S'case for({name, nil} <- checks, do: name) do',
        @c_standing,
        :killed
      ),
      m(
        "STD-05-provider-unchecked",
        @standing,
        ~S'provider != nil and provider != to_string(selected(selection, task))',
        ~S'false',
        @c_standing,
        :killed
      ),
      m(
        "STD-06-dependency-order-flipped",
        @standing,
        ~S'{:ok, p} -> p > Map.fetch!(position, task)',
        ~S'{:ok, p} -> p < Map.fetch!(position, task)',
        @c_standing,
        :killed
      ),
      m(
        "STD-07-missing-dependency-tolerated",
        @standing,
        ~S':error -> true',
        ~S':error -> false',
        @c_standing,
        :probable
      ),
      m(
        "STD-08-task-outside-model-inverted",
        @standing,
        ~S'&(not Map.has_key?(tasks, &1.attributes.task))',
        ~S'&(Map.has_key?(tasks, &1.attributes.task))',
        @c_standing,
        :killed
      ),
      m(
        "STD-09-fond-gate-inverted",
        @standing,
        ~S'gate.attributes.outcome not in admit and',
        ~S'gate.attributes.outcome in admit and',
        @c_standing,
        :probable
      ),
      m(
        "STD-10-events-unsorted",
        @standing,
        ~S'Enum.sort_by(events, & &1.attributes.seq)',
        ~S'events',
        @c_standing,
        :probable
      ),
      m(
        "STD-11-seal-always-alive",
        @standing,
        ~S'final = if result == :alive, do: "ALIVE", else: "REFUSED"',
        ~S'final = "ALIVE"',
        @c_standing,
        :probable
      ),
      m(
        "STD-12-empty-ledger-verifies",
        @standing,
        ~S'{Chain.head(chain), events != [] and Chain.verify(chain)}',
        ~S'{Chain.head(chain), Chain.verify(chain)}',
        @c_standing,
        :probable
      ),
      m(
        "STD-13-standing-field-always-alive",
        @standing,
        ~S'%{value: "ALIVE", derived_from: "ledger #{digest} at #{anchor}"}',
        ~S'%{value: "REFUSED(none)", derived_from: "ledger #{digest} at #{anchor}"}',
        @c_standing,
        :killed
      ),
      m(
        "STD-14-ceiling-do",
        @standing,
        ~S'Keyword.get(opts, :ceiling, "CONSTRUCT")',
        ~S'Keyword.get(opts, :ceiling, "DO")',
        @c_standing,
        :killed
      ),
      m(
        "STD-15-ocel-digest-unprefixed",
        @standing,
        ~S'"sha256:" <> (:crypto.hash(:sha256, json) |> Base.encode16(case: :lower))',
        ~S'(:crypto.hash(:sha256, json) |> Base.encode16(case: :lower))',
        @c_portable,
        :probable
      ),
      m(
        "STD-16-observed-rung-vacuous",
        @standing,
        ~S'OBSERVED: {events != [], "process_evidence events=#{length(events)}"},',
        ~S'OBSERVED: {true, "process_evidence events=#{length(events)}"},',
        @c_standing,
        :probable
      ),
      m(
        "STD-17-empty-observation-actuates",
        @standing,
        ~S'defp observed?(%{observation: o}), do: is_map(o) and map_size(o) > 0',
        ~S'defp observed?(%{observation: o}), do: is_map(o)',
        @c_standing,
        :probable
      ),
      m(
        "STD-18-validated-rung-vacuous",
        @standing,
        ~S'VALIDATED: {v.plan_correct == :ok, "plan_correct=ok"},',
        ~S'VALIDATED: {true, "plan_correct=ok"},',
        @c_standing,
        :killed
      )
    ]
  end

  defp receipt do
    [
      m(
        "RCP-01-failed-status-unknown",
        @receipt,
        ~S'defp status({:error, _reason}), do: :failed',
        ~S'defp status({:error, _reason}), do: :unknown',
        @c_receipt,
        :killed
      ),
      m(
        "RCP-02-halted-status-failed",
        @receipt,
        ~S'defp status({:halted, _reactor}), do: :halted',
        ~S'defp status({:halted, _reactor}), do: :failed',
        @c_receipt,
        :killed
      ),
      m(
        "RCP-03-stacktrace-kept",
        @receipt,
        ~S'|> Map.drop([:stacktrace])',
        ~S'|> Map.drop([])',
        @c_receipt,
        :probable
      ),
      m(
        "RCP-04-pid-not-canonical",
        @receipt,
        ~S'defp canonical(value, _seen) when is_pid(value), do: :"$pid"',
        ~S'defp canonical(value, _seen) when is_pid(value), do: value',
        @c_receipt,
        :killed
      ),
      m(
        "RCP-05-reference-not-canonical",
        @receipt,
        ~S'defp canonical(value, _seen) when is_reference(value), do: :"$reference"',
        ~S'defp canonical(value, _seen) when is_reference(value), do: value',
        @c_receipt,
        :probable
      ),
      m(
        "RCP-06-sha-width-wrong",
        @receipt,
        ~S'Regex.match?(~r/^[0-9a-f]{40}$/, sha)',
        ~S'Regex.match?(~r/^[0-9a-f]{64}$/, sha)',
        @c_receipt,
        :killed
      ),
      m(
        "RCP-07-blank-repo-admitted",
        @receipt,
        ~S'if is_binary(receipt.repo) and String.trim(receipt.repo) == "" do',
        ~S'if false do',
        @c_receipt,
        :killed
      ),
      m(
        "RCP-08-result-digest-constant",
        @receipt,
        ~S'{receipt_iri, @ap <> "resultDigest", {:literal, receipt.outcome_digest}},',
        ~S'{receipt_iri, @ap <> "resultDigest", {:literal, "constant"}},',
        @c_receipt,
        :probable
      ),
      m(
        "RCP-09-newline-unescaped",
        @receipt,
        ~S'defp escape_char(?\n), do: "\\n"',
        ~S'defp escape_char(?\n), do: "\n"',
        @c_receipt,
        :killed
      ),
      m(
        "RCP-10-backslash-unescaped",
        @receipt,
        ~S'defp escape_char(?\\), do: "\\\\"',
        ~S'defp escape_char(?\\), do: "\\"',
        @c_receipt,
        :killed
      ),
      m(
        "RCP-11-invalid-utf8-iri-admitted",
        @receipt,
        ~S'defp iri_byte_admitted?(byte, utf8?) when byte >= 0x80, do: utf8?',
        ~S'defp iri_byte_admitted?(byte, utf8?) when byte >= 0x80, do: true',
        @c_receipt,
        :probable
      ),
      m(
        "RCP-12-space-admitted-in-iri",
        @receipt,
        ~S'when byte <= 0x20 or byte == 0x7F, do: false',
        ~S'when byte < 0x20 or byte == 0x7F, do: false',
        @c_receipt,
        :killed
      ),
      m(
        "RCP-13-persisted-steps-ignored",
        @receipt,
        ~S'Keyword.get(opts, :corresponds_to_steps) || receipt.corresponds_to_steps || []',
        ~S'Keyword.get(opts, :corresponds_to_steps) || []',
        @c_g1,
        :probable
      ),
      m(
        "RCP-14-binding-ignores-observed-outcome",
        @receipt,
        ~S'if bound_outcome == :__no_outcome__, do: outcome_term(outcome), else: bound_outcome',
        ~S'bound_outcome',
        @c_receipt,
        :killed
      ),
      m(
        "RCP-15-digest-version-bump",
        @receipt,
        ~S'@digest_version {:ash_pplan_receipt_digest, 2}',
        ~S'@digest_version {:ash_pplan_receipt_digest, 3}',
        @c_receipt,
        :probable
      )
    ]
  end

  defp obligation do
    [
      m(
        "OBL-01-id-prefix-truncated",
        @obligation,
        ~S'id = "obl-" <> binary_part(digest, 0, 16)',
        ~S'id = "obl-" <> binary_part(digest, 0, 8)',
        @c_oblig,
        :probable
      ),
      m(
        "OBL-02-digest-unprefixed",
        @obligation,
        ~S'digest: "sha256:" <> digest,',
        ~S'digest: digest,',
        @c_oblig,
        :killed
      ),
      m(
        "OBL-03-verify-always-true",
        @obligation,
        ~S'actual_hash == expected_hash',
        ~S'true',
        @c_oblig_pm4,
        :probable
      ),
      m(
        "OBL-04-malformed-verifies",
        @obligation,
        ~S'def verify_digest(_), do: false',
        ~S'def verify_digest(_), do: true',
        @c_oblig_pm4,
        :probable
      )
    ]
  end

  defp digest do
    [
      m(
        "DIG-01-sha512",
        @digest,
        ~S'do: :crypto.hash(:sha256, IO.iodata_to_binary(input))',
        ~S'do: :crypto.hash(:sha512, IO.iodata_to_binary(input))',
        @c_receipt,
        :probable
      ),
      m(
        "DIG-02-hex-uppercase",
        @digest,
        ~S'def hex(digest), do: Base.encode16(digest, case: :lower)',
        ~S'def hex(digest), do: Base.encode16(digest, case: :upper)',
        @c_receipt,
        :probable
      )
    ]
  end
end
