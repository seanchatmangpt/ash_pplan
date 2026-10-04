defmodule AshPPlan.Sim.Marketplace.Reactors.ContractCourts.MutantSubjects do
  @moduledoc """
  Anti-vacuity corpus for the RuntimeContract reactors court: mutant subject
  modules defined IN MEMORY (runtime `defmodule`, no file edits) whose
  refusal shape is corrupted. The court's refusal-shape leg MUST fail over
  this family; if it passes, the court carries no bits.

  Mutants:

    * `MutantSignupCrashReactor` — verify_jwt RAISES instead of returning a
      typed refusal (crash-shaped subject);
    * `MutantSignupUntaggedReactor` — verify_jwt returns a bare-string
      refusal with no `{tag, reason}` typed shape.
  """

  alias AshPPlan.Sim.Marketplace.Reactors.ContractCourts.Drivers

  @aud "marketplace"

  def signup_crash_mutant do
    defmodule AshPPlan.Sim.Marketplace.Reactors.ContractCourts.MutantSignupCrashReactor do
      @moduledoc "Mutant: refusal shape corrupted into a bare raise."
      use Reactor

      input :portal
      input :api
      input :jwt
      input :now
      input :aud
      input :account_id
      input :entitlement_id

      step :verify_jwt do
        argument :portal, input(:portal)
        argument :jwt, input(:jwt)
        argument :now, input(:now)
        argument :aud, input(:aud)

        run fn %{jwt: jwt}, _context ->
          :erlang.put({MutantSignupCrashReactor, :fired}, jwt)
          raise "untyped crash: refusal shape corrupted"
        end
      end

      return :verify_jwt
    end

    AshPPlan.Sim.Marketplace.Reactors.ContractCourts.MutantSignupCrashReactor
  end

  def signup_untagged_mutant do
    defmodule AshPPlan.Sim.Marketplace.Reactors.ContractCourts.MutantSignupUntaggedReactor do
      @moduledoc "Mutant: refusal shape corrupted into a bare untagged string."
      use Reactor

      input :portal
      input :api
      input :jwt
      input :now
      input :aud
      input :account_id
      input :entitlement_id

      step :verify_jwt do
        argument :portal, input(:portal)
        argument :jwt, input(:jwt)
        argument :now, input(:now)
        argument :aud, input(:aud)

        run fn %{jwt: jwt}, _context ->
          :erlang.put({MutantSignupUntaggedReactor, :fired}, jwt)
          {:error, "total payload destruction: no typed tag anywhere"}
        end
      end

      return :verify_jwt
    end

    AshPPlan.Sim.Marketplace.Reactors.ContractCourts.MutantSignupUntaggedReactor
  end

  @doc """
  Mutant subject family in the engine's entry shape: signup-shaped entries
  sharing the real family's drive (expired-JWT poisoned input class) but
  whose declared tag the corrupt step can no longer produce.
  """
  def subjects do
    crash = signup_crash_mutant()
    untagged = signup_untagged_mutant()

    [
      %{
        name: :signup_mutant_crash,
        module: crash,
        negative: [
          %{
            class: :expired_jwt,
            expect_tag: :jwt_refused,
            expect_reason: :expired,
            drive: fn ctx ->
              {:ok, token} = Drivers.issue(ctx, sub: "rc-mutant-1", aud: @aud, exp_seconds: -60)
              Drivers.signup_inputs(ctx, "rc-mutant-1", token)
            end
          }
        ]
      },
      %{
        name: :signup_mutant_untagged,
        module: untagged,
        negative: [
          %{
            class: :expired_jwt,
            expect_tag: :jwt_refused,
            expect_reason: :expired,
            drive: fn ctx ->
              {:ok, token} = Drivers.issue(ctx, sub: "rc-mutant-2", aud: @aud, exp_seconds: -60)
              Drivers.signup_inputs(ctx, "rc-mutant-2", token)
            end
          }
        ]
      }
    ]
  end
end
