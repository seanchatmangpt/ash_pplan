defmodule AshPPlan.MirrorSim.KillSA2ATest do
  use ExUnit.Case, async: false

  alias AshPPlan.SA2A.{Replay, SubjectGuard}

  # SA-01: empty-binary subject must be refused (mutant drops `subject != ""`).
  test "SA-01 empty binary subject is refused as missing_subject" do
    assert {:error, %{code: :missing_subject, authority: :none}} =
             SubjectGuard.fetch(%{subject: ""})

    assert {:ok, "caller"} = SubjectGuard.fetch(%{subject: "caller"})
  end

  # SA-02: nil subject must be refused (mutant drops `not is_nil`).
  test "SA-02 nil subject is refused as missing_subject" do
    assert {:error, %{code: :missing_subject}} = SubjectGuard.fetch(%{subject: nil})
    assert {:ok, :caller} = SubjectGuard.fetch(%{subject: :caller})
  end

  # SA-04: drift refusal carries authority :none (mutant: :construct).
  test "SA-04 subject drift refusal has authority :none" do
    assert {:error, %{code: :planner_refused, authority: authority, detail: detail}} =
             SubjectGuard.preserve("a", %{subject: "b"})

    assert authority == :none
    assert detail == {:subject_drift, "a", "b"}
  end

  # SA-10: drifted/absent candidate subject is refused before any other check
  # (mutant `_ -> :ok` lets it fall through to :missing_domain).
  test "SA-10 drifted candidate subject is refused as subject_drift" do
    request = %{subject: "a"}

    assert {:error, %{code: :planner_refused, detail: {:subject_drift, "a", "b"}}} =
             Replay.fond(request, %{subject: "b"})

    assert {:error, %{code: :missing_subject}} = Replay.fond(request, %{})
  end

  # SA-11: non-keyword list opts are refused (mutant accepts them, then fails
  # later with :missing_domain on this domainless request).
  test "SA-11 garbage list opts are refused as invalid_opts" do
    request = %{subject: "a"}

    assert {:error, %{code: :planner_refused, detail: {:invalid_opts, [1, 2]}}} =
             Replay.fond(request, %{subject: "a"}, [1, 2])
  end
end
