defmodule AshPPlan.MirrorSim.MutantsRuntime do
  @moduledoc """
  Mutant catalog B (runtime side) as data: durable policy driver / status / poll / dispatch / clock,
  FOND validation, POWL, providers registry, runtime_contract, SA2A.

  Each mutant is `%{id, file, anchor, replacement, court, equivalent}`:

    * `file`        path relative to the repo root (a file under `lib/`)
    * `anchor`      substring that occurs EXACTLY ONCE in `file`
    * `replacement` text substituted for `anchor`
    * `court`       test file that must fail on the mutated source (existing, or a
                    `test/mirror_sim/` court that the mirror lanes own)
    * `equivalent`  nil, or a note that the mutant is expected to SURVIVE and why

  This module never writes `lib/`. `apply_mutant/2` is pure (binary in, binary out); callers
  mutate a scratch copy only.
  """

  @rc "test/mirror_sim/standing_test.exs"

  @spec catalog() :: [map()]
  def catalog do
    [
      # --- runtime_contract -------------------------------------------------------------------
      m(
        "RC-01",
        "lib/ash_pplan/runtime_contract/authority_gate.ex",
        ~s|@allowed_action "CONSTRUCT"|,
        ~s|@allowed_action "DO"|,
        @rc
      ),
      m(
        "RC-02",
        "lib/ash_pplan/runtime_contract/authority_gate.ex",
        "when not is_nil(policy), do: :ok",
        "when true, do: :ok",
        @rc
      ),
      m(
        "RC-03",
        "lib/ash_pplan/runtime_contract/exact_subject.ex",
        "def exact?(%{repo: @repo, base: @base, head: @head}), do: true",
        "def exact?(%{repo: @repo, base: @base}), do: true",
        @rc
      ),
      m(
        "RC-04",
        "lib/ash_pplan/runtime_contract/exact_subject.ex",
        "def exact?(_), do: false",
        "def exact?(_), do: true",
        @rc
      ),
      m(
        "RC-05",
        "lib/ash_pplan/runtime_contract/replay.ex",
        "{:ok, key} when not is_nil(key) -> fun.(key)",
        "{:ok, key} -> fun.(key)",
        @rc
      ),
      m(
        "RC-06",
        "lib/ash_pplan/runtime_contract/replay.ex",
        "_ -> {:error, {:refused, :missing_replay_key}}",
        "_ -> fun.(nil)",
        @rc
      ),
      m(
        "RC-07",
        "lib/ash_pplan/runtime_contract/authority_gate.ex",
        "def authorize(_), do: {:error, {:refused, :authority, :missing_action}}",
        "def authorize(_), do: :ok",
        @rc
      ),
      m(
        "RC-08",
        "lib/ash_pplan/runtime_contract/receipt.ex",
        "replay_key: replay_key,",
        "replay_key: nil,",
        @rc
      ),
      # --- sa2a -------------------------------------------------------------------------------
      m(
        "SA-01",
        "lib/ash_pplan/sa2a/subject_guard.ex",
        ~s|(is_binary(subject) and subject != "")|,
        "is_binary(subject)",
        "test/sa2a/subject_guard_test.exs"
      ),
      m(
        "SA-02",
        "lib/ash_pplan/sa2a/subject_guard.ex",
        "(is_atom(subject) and not is_nil(subject))",
        "is_atom(subject)",
        "test/sa2a/subject_guard_test.exs"
      ),
      m(
        "SA-03",
        "lib/ash_pplan/sa2a/subject_guard.ex",
        "def preserve(subject, %{subject: subject} = candidate), do: {:ok, candidate}",
        "def preserve(_subject, candidate) when is_map(candidate), do: {:ok, candidate}",
        "test/sa2a/subject_guard_test.exs"
      ),
      m(
        "SA-04",
        "lib/ash_pplan/sa2a/subject_guard.ex",
        "authority: :none",
        "authority: :construct",
        "test/sa2a/subject_guard_test.exs"
      ),
      m(
        "SA-05",
        "lib/ash_pplan/sa2a/refusal.ex",
        "do: %{code: code, detail: detail, authority: :none}",
        "do: %{code: code, detail: detail, authority: :construct}",
        "test/sa2a/refusal_test.exs"
      ),
      m(
        "SA-06",
        "lib/ash_pplan/sa2a/refusal.ex",
        "    :unsupported_formalism,\n",
        "",
        "test/sa2a/refusal_test.exs"
      ),
      m(
        "SA-07",
        "lib/ash_pplan/sa2a/replay.ex",
        "authority: :none,",
        "authority: :construct,",
        "test/sa2a/replay_test.exs"
      ),
      m(
        "SA-08",
        "lib/ash_pplan/sa2a/replay.ex",
        "standing: :candidate,",
        "standing: :admitted,",
        "test/sa2a/replay_test.exs"
      ),
      m(
        "SA-09",
        "lib/ash_pplan/sa2a/replay.ex",
        "mode not in [:strong, :strong_cyclic]",
        "mode not in [:strong]",
        "test/sa2a/replay_test.exs"
      ),
      m(
        "SA-10",
        "lib/ash_pplan/sa2a/replay.ex",
        "^subject -> :ok",
        "_ -> :ok",
        "test/sa2a/replay_test.exs"
      ),
      m(
        "SA-11",
        "lib/ash_pplan/sa2a/replay.ex",
        "if Keyword.keyword?(opts), do: :ok, else: {:error, {:invalid_opts, opts}}",
        "if Keyword.keyword?(opts), do: :ok, else: :ok",
        "test/sa2a/replay_test.exs"
      ),
      # --- durable policy driver --------------------------------------------------------------
      m(
        "PD-01",
        "lib/ash_pplan/reactor/durable/policy_driver.ex",
        "if observed in admitted do",
        "if true do",
        "test/durable/mutations/policy_driver_admit_mutation_test.exs"
      ),
      m(
        "PD-02",
        "lib/ash_pplan/reactor/durable/policy_driver.ex",
        "{:ok, _report} -> :ok",
        "{:ok, _report} -> :ok\n      {:error, _} -> :ok",
        "test/durable/policy_driver_test.exs"
      ),
      m(
        "PD-03",
        "lib/ash_pplan/reactor/durable/policy_driver.ex",
        "goal?(driver, state) ->",
        "false ->",
        "test/durable/policy_driver_test.exs"
      ),
      m(
        "PD-04",
        "lib/ash_pplan/reactor/durable/policy_driver.ex",
        "Map.has_key?(driver.policy, state) ->",
        "true ->",
        "test/durable/policy_driver_test.exs"
      ),
      m(
        "PD-05",
        "lib/ash_pplan/reactor/durable/policy_driver.ex",
        "authority: :none, ceiling: :construct]",
        "authority: :none, ceiling: :do]",
        "test/durable/policy_driver_test.exs"
      ),
      m(
        "PD-06",
        "lib/ash_pplan/reactor/durable/policy_driver.ex",
        "[:deterministic, minor_version: 2]",
        "[]",
        "test/durable/policy_driver_test.exs",
        "Equivalent unless a court pins a fingerprint across term_to_binary encodings; " <>
          "expected to survive within one OTP."
      ),
      # --- durable status ---------------------------------------------------------------------
      m(
        "ST-01",
        "lib/ash_pplan/reactor/durable/status.ex",
        "@terminal ~w(completed failed cancelled)a",
        "@terminal ~w(completed failed)a",
        "test/hardening/status_fuzz_test.exs"
      ),
      m(
        "ST-02",
        "lib/ash_pplan/reactor/durable/status.ex",
        "completed: [],",
        "completed: ~w(failed)a,",
        "test/hardening/status_fuzz_test.exs"
      ),
      m(
        "ST-03",
        "lib/ash_pplan/reactor/durable/status.ex",
        "def cancellable?(s), do: s in [:pending, :waiting, :polling]",
        "def cancellable?(s), do: s in [:pending, :waiting, :polling, :completed]",
        "test/hardening/status_fuzz_test.exs"
      ),
      m(
        "ST-04",
        "lib/ash_pplan/reactor/durable/status.ex",
        "unwinding: ~w(failed unwind_blocked)a,",
        "unwinding: ~w(failed unwind_blocked completed)a,",
        "test/hardening/status_fuzz_test.exs"
      ),
      m(
        "ST-05",
        "lib/ash_pplan/reactor/durable/status.ex",
        "@parked ~w(waiting polling)a",
        "@parked ~w(waiting)a",
        "test/hardening/status_fuzz_test.exs"
      ),
      # --- durable steps / clock --------------------------------------------------------------
      m(
        "DS-01",
        "lib/ash_pplan/reactor/durable/steps/poll.ex",
        ":ok = mod.release(store, run_id, name)",
        ":ok",
        "test/durable/poll_test.exs"
      ),
      m(
        "DS-02",
        "lib/ash_pplan/reactor/durable/steps/poll.ex",
        "every = max(Keyword.get(options, :every, @default_every), 1)",
        "every = Keyword.get(options, :every, @default_every)",
        "test/durable/poll_test.exs",
        "Survives unless a court polls with every: 0 and asserts a strictly future deadline."
      ),
      m(
        "DS-03",
        "lib/ash_pplan/reactor/durable/steps/poll.ex",
        "overwrite: true",
        "overwrite: false",
        "test/durable/poll_test.exs"
      ),
      m(
        "DS-04",
        "lib/ash_pplan/reactor/durable/steps/dispatch.ex",
        "if Keyword.get(options, :async?, false) do",
        "if true do",
        "test/durable/dispatch_test.exs"
      ),
      m(
        "DS-05",
        "lib/ash_pplan/reactor/durable/steps/dispatch.ex",
        "do: if(Status.terminal?(child.status), do: {:ended, child}, else: {:live, child})",
        "do: {:live, child}",
        "test/durable/dispatch_durability_test.exs"
      ),
      m(
        "DS-06",
        "lib/ash_pplan/reactor/durable/steps/dispatch.ex",
        "child_id = Key.child_id(parent_id, name)",
        "child_id = Key.child_id(parent_id, :fixed)",
        "test/durable/dispatch_durability_test.exs"
      ),
      m(
        "DS-07",
        "lib/ash_pplan/reactor/durable/clock.ex",
        "def add(%DateTime{} = t, ms), do: DateTime.add(t, ms, :millisecond)",
        "def add(%DateTime{} = t, ms), do: DateTime.add(t, ms, :second)",
        "test/durable/poll_test.exs"
      ),
      m(
        "DS-08",
        "lib/ash_pplan/reactor/durable/clock.ex",
        "n = DateTime.add(t, ms, :millisecond)",
        "n = t",
        "test/durable/testing_test.exs"
      ),
      # --- providers registry -----------------------------------------------------------------
      m(
        "PR-01",
        "lib/ash_pplan/providers/registry.ex",
        "sealed: Map.put(reg.sealed, module, reason),",
        "sealed: reg.sealed,",
        "test/workflow/registry_test.exs"
      ),
      m(
        "PR-02",
        "lib/ash_pplan/providers/registry.ex",
        "providers: List.delete(reg.providers, module),",
        "providers: reg.providers,",
        "test/workflow/registry_test.exs"
      ),
      m(
        "PR-03",
        "lib/ash_pplan/providers/registry.ex",
        "providers: Enum.uniq(reg.providers ++ [module]),",
        "providers: reg.providers ++ [module],",
        "test/workflow/registry_test.exs",
        "Survives unless a court registers an already-present module and asserts uniqueness."
      ),
      m(
        "PR-04",
        "lib/ash_pplan/providers/registry.ex",
        "if module in reg.providers do",
        "if true do",
        "test/workflow/registry_test.exs"
      ),
      m(
        "PR-05",
        "lib/ash_pplan/providers/registry.ex",
        "detail: :invalid_requirement_or_context}}",
        "detail: :other}}",
        "test/hardening/providers_action_hardening_test.exs"
      ),
      # --- FOND -------------------------------------------------------------------------------
      m(
        "FO-01",
        "lib/ash_pplan/fond.ex",
        "not MapSet.subset?(collect_states(transitions, goals), states) ->",
        "false ->",
        "test/fond_hardening_test.exs"
      ),
      m(
        "FO-02",
        "lib/ash_pplan/fond.ex",
        "if MapSet.subset?(reachable, winning) do",
        "if true do",
        "test/fond_test.exs"
      ),
      m(
        "FO-03",
        "lib/ash_pplan/fond.ex",
        "if MapSet.subset?(reachable, goal_reachable) do",
        "if true do",
        "test/fond_test.exs"
      ),
      m(
        "FO-04",
        "lib/ash_pplan/fond.ex",
        "if remaining == 0,",
        "if remaining <= 0,",
        "test/fond_test.exs",
        "Equivalent: normalized outcome lists are duplicate-free, so each predecessor edge " <>
          "decrements pending exactly once and it never goes below 0."
      ),
      m(
        "FO-05",
        "lib/ash_pplan/fond.ex",
        "MapSet.member?(domain.goals, state) ->",
        "false ->",
        "test/fond_test.exs"
      ),
      m(
        "FO-06",
        "lib/ash_pplan/fond.ex",
        ":error -> {:error, %{reason: :missing_policy_action, state: state}}",
        ":error -> {:ok, nil}",
        "test/fond_hardening_test.exs"
      ),
      m(
        "FO-07",
        "lib/ash_pplan/fond.ex",
        "reason: :unavailable_policy_action,",
        "reason: :missing_policy_action,",
        "test/fond_hardening_test.exs"
      ),
      # --- POWL -------------------------------------------------------------------------------
      m(
        "PW-01",
        "lib/ash_pplan/powl.ex",
        "defp to_endpoint(i) when is_integer(i) and i >= 0, do: {:child, i}",
        "defp to_endpoint(i) when is_integer(i) and i > 0, do: {:child, i}",
        "test/powl/choice_graph_test.exs"
      ),
      m(
        "PW-02",
        "lib/ash_pplan/powl.ex",
        "def normalize(_other), do: {:error, %{reason: :unsupported_powl_shape}}",
        "def normalize(_other), do: {:ok, activity(\"x\")}",
        "test/powl/verifier_test.exs"
      ),
      m(
        "PW-03",
        "lib/ash_pplan/powl.ex",
        "|> Enum.filter(fn {s, t} -> MapSet.member?(ids, s) and MapSet.member?(ids, t) end)",
        "|> Enum.filter(fn {s, t} -> MapSet.member?(ids, s) or MapSet.member?(ids, t) end)",
        "test/powl/verifier_test.exs"
      ),
      m(
        "PW-04",
        "lib/ash_pplan/powl.ex",
        ~s|defp root_suffix([]), do: "empty"|,
        ~s|defp root_suffix([]), do: "none"|,
        "test/powl/verifier_test.exs",
        "Survives unless a court pins the root id of an empty-steps catalog plan."
      ),
      m(
        "PW-05",
        "lib/ash_pplan/powl.ex",
        "%Node{id: to_id(id), operator: :loop, children: [body, redo]}",
        "%Node{id: to_id(id), operator: :loop, children: [redo, body]}",
        "test/powl/verifier_test.exs"
      )
    ]
  end

  @doc "Apply one mutant to `source`. Refuses (raises) unless the anchor occurs exactly once."
  @spec apply_mutant(String.t(), map()) :: String.t()
  def apply_mutant(source, %{anchor: anchor, replacement: repl, id: id}) do
    case occurrences(source, anchor) do
      1 -> String.replace(source, anchor, repl, global: false)
      n -> raise ArgumentError, "mutant #{id}: anchor occurs #{n} times (need exactly 1)"
    end
  end

  @spec occurrences(String.t(), String.t()) :: non_neg_integer()
  def occurrences(source, anchor), do: length(:binary.matches(source, anchor))

  @doc "Check every anchor against the real files under `root` (read-only)."
  @spec verify_anchors(Path.t()) :: [{String.t(), non_neg_integer()}]
  def verify_anchors(root \\ File.cwd!()) do
    for %{id: id, file: file, anchor: anchor} <- catalog() do
      n =
        case File.read(Path.join(root, file)) do
          {:ok, src} -> occurrences(src, anchor)
          {:error, _} -> 0
        end

      {id, n}
    end
  end

  defp m(id, file, anchor, replacement, court, equivalent \\ nil) do
    %{
      id: id,
      file: file,
      anchor: anchor,
      replacement: replacement,
      court: court,
      equivalent: equivalent
    }
  end
end
