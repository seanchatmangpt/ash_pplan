defmodule AshPPlan.SA2A.SubjectGuardTest do
  use ExUnit.Case, async: true

  alias AshPPlan.SA2A.SubjectGuard

  test "candidate must preserve caller exact subject" do
    assert {:ok, %{subject: "sha256:s"}} =
             SubjectGuard.preserve("sha256:s", %{subject: "sha256:s"})

    assert {:error, %{detail: {:subject_drift, "sha256:s", "sha256:other"}}} =
             SubjectGuard.preserve("sha256:s", %{subject: "sha256:other"})
  end

  test "missing subject is refused" do
    assert {:error, %{code: :missing_subject}} = SubjectGuard.fetch(%{})
  end
end
