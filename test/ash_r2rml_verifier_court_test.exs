defmodule AshR2RML.Resource.Court.Sections do
  @moduledoc false

  # Rebuilds the spec's sections with the REAL generated entity structs
  # (AshR2RML.Resource-family, defined by lib/ash_r2rml/resource.ex) so
  # ScratchTrail presents the identical section surface with `transformers: []`.

  def r2rml do
    %Spark.Dsl.Section{
      name: :r2rml,
      describe: "Semantic mapping metadata normalized into AshR2RML.Mapping",
      schema: [
        table_name: [type: :string],
        sql_query: [type: :string],
        schema: [type: :string]
      ],
      entities: [
        %Spark.Dsl.Entity{
          name: :class,
          target: AshR2RML.Dsl.Class,
          args: [:iri],
          identifier: :iri,
          schema: [
            iri: [
              type: {:or, [:string, {:list, :string}]},
              required: true,
              doc: "The RDF class IRI (or list of class IRIs) this resource maps to."
            ]
          ]
        },
        %Spark.Dsl.Entity{
          name: :subject,
          target: AshR2RML.Dsl.Subject,
          schema: [
            template: [
              type: :string,
              required: false,
              doc:
                "IRI template with {attr} interpolation, e.g. https://example.test/organization/{id}."
            ],
            column: [
              type: :atom,
              required: false,
              doc: "Attribute whose value is used verbatim as the subject IRI/identifier."
            ],
            constant: [
              type: :string,
              required: false,
              doc: "A fixed subject IRI shared by every instance."
            ],
            term_type: [
              type: {:one_of, [:iri, :blank_node]},
              required: false,
              default: :iri,
              doc: "Whether the subject is an :iri or a :blank_node."
            ]
          ]
        },
        %Spark.Dsl.Entity{
          name: :property,
          target: AshR2RML.Dsl.Property,
          args: [:attribute, :predicate_iri],
          identifier: :attribute,
          schema: [
            attribute: [
              type: :atom,
              required: true,
              doc: "The Ash resource attribute this property maps."
            ],
            predicate_iri: [type: :string, required: true, doc: "The RDF predicate IRI."],
            datatype: [
              type: :string,
              required: false,
              doc: "Explicit RDF literal datatype IRI, overriding the registry-resolved default."
            ],
            language: [
              type: :string,
              required: false,
              doc: "Fixed BCP-47 language tag for a literal (requires term_type: :literal)."
            ],
            language_column: [
              type: :atom,
              required: false,
              doc: "Attribute holding a per-row language tag."
            ],
            constant: [
              type: :string,
              required: false,
              doc: "A fixed object value shared by every instance."
            ],
            template: [
              type: :string,
              required: false,
              doc: "Object-value template with {attr} interpolation."
            ],
            term_type: [
              type: {:one_of, [:literal, :iri, :blank_node]},
              required: false,
              default: :literal,
              doc: "Whether the object is a :literal, :iri, or :blank_node."
            ]
          ]
        },
        %Spark.Dsl.Entity{
          name: :reference,
          target: AshR2RML.Dsl.Reference,
          args: [:relationship, :predicate_iri],
          identifier: :relationship,
          schema: [
            relationship: [
              type: :atom,
              required: true,
              doc: "The Ash relationship this reference follows."
            ],
            predicate_iri: [type: :string, required: true, doc: "The RDF predicate IRI."],
            inverse_predicate: [
              type: :string,
              required: false,
              doc: "Optional inverse predicate IRI."
            ],
            direction: [
              type: {:one_of, [:outgoing, :incoming]},
              required: false,
              default: :outgoing,
              doc: "Whether the predicate points :outgoing or :incoming."
            ],
            guard_class: [
              type: :string,
              required: false,
              doc: "Optional class IRI guard on the related resource."
            ]
          ]
        },
        %Spark.Dsl.Entity{
          name: :graph,
          target: AshR2RML.Dsl.Graph,
          args: [:iri],
          identifier: :iri,
          schema: [
            iri: [type: :string, required: true, doc: "The named graph IRI."],
            scope: [
              type: {:one_of, [:resource, :subject]},
              required: false,
              default: :resource,
              doc: "Whether the graph scope is per-:resource or per-:subject."
            ]
          ]
        }
      ],
      singleton_entity_keys: [:subject]
    }
  end

  def sparql do
    %Spark.Dsl.Section{
      name: :sparql,
      describe: "Declarative SPARQL query definitions compiled with the resource",
      entities: [
        %Spark.Dsl.Entity{
          name: :query,
          target: AshR2RML.Dsl.SparqlQuery,
          args: [:name],
          identifier: :name,
          schema: [
            name: [type: :atom, required: true, doc: "The query's atom name."],
            form: [
              type: {:one_of, [:select, :construct, :ask, :describe]},
              required: false,
              default: :select,
              doc: "SPARQL query form."
            ],
            select: [
              type: {:list, :atom},
              required: false,
              default: [],
              doc: "Selected variables for a :select query."
            ],
            where: [type: :any, required: false, default: [], doc: "WHERE-clause pattern data."]
          ]
        }
      ]
    }
  end
end

defmodule AshR2RML.Resource.Court.ScratchTrail do
  @moduledoc false

  # Same surface, no transformers: the REAL AshR2RML.Resource.Verify must still
  # refuse anything compiled under it, because nothing persists
  # :ash_r2rml_compiled.
  use Spark.Dsl.Extension,
    sections: [
      AshR2RML.Resource.Court.Sections.r2rml(),
      AshR2RML.Resource.Court.Sections.sparql()
    ],
    transformers: [],
    verifiers: [AshR2RML.Resource.Verify]
end

defmodule AshR2RML.Resource.Court.Dsl do
  @moduledoc false

  use Spark.Dsl, default_extensions: [extensions: [AshR2RML.Resource]]
end

defmodule AshR2RML.Resource.Court.ScratchDsl do
  @moduledoc false

  use Spark.Dsl, default_extensions: [extensions: [AshR2RML.Resource.Court.ScratchTrail]]
end

defmodule AshR2RML.ResourceVerifierCourtTest do
  use ExUnit.Case, async: false

  @specimen_dir Path.join(File.cwd!(), "fixture/malformed_specimens")
  @verifiers []

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
    use AshR2RML.Resource.Court.Dsl

    r2rml do
    end
    sparql do
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
        |> String.replace("Court.ScratchDsl", "AshR2RML.Resource.Court.ScratchDsl")
        |> String.replace("Court.Dsl", "AshR2RML.Resource.Court.Dsl")

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
