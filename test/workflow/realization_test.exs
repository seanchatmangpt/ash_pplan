defmodule AshPPlan.RealizationTest do
  use ExUnit.Case, async: true
  alias AshPPlan.Realization

  test "op_for downcases and underscores the capability id" do
    assert Realization.op_for("File.Write") == :file_write
    assert Realization.op_for("Remote.Read") == :remote_read
  end

  test "from_map builds a valid binding from adapter/operation keys" do
    r =
      Realization.from_map(
        %{
          provider: :file,
          adapter: :reactor_file,
          operation: :file_write,
          options: [revert_on_undo?: true]
        },
        "File.Write"
      )

    assert r.binding == %{adapter: :reactor_file, op: :file_write}
    assert r.options == [revert_on_undo?: true]
    assert :ok = Realization.validate(r)
  end

  test "legacy step map is refused, never re-bound" do
    r = Realization.from_map(%{provider: :x, step: SomeMod}, "Work.Observe")
    assert r.binding == nil
    assert {:error, {:invalid_binding, nil}} = Realization.validate(r)

    assert {:error, {:invalid_binding, nil}} =
             Realization.new(%{provider: :x, step: SomeMod}, "Work.Observe")
  end

  test "binding with unknown adapter or mismatched op is rejected" do
    bad = %Realization{
      capability: "File.Write",
      provider: :f,
      binding: %{adapter: :nope, op: :file_write}
    }

    assert {:error, {:invalid_binding, {:unknown_adapter, :nope}}} = Realization.validate(bad)
    bad = %{bad | binding: %{adapter: :reactor_file, op: :file_read}}

    assert {:error, {:invalid_binding, {:op_mismatch, :file_read, :file_write}}} =
             Realization.validate(bad)

    assert {:error, {:invalid_binding, nil}} = Realization.validate(%{bad | binding: nil})
    assert {:error, _} = Realization.new(%{provider: :f, adapter: :nope, op: :x}, "File.Write")
  end
end
