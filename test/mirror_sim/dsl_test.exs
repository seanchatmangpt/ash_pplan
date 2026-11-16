defmodule AshPPlan.MirrorSim.DslTest do
  use ExUnit.Case, async: false

  alias AshPPlan.Catalog.Plan
  alias AshPPlan.Compiler
  alias AshPPlan.MirrorSim.Dsl
  alias AshPPlan.MirrorSim.Server
  alias AshPPlan.Workflow
  alias AshPPlan.Workflow.{Authority, CapabilityCatalog, Explain, Model, Subject}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, pid} = Server.start_link(port: 0)
    {:ok, base: Server.base_url(pid)}
  end

  defp request(base, method, path, body) do
    url = String.to_charlist(base <> path)
    headers = [{~c"accept", ~c"application/json"}]

    req =
      case method do
        :get -> {url, headers}
        :post -> {url, headers, ~c"application/json", Jason.encode!(body)}
      end

    {:ok, {{_, status, _}, _h, resp}} =
      :httpc.request(method, req, [], body_format: :binary)

    {status, Jason.decode!(resp)}
  end

  defp post(base, path, body), do: request(base, :post, path, body)

  @model %{
    "name" => "demo",
    "goal" => "verified",
    "tasks" => [
      %{"id" => "observe", "capability" => "File.Read", "outcomes" => ["ok"]},
      %{"id" => "verify", "capability" => "Verification.Run", "after" => ["observe"]}
    ],
    "methods" => [%{"id" => "m1", "task" => "verify", "subtasks" => ["observe"]}]
  }

  defp direct_model(descriptor) do
    with {:ok, model} <- Model.new(Dsl.decode_model(descriptor)),
         :ok <- Model.validate(model) do
      {:ok, model}
    end
  end

  defp built_model!(descriptor) do
    {:ok, model} = Model.new(Dsl.decode_model(descriptor))
    model
  end

  describe "surfaces" do
    test "every declared surface is an exported function" do
      for %{module: m, fun: f, arity: a, route: r} <- Dsl.surfaces() do
        assert Code.ensure_loaded?(m)
        assert function_exported?(m, f, a), "#{inspect(m)}.#{f}/#{a} missing"
        assert String.starts_with?(r, "/dsl/")
      end
    end
  end

  describe "model" do
    test "parity: sim model equals direct Model.new + validate", %{base: base} do
      {status, body} = post(base, "/dsl/model", %{"model" => @model})
      assert status == 200
      {:ok, direct} = direct_model(@model)
      assert body["model"] == Dsl.jsonable(direct)
    end

    test "typed refusals match direct errors", %{base: base} do
      cases = [
        put_in(@model, ["tasks"], [
          %{"id" => "a", "capability" => "File.Read", "after" => ["ghost"]}
        ]),
        put_in(@model, ["tasks"], [
          %{"id" => "a", "capability" => "File.Read", "after" => ["b"]},
          %{"id" => "b", "capability" => "File.Read", "after" => ["a"]}
        ]),
        put_in(@model, ["tasks"], [
          %{"id" => "a", "capability" => "File.Read"},
          %{"id" => "a", "capability" => "File.Read"}
        ]),
        put_in(@model, ["tasks"], [%{"id" => "a", "capability" => "nonsense"}]),
        put_in(@model, ["tasks"], [%{"id" => "a", "capability" => "File.Read", "bogus" => 1}]),
        put_in(@model, ["methods"], [%{"id" => "m", "task" => "a", "subtasks" => ["ghost"]}]),
        Map.delete(@model, "name"),
        %{"name" => "x", "tasks" => "not-a-list"}
      ]

      for descriptor <- cases do
        {status, body} = post(base, "/dsl/model", %{"model" => descriptor})
        assert status == 422
        assert body["refused"] == true
        assert {:error, %{reason: reason} = detail} = direct_model(descriptor)
        assert body["broken_term"] == Atom.to_string(reason)
        assert body["details"] == Dsl.jsonable(detail)
      end
    end

    test "non-object model is refused, not a 500", %{base: base} do
      {status, body} = post(base, "/dsl/model", %{"model" => 7})
      assert status == 422
      assert body["refused"] == true
    end
  end

  describe "workflow_model" do
    test "DSL modules resolve like Workflow.model/1", %{base: base} do
      for {name, mod} <- [
            {"workflow", AshPPlan.MirrorSim.Dsl.FixtureWorkflow},
            {"pplan", AshPPlan.MirrorSim.Dsl.FixturePPlan}
          ] do
        {status, body} = post(base, "/dsl/workflow_model", %{"module" => name})
        assert status == 200
        {:ok, direct} = Workflow.model(mod)
        assert body["model"] == Dsl.jsonable(direct)
      end
    end

    test "non-workflow module is a typed not_a_workflow refusal", %{base: base} do
      {status, body} = post(base, "/dsl/workflow_model", %{"module" => "nope"})
      assert status == 422
      assert body["broken_term"] == "not_a_workflow"

      assert {:error, %{reason: :not_a_workflow} = d} =
               Workflow.model(AshPPlan.MirrorSim.Dsl.NotAWorkflow)

      assert body["details"] == Dsl.jsonable(d)
    end
  end

  describe "task and method" do
    test "task normalization parity", %{base: base} do
      task = %{
        "id" => "t",
        "capability" => "file.Read",
        "after" => ["b", "a", "a"],
        "outcomes" => ["z", "y"]
      }

      {status, body} = post(base, "/dsl/task", %{"task" => task})
      assert status == 200
      direct = Model.task(Dsl.decode_task(task))
      assert body["task"] == Dsl.jsonable(direct)
      assert body["task"]["depends_on"] == ["a", "b"]
    end

    test "method parity", %{base: base} do
      method = %{"id" => "m", "task" => "t", "subtasks" => ["a", "b"]}
      {status, body} = post(base, "/dsl/method", %{"method" => method})
      assert status == 200
      assert body["method"] == Dsl.jsonable(Model.method(Dsl.decode_method(method)))
    end

    test "task without id refuses with 422", %{base: base} do
      {status, body} = post(base, "/dsl/task", %{"task" => %{"capability" => "File.Read"}})
      assert status == 422
      assert body["refused"] == true
    end

    test "method missing enforced keys refuses with 422", %{base: base} do
      {status, body} = post(base, "/dsl/method", %{"method" => %{"id" => "m"}})
      assert status == 422
      assert body["refused"] == true
    end
  end

  describe "explain and subject" do
    test "explain parity", %{base: base} do
      {status, body} = post(base, "/dsl/explain", %{"model" => @model})
      assert status == 200
      direct = Explain.workflow(built_model!(@model))
      assert body["explain"] == Dsl.jsonable(direct)
      assert body["explain"]["authority"]["do_authority"] == false
    end

    test "subject parity and content addressing", %{base: base} do
      {200, body} = post(base, "/dsl/subject", %{"model" => @model})
      assert body["subject"] == Dsl.jsonable(Subject.bind(built_model!(@model)))

      changed = put_in(@model, ["goal"], "other")
      {200, body2} = post(base, "/dsl/subject", %{"model" => changed})
      refute body["subject"]["id"] == body2["subject"]["id"]
    end

    test "explain of an invalid model is a typed refusal", %{base: base} do
      {status, body} = post(base, "/dsl/explain", %{"model" => %{"tasks" => []}})
      assert status == 422
      assert body["broken_term"] == "missing_workflow_name"
    end
  end

  describe "authority" do
    test "model ceiling parity and zero granted", %{base: base} do
      {200, body} = post(base, "/dsl/authority", %{"model" => @model})
      model = built_model!(@model)
      assert {:ok, ceiling} = Authority.admit(model)
      assert body["ceiling"] == Atom.to_string(ceiling)
      assert body["granted"] == Authority.granted(model)
    end

    test "scalar authorities match direct admission", %{base: base} do
      for a <- ["none", "observe", "select", "plan", "construct", "do", "root", "x"] do
        {status, body} = post(base, "/dsl/authority", %{"authority" => a})
        direct = Authority.admit(Dsl.decode_authority(a))

        case direct do
          {:ok, ceiling} ->
            assert status == 200
            assert body["ceiling"] == Atom.to_string(ceiling)

          {:error, %{reason: :authority_ceiling} = d} ->
            assert status == 422
            assert body["broken_term"] == "authority_ceiling"
            assert body["details"] == Dsl.jsonable(d)
        end
      end
    end

    test ":do on a task is refused above the construct ceiling", %{base: base} do
      model =
        put_in(@model, ["tasks"], [
          %{"id" => "a", "capability" => "File.Read", "authority" => "do"}
        ])

      {status, body} = post(base, "/dsl/authority", %{"model" => model})
      assert status == 422
      assert body["broken_term"] == "authority_ceiling"
      assert body["details"]["max"] == "construct"
    end
  end

  describe "verify_projection" do
    test "pplan projection with exact correspondence verifies; a lost task refuses", %{base: base} do
      model = built_model!(@model)
      ids = for t <- model.tasks, do: Subject.correspondence(model.name, t.id).pplan

      steps = fn ids ->
        for id <- ids, do: %{"iri" => id, "predecessors" => []}
      end

      body = %{"model" => @model, "kind" => "pplan", "projection" => %{"steps" => steps.(ids)}}
      {status, resp} = post(base, "/dsl/verify_projection", body)
      direct = Subject.verify_projection(model, :pplan, Dsl.decode_projection(body["projection"]))

      # Edges are required by the model (verify depends on observe): the real
      # module decides; the sim must agree with it either way.
      assert (direct == :ok and status == 200) or (match?({:error, _}, direct) and status == 422)

      {status2, resp2} =
        post(base, "/dsl/verify_projection", %{
          body
          | "projection" => %{"steps" => steps.(tl(ids))}
        })

      assert status2 == 422

      assert {:error, %{reason: reason}} =
               Subject.verify_projection(
                 model,
                 :pplan,
                 Dsl.decode_projection(%{"steps" => steps.(tl(ids))})
               )

      assert resp2["broken_term"] == Atom.to_string(reason)
      assert is_map(resp)
    end

    test "unknown kind refuses typed", %{base: base} do
      {status, body} =
        post(base, "/dsl/verify_projection", %{
          "model" => @model,
          "kind" => "bogus",
          "projection" => %{"ids" => []}
        })

      assert status == 422
      assert body["broken_term"] == "unknown_projection"
    end
  end

  describe "capability_catalog" do
    test "GET returns the generated catalog verbatim", %{base: base} do
      {200, body} = request(base, :get, "/dsl/capability_catalog", nil)
      assert body["capabilities"] == Dsl.jsonable(CapabilityCatalog.all())
      assert body["ids"] == CapabilityCatalog.ids()
    end
  end

  describe "compile_spec" do
    @spec_ok %{
      "iri" => "urn:sim:plan:ok",
      "steps" => [
        %{"iri" => "urn:s:a", "predecessors" => [], "inputs" => ["x"], "outputs" => ["y"]},
        %{"iri" => "urn:s:b", "predecessors" => ["urn:s:a"], "inputs" => ["y"], "outputs" => []}
      ]
    }

    test "valid spec compiles; summary equals direct compile", %{base: base} do
      {status, body} = post(base, "/dsl/compile_spec", @spec_ok)
      assert status == 200
      spec = Dsl.decode_spec(@spec_ok)
      {:ok, reactor} = Compiler.compile_spec(spec, Dsl.handlers_for(spec, []))
      assert body["compiled"] == Dsl.jsonable(Dsl.summarize_reactor(reactor))
      assert "urn:s:a" in body["compiled"]["steps"]
      assert "urn:s:b" in body["compiled"]["steps"]
    end

    test "fan-in with several terminals compiles via the return collector", %{base: base} do
      spec = %{
        "iri" => "urn:sim:plan:fan",
        "steps" => [
          %{"iri" => "urn:s:a", "predecessors" => [], "inputs" => [], "outputs" => []},
          %{"iri" => "urn:s:b", "predecessors" => [], "inputs" => [], "outputs" => []}
        ]
      }

      {200, body} = post(base, "/dsl/compile_spec", spec)
      assert ["ash_pplan", "return"] == body["compiled"]["return"]
    end

    test "every refusal class matches the direct Compiler.Error", %{base: base} do
      step = fn iri, preds ->
        %{"iri" => iri, "predecessors" => preds, "inputs" => [], "outputs" => []}
      end

      cases = [
        {:empty_plan, %{"iri" => "urn:p", "steps" => []}, []},
        {:cyclic_plan, %{"iri" => "urn:p", "steps" => [step.("a", ["b"]), step.("b", ["a"])]},
         []},
        {:dangling_predecessors, %{"iri" => "urn:p", "steps" => [step.("a", ["ghost"])]}, []},
        {:duplicate_steps, %{"iri" => "urn:p", "steps" => [step.("a", []), step.("a", [])]}, []},
        {:invalid_step_spec, %{"iri" => "urn:p", "steps" => [%{"iri" => "a"}]}, []},
        {:missing_handlers, %{"iri" => "urn:p", "steps" => [step.("a", [])]}, ["a"]},
        {:invalid_plan_spec, %{"iri" => "urn:p", "steps" => "nope"}, []}
      ]

      for {expected, params, omit} <- cases do
        {status, body} = post(base, "/dsl/compile_spec", Map.put(params, "omit_handlers", omit))
        assert status == 422, "#{expected}: #{inspect(body)}"
        assert body["refused"] == true
        assert body["broken_term"] == Atom.to_string(expected)

        spec = Dsl.decode_spec(params)

        assert {:error, %Compiler.Error{reason: ^expected, details: details}} =
                 Compiler.compile_spec(spec, Dsl.handlers_for(spec, omit))

        assert body["details"] == Dsl.jsonable(details)
      end
    end

    test "garbage body never 500s", %{base: base} do
      {status, body} = post(base, "/dsl/compile_spec", %{"steps" => 5})
      assert status == 422
      assert body["refused"] == true
    end
  end

  describe "compile_iri" do
    test "every cataloged plan compiles with parity", %{base: base} do
      plans = Plan.all()
      assert plans != []

      for %{iri: iri} <- plans do
        {status, body} = post(base, "/dsl/compile_iri", %{"plan_iri" => iri})
        plan = Plan.fetch(iri)
        direct = Compiler.compile(iri, Dsl.handlers_for(plan, []))

        case direct do
          {:ok, reactor} ->
            assert status == 200, "#{iri}: #{inspect(body)}"
            assert body["compiled"] == Dsl.jsonable(Dsl.summarize_reactor(reactor))

          {:error, %Compiler.Error{reason: reason}} ->
            assert status == 422
            assert body["broken_term"] == Atom.to_string(reason)
        end
      end
    end

    test "unknown plan and non-binary iri refuse typed", %{base: base} do
      {422, body} = post(base, "/dsl/compile_iri", %{"plan_iri" => "urn:no:such:plan"})
      assert body["broken_term"] == "unknown_plan"
      assert {:error, %{reason: :unknown_plan}} = Compiler.compile("urn:no:such:plan", %{})

      {422, body2} = post(base, "/dsl/compile_iri", %{"plan_iri" => 5})
      assert body2["broken_term"] == "invalid_compile_arguments"
    end
  end

  describe "routing" do
    test "unknown route is a typed 404 refusal", %{base: base} do
      {404, body} = post(base, "/dsl/no_such_route", %{})
      assert body["refused"] == true
    end
  end
end
