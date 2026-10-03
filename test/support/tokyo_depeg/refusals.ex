defmodule AshPPlan.Test.TokyoDepeg.Refusals do
  @moduledoc """
  The CLOSED refusal vocabulary for the Tokyo depeg surface.

  Before this module the surface had three uncoordinated families:

    * `AshPplan.TokyoDepeg.Alignment` atoms (`:empty_model`,
      `:lifecycle_*`, `:permissive_model`)
    * `RevocationSupport.refusal_class/1` strings
      (`"REFUSED_AUTHORITY_REVOKED"`, `"REFUSED_NO_SUCH_RUN"`,
      plus an OPEN-class catch-all `"REFUSED(class=...)"`)
    * the production `AshPPlan.SA2A.Refusal` codes (atoms)

  Every `{:refused, _}` verdict and every `refusal_class` string emitted on
  this surface must be a member of `codes/0` — `hardening_test.exs` holds
  that line. The open-class catch-all remains on `RevocationSupport` for
  engine refusals that have no scenario name yet; it is intentionally NOT a
  member of the closed set, so a refusal only ever exits the open class by
  being added here under a scenario name.
  """

  @typedoc "Closed-set members, keyed by family."

  # Elixir typespecs do not accept string-literal types; the closed set itself is
  # defined by @codes below (alignment atoms + revocation strings + SA2A codes).
  @type code :: atom() | String.t()

  @alignment_codes [
    :empty_model,
    :permissive_model,
    :lifecycle_sanctions_omitted,
    :lifecycle_order_violation,
    :lifecycle_unmodelled_activity
  ]

  @revocation_strings ["REFUSED_AUTHORITY_REVOKED", "REFUSED_NO_SUCH_RUN"]

  @burn_in_strings [
    "REFUSED_DUPLICATE_EFFECT",
    "REFUSED_CONFORMANCE_DEVIATION",
    "REFUSED_LEASE_EXPIRED"
  ]

  @sa2a_codes AshPPlan.SA2A.Refusal.codes()

  @codes @alignment_codes ++ @revocation_strings ++ @burn_in_strings ++ @sa2a_codes

  @doc "The closed set, every member tagged with its family."
  @spec codes() :: [code(), ...]
  def codes, do: @codes

  @doc "Family of a code: `:alignment` | `:revocation` | `:burn_in` | `:sa2a` | nil (not a member)."
  @spec family(term()) :: :alignment | :revocation | :burn_in | :sa2a | nil
  def family(code) when code in @alignment_codes, do: :alignment
  def family(code) when code in @burn_in_strings, do: :burn_in
  def family(code) when code in @revocation_strings, do: :revocation
  def family(code) when code in @sa2a_codes, do: :sa2a
  def family(_), do: nil

  @doc "Membership."
  @spec in?(term()) :: boolean()
  def in?(code), do: family(code) != nil
end
