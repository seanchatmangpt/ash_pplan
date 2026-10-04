defmodule AshPPlan.Sim.Marketplace.Reactors.ContractCourts.Engine do
  @moduledoc """
  Contract-court engine giving the five generated RuntimeContract surfaces
  (`AshPPlan.RuntimeContract.{ExactSubject, AuthorityGate, Receipt, Replay,
  Refusal}`) a second, non-vacuous subject family: the four marketplace_sim
  Reactor subjects (Signup / Activation / Usage / Reporting).

  The first subject family for these surfaces is the durable-runtime pack
  itself; this family is NON-DURABLE — plain `Reactor.run/2` over real
  in-process sim processes (portal JWT, ProcurementApi, metering, billing),
  no durable ledger in the court loop.

  Legs:

    * signature/inputs conformance — each subject executes to `{:ok, _}`
      against its manifest inputs (real typed execution, not shape
      introspection);
    * refusal-shape conformance (negative corpus) — every poisoned-input
      class must return a TYPED refusal whose declared tag and reason
      surface in the error; never a bare raise;
    * idempotency keys honored — duplicate JWT, duplicate usage-event id,
      duplicate report ref each return `:duplicate` / typed refusal without
      double-counting real process state;
    * RuntimeContract surface interop — observed refusals map into
      `RuntimeContract.Refusal`, receipts carry the idempotency key as
      `replay_key` and replay through `RuntimeContract.Replay`, subjects
      bind to `RuntimeContract.ExactSubject` identity, and the court's own
      dispatch rows pass `RuntimeContract.AuthorityGate`;
    * anti-vacuity — the refusal-shape leg is subject-parameterized: run it
      over `ContractCourts.MutantSubjects` (refusal shape corrupted
      in-memory) and it must FAIL, so the court cannot pass on unconstrained
      subjects.
  """

  import AshPPlan.Sim.Marketplace.Reactors.ContractCourts.Drivers

  alias AshPPlan.RuntimeContract.{AuthorityGate, ExactSubject, Receipt, Refusal, Replay}

  alias AshPPlan.Sim.Marketplace.Reactors.{
    ActivationReactor,
    ReportingReactor,
    SignupReactor,
    UsageReactor
  }

  alias Vendor.MeteringServer

  @aud "marketplace"
  @ts 1_700_000_500
  @pool_id :rcr_court_pool
  @pool_committed 10_000
  @ent "rc-acct-1-ent"

  # -- subject manifest ---------------------------------------------------------

  @doc """
  The second subject family: four entries, each with its happy-path drive
  (signature conformance), its poisoned-input classes (negative corpus) and
  its idempotency probe (a thunk run twice against the same key).
  """
  def real_subjects do
    [
      %{
        name: :signup,
        module: SignupReactor,
        happy: fn ctx ->
          {:ok, token} = issue(ctx, sub: "rc-acct-1", aud: @aud, exp_seconds: 3600)
          signup_inputs(ctx, "rc-acct-1", token)
        end,
        negative: [
          %{
            class: :expired_jwt,
            expect_tag: :jwt_refused,
            expect_reason: :expired,
            drive: fn ctx ->
              {:ok, token} = issue(ctx, sub: "rc-neg-1", aud: @aud, exp_seconds: -60)
              signup_inputs(ctx, "rc-neg-1", token)
            end
          },
          %{
            class: :malformed_jwt,
            expect_tag: :jwt_refused,
            expect_reason: :malformed,
            drive: fn ctx -> signup_inputs(ctx, "rc-neg-2", "garbage.not.a.jwt") end
          },
          %{
            class: :wrong_aud_jwt,
            expect_tag: :jwt_refused,
            expect_reason: :wrong_aud,
            drive: fn ctx ->
              {:ok, token} = issue(ctx, sub: "rc-neg-3", aud: "some-one-else", exp_seconds: 3600)
              signup_inputs(ctx, "rc-neg-3", token)
            end
          }
        ],
        idempotency: fn ctx ->
          # duplicate JWT: Portal.issue is deterministic over claims, so the
          # same (sub, aud, now, exp) re-issues the SAME token string. The
          # second signup with that token must be a TYPED refusal
          # (:already_exists) and must not double-apply the creation event.
          {:ok, tok_a} = issue(ctx, sub: "rc-acct-2", aud: @aud, exp_seconds: 3600)
          {:ok, tok_b} = issue(ctx, sub: "rc-acct-2", aud: @aud, exp_seconds: 3600)

          cond do
            tok_a != tok_b ->
              [fail("idempotency/duplicate_jwt_token_stable", :token_differ)]

            true ->
              case Reactor.run(SignupReactor, signup_inputs(ctx, "rc-acct-2", tok_a)) do
                {:ok, _} ->
                  case Reactor.run(SignupReactor, signup_inputs(ctx, "rc-acct-2", tok_b)) do
                    {:error, first} ->
                      text = inspect(first)

                      if text =~ "create_account_refused" and text =~ ":already_exists" do
                        creation =
                          journal_creation_events(ctx, "rc-acct-2-ent")

                        violations_unless(
                          "idempotency/duplicate_jwt",
                          length(creation) == 1,
                          {:creation_events, length(creation)}
                        )
                      else
                        [fail("idempotency/duplicate_jwt", "refusal shape drifted: " <> text)]
                      end

                    {:ok, _} ->
                      [fail("idempotency/duplicate_jwt", :expected_refusal_got_ok)]

                    other ->
                      [fail("idempotency/duplicate_jwt", inspect(other))]
                  end

                {:error, err} ->
                  [fail("idempotency/duplicate_jwt", "first signup failed: " <> inspect(err))]
              end
          end
        end
      },
      %{
        name: :activation,
        module: ActivationReactor,
        happy: fn ctx ->
          activation_inputs(ctx, "rc-acct-1")
        end,
        negative: [
          %{
            class: :unknown_account,
            expect_tag: :approve_account_refused,
            expect_reason: :not_found,
            drive: fn ctx -> activation_inputs(ctx, "rc-no-such-account") end
          }
        ],
        idempotency: fn ctx ->
          # duplicate activation event id: re-applying ENTITLEMENT_ACTIVE with
          # the same event id is an exact no-op (ProcurementApi idempotent
          # redelivery), and the activation stays confirmed.
          with {:ok, _} <-
                 AshPPlan.Sim.Marketplace.Google.ProcurementApi.create_account(
                   ctx.api,
                   "rc-acct-2-active"
                 ),
               {:ok, _} <-
                 Reactor.run(ActivationReactor, activation_inputs(ctx, "rc-acct-2-active")),
               {:ok, _} <-
                 Reactor.run(ActivationReactor, activation_inputs(ctx, "rc-acct-2-active")) do
            []
          else
            other -> [fail("idempotency/duplicate_activation", inspect(other))]
          end
        end
      },
      %{
        name: :usage,
        module: UsageReactor,
        happy: fn ctx -> usage_inputs(ctx, "rc-wf-1") end,
        negative: [
          %{
            class: :unknown_workflow_source,
            expect_tag: :run_refused,
            expect_reason: :unknown_workflow,
            drive: fn ctx -> %{usage_inputs(ctx, "rc-wf-neg") | source: :no_such_workflow} end
          }
        ],
        idempotency: fn ctx ->
          # duplicate usage-event id: the usage event id is
          # "plan_solve-" <> run_id; re-posting that exact
          # (entitlement, event id) key must return {:ok, :duplicate} and
          # leave the metering total unchanged.
          ent = "rc-acct-1-ent"

          with {:ok, %{usage: :recorded}} <-
                 Reactor.run(UsageReactor, usage_inputs(ctx, "rc-wf-2")),
               {:ok, totals_before} <- MeteringServer.totals(ctx.metering),
               {:ok, :duplicate} <-
                 MeteringServer.post_usage(
                   ctx.metering,
                   ent,
                   "plan_solve-rc-wf-2",
                   "plan_solve",
                   500,
                   @ts
                 ),
               {:ok, totals_after} <- MeteringServer.totals(ctx.metering) do
            violations_unless(
              "idempotency/duplicate_usage_event",
              totals_before == totals_after,
              :totals_moved_after_duplicate
            )
          else
            other -> [fail("idempotency/duplicate_usage_event", inspect(other))]
          end
        end
      },
      %{
        name: :reporting,
        module: ReportingReactor,
        happy: fn ctx -> report_inputs(ctx, "rc-report-1", @ent) end,
        negative: [
          %{
            class: :empty_window_report,
            expect_tag: :invalid_total,
            expect_reason: 0,
            drive: fn ctx ->
              # poisoned input class: a window over an entitlement with no
              # usage events aggregates to 0; record_drawdown must REFUSE the
              # zero total as a typed error, not draw 0 from the pool.
              %{
                report_inputs(ctx, "rc-report-neg", "rc-empty-ent")
                | entitlement_id: "rc-empty-ent"
              }
            end
          }
        ],
        idempotency: fn ctx ->
          # duplicate report ref: the second run must return drawdown
          # :duplicate and leave the committed pool untouched.
          ent = "rc-acct-4-ent"
          seed_usage(ctx.metering, ent, 250)

          with {:ok, %{drawdown: :recorded, balance: %{spent: s1}}} <-
                 Reactor.run(ReportingReactor, report_inputs(ctx, "rc-report-dup", ent)),
               {:ok, %{drawdown: :duplicate, balance: %{spent: s2}}} <-
                 Reactor.run(ReportingReactor, report_inputs(ctx, "rc-report-dup", ent)) do
            violations_unless(
              "idempotency/duplicate_report_ref",
              s1 == s2,
              {:spent_moved, {s1, s2}}
            )
          else
            other -> [fail("idempotency/duplicate_report_ref", inspect(other))]
          end
        end
      }
    ]
  end

  # -- legs ---------------------------------------------------------------------

  @doc """
  Full audit of a subject family. Returns `%{checks: n, violations: [...]}`;
  a family conforms iff `violations == []`.
  """
  def audit(ctx) do
    subjects = real_subjects()

    violations =
      Enum.flat_map(subjects, &signature_leg(&1, ctx)) ++
        refusal_leg(ctx, subjects) ++
        Enum.flat_map(subjects, & &1.idempotency.(ctx)) ++
        surface_leg()

    %{
      checks: count_legs(subjects),
      violations: violations
    }
  end

  defp count_legs(subjects) do
    # one signature leg + one idempotency leg per subject, one entry per
    # refusal case, plus the single surface leg.
    length(subjects) * 2 + Enum.sum(Enum.map(subjects, &length(&1.negative))) + 1
  end

  @doc "Refusal-shape leg only — the leg the anti-vacuity probe re-runs over mutants."
  def refusal_leg(ctx, subjects \\ nil) do
    subjects = subjects || real_subjects()

    Enum.flat_map(subjects, fn subject ->
      Enum.flat_map(subject.negative, fn case_def ->
        run_negative_case(subject, case_def, ctx)
      end)
    end)
  end

  # -- internals --------------------------------------------------------------

  defp signature_leg(subject, ctx) do
    try do
      case Reactor.run(subject.module, subject.happy.(ctx)) do
        {:ok, _} -> []
        {:error, err} -> [fail("signature/#{subject.name}", inspect(err))]
      end
    rescue
      e -> [fail("signature/#{subject.name}", {:raised, Exception.message(e)})]
    end
  end

  defp run_negative_case(subject, case_def, ctx) do
    try do
      case Reactor.run(subject.module, case_def.drive.(ctx)) do
        {:ok, _} ->
          [fail("refusal/#{subject.name}/#{case_def.class}", :expected_refusal_got_ok)]

        {:error, err} ->
          text = inspect(err, limit: 50)
          needle = case_def.expect_reason |> inspect() |> String.replace("\"", "")

          violations_unless(
            "refusal/#{subject.name}/#{case_def.class}",
            text =~ to_string(case_def.expect_tag) and text =~ needle,
            {:wrong_refusal_shape, text}
          )
      end
    rescue
      e -> [fail("refusal/#{subject.name}/#{case_def.class}", {:raised, Exception.message(e)})]
    end
  end

  # -- RuntimeContract surface interop leg --------------------------------------

  defp surface_leg do
    observed_refusals = [
      {:jwt_refused, "expired"},
      {:create_account_refused, :already_exists},
      {:approve_account_refused, :not_found},
      {:run_refused, %{reason: :unknown_workflow}},
      {:invalid_total, 0}
    ]

    refusal_surface =
      Enum.flat_map(observed_refusals, fn {code, reason} ->
        refusal = Refusal.new(code, reason, :marketplace_reactors)

        cond do
          refusal.code != code or refusal.reason != reason or
              refusal.subject != :marketplace_reactors ->
            [fail("surface/refusal/#{code}", :struct_fields_drifted)]

          Refusal.tagged(refusal) != {:refused, code, reason} ->
            [fail("surface/refusal/#{code}", :tagged_shape_drifted)]

          true ->
            []
        end
      end)

    receipt =
      Receipt.new({@ent, "plan_solve-rc-wf-2"}, "CONSTRUCT", :ok, {@ent, "plan_solve-rc-wf-2"})

    replay_surface =
      case Replay.replay(receipt, fn key -> {:ok, key} end) do
        {:ok, {@ent, "plan_solve-rc-wf-2"}} -> []
        other -> [fail("surface/replay/honored", inspect(other))]
      end ++
        case Receipt.new(@ent, "CONSTRUCT", :ok, nil)
             |> Replay.replay(fn key -> {:ok, key} end) do
          {:error, {:refused, :missing_replay_key}} -> []
          other -> [fail("surface/replay/missing_key", inspect(other))]
        end

    identity = ExactSubject.identity()

    subject_family_binding =
      Enum.flat_map([:signup, :activation, :usage, :reporting], fn name ->
        subject = %{repo: identity.repo, base: identity.base, head: identity.head}

        moved = %{subject | head: "moved-head-0000000000"}

        cond do
          not ExactSubject.exact?(subject) ->
            [fail("surface/exact_subject/#{name}", :family_subject_not_exact)]

          ExactSubject.exact?(moved) ->
            [fail("surface/exact_subject/#{name}", :moved_head_accepted_as_exact)]

          true ->
            []
        end
      end)

    authority_surface =
      Enum.flat_map(
        [
          {%{action: "CONSTRUCT", policy: :marketplace_court}, :ok},
          {%{action: "DO", policy: :marketplace_court}, {:error, {:refused, :authority, "DO"}}},
          {%{policy: :marketplace_court}, {:error, {:refused, :authority, :missing_action}}}
        ],
        fn {row, expect} ->
          violations_unless(
            "surface/authority",
            AuthorityGate.authorize(row) == expect,
            {:authority, row, AuthorityGate.authorize(row)}
          )
        end
      )

    refusal_surface ++ replay_surface ++ subject_family_binding ++ authority_surface
  end

  # -- shared helpers -----------------------------------------------------------

  defp violations_unless(_check, true, _detail), do: []

  defp violations_unless(check, false, detail), do: [fail(check, detail)]

  defp fail(check, detail), do: %{check: check, status: {:fail, detail}}

  defp event_journal(ctx),
    do: AshPPlan.Sim.Marketplace.Google.ProcurementApi.event_journal(ctx.api)

  defp journal_creation_events(ctx, ent_id) do
    ctx
    |> event_journal()
    |> Enum.filter(fn e ->
      e.event_type == "ENTITLEMENT_CREATION_REQUESTED" and e.entitlement_id == ent_id
    end)
  end

  defp seed_usage(metering, ent, amount) do
    {:ok, :recorded} =
      MeteringServer.post_usage(
        metering,
        ent,
        "plan_solve-rc-report-seed",
        "plan_solve",
        amount,
        @ts
      )
  end

  def pool_id, do: @pool_id
  def pool_committed, do: @pool_committed
end
