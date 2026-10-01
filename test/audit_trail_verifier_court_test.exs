defmodule AuditTrail.Resource.Court.Sections do
  @moduledoc false

  # Rebuilds the spec's sections with the REAL generated entity structs
  # (AuditTrail.Resource-family, defined by lib/audit_trail/resource.ex) so
  # ScratchTrail presents the identical section surface with `transformers: []`.

  def audit do
    %Spark.Dsl.Section{
      name: :audit,
      entities: [
        %Spark.Dsl.Entity{
          name: :event,
          target: AuditTrail.Dsl.Event,
          schema: [
            name: [type: :atom, required: true, doc: "The audited event's slug."],
            description: [
              type: :string,
              required: false,
              doc: "Human-readable description of what triggers this event."
            ]
          ]
        },
        %Spark.Dsl.Entity{
          name: :projection,
          target: AuditTrail.Dsl.Projection,
          schema: [
            attribute: [
              type: :atom,
              required: true,
              doc: "Resource attribute this projection reads."
            ]
          ]
        }
      ]
    }
  end
end

defmodule AuditTrail.Resource.Court.ScratchTrail do
  @moduledoc false

  # Same surface, no transformers: the REAL AuditTrail.Resource.Verify must still
  # refuse anything compiled under it, because nothing persists
  # :audit_trail_compiled.
  use Spark.Dsl.Extension,
    sections: [AuditTrail.Resource.Court.Sections.audit()],
    transformers: [],
    verifiers: [AuditTrail.Resource.Verify]
end

defmodule AuditTrail.Resource.Court.Dsl do
  @moduledoc false

  use Spark.Dsl, default_extensions: [extensions: [AuditTrail.Resource]]
end

defmodule AuditTrail.Resource.Court.ScratchDsl do
  @moduledoc false

  use Spark.Dsl, default_extensions: [extensions: [AuditTrail.Resource.Court.ScratchTrail]]
end

defmodule AuditTrail.ResourceVerifierCourtTest do
  use ExUnit.Case, async: false

  @specimen_dir Path.join(File.cwd!(), "fixture/malformed_specimens")
  @verifiers ["unique_event_name", "valid_projection"]

  @specimens @specimen_dir
             |> Path.join("*.ex")
             |> Path.wildcard()
             |> Enum.sort()
             |> Enum.map(fn path ->
               source = File.read!(path)

               meta = fn key ->
                 case Regex.run(~r/^# #{key}: (.*)$/m, source) do
                   [_, value] -> String.trim(value)
                   nil -> nil
                 end
               end

               %{
                 path: path,
                 name: path |> Path.basename(".ex"),
                 source: source,
                 verifier: meta.("VERIFIER"),
                 expect_raise: meta.("EXPECT-RAISE"),
                 expect_message: meta.("EXPECT-MESSAGE"),
                 scratch?: match?({:ok, _}, Regex.run(~r/use Court.ScratchDsl/, source))
               }
             end)

  # -- happy-path guard: the extension itself must accept a legal module, so any
  # -- specimen failure below is attributable to the refusal condition, not to a
  # -- broken extension render.
  @happy_path_source """
  defmodule Court.HappyPath do
    use AuditTrail.Resource.Court.Dsl

    audit do
    end
    end
  """

  test "court is non-vacuous: specimens exist and cover declared verifiers" do
    refute @specimens == [],
           "no malformed specimens found in #{@specimen_dir} -- an empty court proves nothing"

    refute @verifiers == [],
           "spec declares no aex:Verifier rows -- nothing for the court to close"

    witnessed = Enum.map(@specimens, & &1.verifier)

    missing =
      Enum.reject(witnessed, fn v ->
        v in @verifiers or
          v in [
            "persist_before_verify",
            "verify_section_singleton_entities",
            "section_surface",
            "entity_surface"
          ]
      end)

    assert missing == [],
           "specimens witness unknown verifier(s): #{inspect(missing)} -- declared verifiers: #{inspect(@verifiers)}"
  end

  test "happy path: a legal module compiles against the real extension" do
    {mods, diagnostics} =
      Code.with_diagnostics(fn ->
        Code.compile_string(@happy_path_source)
      end)

    assert Enum.any?(mods, &match?({Court.HappyPath, _}, &1)),
           "the legal happy-path module failed to compile -- the extension render itself is broken, so any specimen refusal would be unattributable"

    error_diagnostics = Enum.filter(diagnostics, &(&1.severity == :error))

    assert error_diagnostics == [],
           "the legal happy-path module produced compiler error diagnostics: #{inspect(error_diagnostics)}"
  end

  test "every malformed specimen is refused by the real generated verifier" do
    Enum.each(@specimens, fn specimen ->
      source =
        specimen.source
        |> String.split("\n")
        |> Enum.reject(&String.starts_with?(&1, "#"))
        |> Enum.join("\n")
        |> String.replace("Court.ScratchDsl", "AuditTrail.Resource.Court.ScratchDsl")
        |> String.replace("Court.Dsl", "AuditTrail.Resource.Court.Dsl")

      # Elixir 1.19+ hazards: a Spark verifier raising inside the parallel checker
      # can surface as a swallowed warning with a SUCCESSFUL compile. The court
      # therefore treats a refusal as: a real raise OR a captured compiler
      # diagnostic carrying the specimen's EXPECT-MESSAGE substring. A clean
      # compile with no matching diagnostic = vacuous verifier.
      {outcome, diagnostics} =
        Code.with_diagnostics(fn ->
          try do
            Code.compile_string(source)
            :compiled_clean
          rescue
            e -> {:raised, e.__struct__ |> Module.split() |> Enum.join("."), Exception.message(e)}
          end
        end)

      case outcome do
        {:raised, kind, message} ->
          matched? =
            String.contains?(message, specimen.expect_message) or
              Enum.any?(diagnostics, fn d ->
                d.severity in [:error, :warning] and
                  String.contains?(d.message, specimen.expect_message)
              end)

          assert kind == specimen.expect_raise and matched?,
                 "specimen #{specimen.name}: expected #{specimen.expect_raise} matching \"#{specimen.expect_message}\", " <>
                   "got #{kind}: #{message}"

        :compiled_clean ->
          diagnostic =
            Enum.find(diagnostics, fn d ->
              d.severity in [:error, :warning] and
                String.contains?(d.message, specimen.expect_message)
            end)

          unless diagnostic do
            flunk(
              "VACUOUS VERIFIER #{specimen.verifier || "?"}: specimen #{specimen.name} " <>
                "(#{specimen.path}) compiled CLEANLY with no matching refusal diagnostic -- " <>
                "refusal condition never fires, so the verifier carries no bits. " <>
                "Expected raise #{specimen.expect_raise} matching \"#{specimen.expect_message}\". " <>
                "Captured diagnostics: #{inspect(Enum.map(diagnostics, &{&1.severity, String.slice(&1.message, 0, 120)}))}"
            )
          end
      end
    end)
  end
end
