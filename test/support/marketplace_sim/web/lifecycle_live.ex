defmodule AshPPlan.MarketplaceSim.TTL do
  @moduledoc false

  @ttl_path Path.expand("../lifecycle_plan.ttl", __DIR__)

  # Compile-time SPARQL helpers. A nested module compiles before the outer
  # module body evaluates, so the outer module's attribute computations can
  # call these (bare defp/defs of the outer module cannot be called during
  # its own compilation).

  def graph, do: RDF.Turtle.read_file!(@ttl_path)
  def text, do: File.read!(@ttl_path)

  def solutions!(graph, qs) do
    prefixes = ~S(
      PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
      PREFIX prov: <http://www.w3.org/ns/prov#>
      PREFIX p-plan: <http://purl.org/net/p-plan#>
      PREFIX gcp: <https://cloud.google.com/marketplace/ontology/v1#>
    )

    case SPARQL.execute_query(graph, prefixes <> qs) do
      %SPARQL.Query.Result{results: solutions} -> solutions
    end
  end

  def list_prop(graph, iri, prop) do
    solutions!(graph, "SELECT ?x WHERE { <#{iri}> #{prop} ?x }")
    |> Enum.map(&local_name(&1["x"]))
  end

  def local_name(iri), do: iri |> to_string() |> String.split("#") |> List.last()
end

defmodule AshPPlan.MarketplaceSim.LifecycleLive do
  @moduledoc """
  GCP Marketplace P-Plan lifecycle explorer, adapted from a single-file PETAL
  app into a real tested LiveView over `test/support/marketplace_sim/lifecycle_plan.ttl`.

  Steps, variables, agents and organizations are extracted from the TTL with
  RDF.Turtle + SPARQL at compile time. The prose layer (step summaries, risk
  notes, avatar descriptions, domain grouping) is not in the TTL; it is kept
  as module attributes keyed by IRI local name, mirroring the original app.

  Chart choice: burn-down curves are rendered as a server-side inline SVG
  polyline (12-point linear model) — no Chart.js / external CDN, so the view
  is fully hermetic under LiveViewTest.
  """

  use Phoenix.LiveView

  import PetalComponents.Card, only: [card: 1]
  import PetalComponents.Badge, only: [badge: 1]

  @graph AshPPlan.MarketplaceSim.TTL.graph()
  @ttl_text AshPPlan.MarketplaceSim.TTL.text()

  # -- static extraction -------------------------------------------------------

  @steps (for sol <-
                AshPPlan.MarketplaceSim.TTL.solutions!(
                  @graph,
                  "SELECT ?step ?label WHERE { ?step a p-plan:Step ; rdfs:label ?label }"
                ),
              %{"step" => step_iri, "label" => label} = sol do
            id = AshPPlan.MarketplaceSim.TTL.local_name(step_iri)

            inputs = AshPPlan.MarketplaceSim.TTL.list_prop(@graph, step_iri, "p-plan:hasInputVar")

            outputs =
              AshPPlan.MarketplaceSim.TTL.list_prop(@graph, step_iri, "p-plan:hasOutputVar")

            agents =
              AshPPlan.MarketplaceSim.TTL.list_prop(@graph, step_iri, "prov:wasAssociatedWith")

            preceded_by =
              AshPPlan.MarketplaceSim.TTL.list_prop(@graph, step_iri, "p-plan:isPrecededBy")

            %{
              id: id,
              label: to_string(label),
              inputs: inputs,
              outputs: outputs,
              agents: agents,
              preceded_by: preceded_by
            }
          end)

  @variables AshPPlan.MarketplaceSim.TTL.solutions!(
               @graph,
               "SELECT ?var ?label WHERE { ?var a p-plan:Variable ; rdfs:label ?label }"
             )
             |> Enum.map(fn %{"var" => var, "label" => label} ->
               {AshPPlan.MarketplaceSim.TTL.local_name(var), to_string(label)}
             end)
             |> Enum.into(%{})

  @domains %{
    "ElenaVance" => "ISV",
    "MarcusThorne" => "ISV",
    "SarahChen" => "Enterprise",
    "DavidRoss" => "Enterprise",
    "TariqAlMansoor" => "Enterprise",
    "RachelAdams" => "Hyperscaler",
    "KenjiSato" => "Hyperscaler",
    "LiamSterling" => "Reseller"
  }

  @agents AshPPlan.MarketplaceSim.TTL.solutions!(
            @graph,
            "SELECT ?agent ?label ?title ?org WHERE {
                ?agent a prov:Agent, prov:Person ;
                       rdfs:label ?label ;
                       gcp:roleTitle ?title ;
                       gcp:memberOfOrganization ?org .
              }"
          )
          |> Enum.map(fn %{"agent" => agent, "label" => label, "title" => title, "org" => org} ->
            id = AshPPlan.MarketplaceSim.TTL.local_name(agent)

            %{
              id: id,
              name: to_string(label),
              title: to_string(title),
              org: AshPPlan.MarketplaceSim.TTL.local_name(org),
              domain: @domains[id]
            }
          end)
          |> Enum.sort_by(& &1.id)

  @orgs AshPPlan.MarketplaceSim.TTL.solutions!(
          @graph,
          "SELECT ?org ?label WHERE { ?org a prov:Agent, prov:Organization ; rdfs:label ?label }"
        )
        |> Enum.map(fn %{"org" => org, "label" => label} ->
          {AshPPlan.MarketplaceSim.TTL.local_name(org), to_string(label)}
        end)
        |> Enum.into(%{})

  # Prose layer from the original single-file app, keyed by step local name.
  @step_prose %{
    "Step1_EnrollAndVerifySupplier" => %{
      summary:
        "Supplier enrolls in the Google Cloud Partner Network, signs MVA terms and completes legal/tax verification to unlock Producer Portal access.",
      risk:
        "MVA (Minimum Viable Agreement) risk: enrollment and MVA terms must complete before any listing work starts; an unsigned MVA stalls every downstream phase."
    },
    "Step2_PublishSaaSListing" => %{
      summary:
        "Technical integration is validated and the SaaS listing is published, minting the Procurement API service account and public catalog entry.",
      risk:
        "Hosting prerequisite: primary-infrastructure hosting on GCP must be certified, or listing publication is rejected at technical review."
    },
    "Step3_StructurePrivateOffer" => %{
      summary:
        "ISV and customer negotiate discount, CUD schedule and payment milestones; the sealed offer payload and secure acceptance URI are published.",
      risk:
        "MCPO bridging: multi-cloud private offers must be structured through the marketplace offer pipeline; a malformed payload breaks the acceptance deep link."
    },
    "Step4_AuthorizeAndAcceptOffer" => %{
      summary:
        "The enterprise binds a target billing account and accepts the offer through Cloud Console, creating the GCP order instance and commercial contract state.",
      risk:
        "Billing-admin-only acceptance: only a Billing Account Administrator of the target account can accept; procurement users without that IAM role fail at the portal."
    },
    "Step5_ProvisionEntitlementAndLinkAccount" => %{
      summary:
        "Entitlement activation is driven from the Pub/Sub trigger and the customer's Google identity is linked to a provisioned ISV tenant account.",
      risk:
        "Pub/sub-vs-redirect race: the signup-token redirect and the ENTITLEMENT_ACTIVATION_REQUESTED message may arrive out of order — the safeguard is to only approve the linked account AFTER the entitlement is formally approved (accounts:approve before entitlements:approve ordering)."
    },
    "Step6_MeterTelemetryUsage" => %{
      summary:
        "Consumption telemetry is aggregated and ingested through Service Control, producing validated usage batches ready for drawdown.",
      risk:
        "Idempotency: telemetry ingestion must be idempotent — duplicate Pub/Sub deliveries must not double-count usage records."
    },
    "Step7_ExecuteCommitmentDrawdown" => %{
      summary:
        "Committed spend is cleared against the enterprise commitment pool and consolidated invoices with ISV software line items are generated.",
      risk:
        "Qualifying purchases only: drawdown debits only marketplace-eligible line items from the commitment pool; non-qualifying charges do not reduce the pool."
    },
    "Step8_DisburseNetSettlement" => %{
      summary:
        "The financial clearinghouse reconciles the invoice, applies hyperscaler fees and disburses the net remittance wire to the ISV.",
      risk:
        "ERP reconciliation: disbursement must reconcile against the ISV ERP ledger; unapplied postpay credits surface here as reconciliation breaks."
    }
  }

  @avatar_prose %{
    "ElenaVance" =>
      "Owns alliance strategy; drives the MVA and champions the deal from ISV side.",
    "MarcusThorne" =>
      "Architects the integration; owns Procurement API, Pub/Sub and entitlement wiring.",
    "SarahChen" => "Runs enterprise sourcing; binds the billing account and executes acceptance.",
    "DavidRoss" => "FinOps authority; approves commitment capacity and governs drawdown pacing.",
    "TariqAlMansoor" =>
      "Billing Account Administrator; the only role that can accept the private offer.",
    "RachelAdams" =>
      "Field sales co-sell director; registers the opportunity and defends discount structure.",
    "KenjiSato" =>
      "Partner engineering reviewer; validates integration and hosting certification.",
    "LiamSterling" =>
      "Reseller channel lead; structures the hyperscaler deal through StrataCloud."
  }

  @domains_ui ["All", "ISV", "Enterprise", "Hyperscaler", "Reseller"]

  def steps, do: @steps
  def variables, do: @variables
  def agents, do: @agents
  def orgs, do: @orgs
  def ttl_text, do: @ttl_text

  # -- FinOps simulator (server-side math) -------------------------------------

  @doc """
  FinOps commitment-pool simulator.

  organic_burn = pool * rate; unused = max(0, pool - organic);
  post = min(pool, organic + deal); remaining = max(0, pool - post);
  gain = (deal / pool) * 100 rounded to 1 decimal. 12-month linear curves.
  """
  def simulate(pool, deal, rate_pct) do
    rate = rate_pct / 100

    organic = trunc(pool * rate)
    unused = max(0, pool - organic)
    post = min(pool, trunc(organic + deal))
    remaining = max(0, pool - post)
    gain = Float.round(deal / pool * 100, 1)

    # 12-month linear burn: remaining pool declines linearly to `remaining`.
    curve =
      Enum.map(0..12, fn m ->
        remaining + (pool - remaining) * (12 - m) / 12
      end)

    %{
      organic_burn: organic,
      unused_pool: unused,
      post_deal_pool: post,
      remaining_pool: remaining,
      gain_pct: gain,
      curve: curve
    }
  end

  @impl true
  def mount(_params, _session, socket) do
    sim = simulate(5_000_000, 400_000, 70)

    socket =
      socket
      |> assign(:active_domain, "All")
      |> assign(:active_step_id, "Step1_EnrollAndVerifySupplier")
      |> assign(:commit_pool, 5_000_000)
      |> assign(:deal_size, 400_000)
      |> assign(:organic_rate, 70)
      |> assign(:ontology_search, @ttl_text)
      |> assign(:steps, @steps)
      |> assign(:variables, @variables)
      |> assign(:agents, @agents)
      |> assign(:step_prose, @step_prose)
      |> assign(:avatar_prose, @avatar_prose)
      |> assign(:domains_ui, @domains_ui)
      |> assign(:sim, sim)

    {:ok, socket}
  end

  @impl true
  def handle_event("filter_avatars", %{"domain" => domain}, socket) do
    {:noreply, assign(socket, :active_domain, domain)}
  end

  def handle_event("select_step", %{"id" => id}, socket) do
    {:noreply, assign(socket, :active_step_id, id)}
  end

  def handle_event("update_simulator", %{"sim" => params}, socket) do
    pool = parse_num(params["commit_pool"], 5_000_000)
    deal = parse_num(params["deal_size"], 400_000)
    rate = parse_num(params["organic_rate"], 70)

    {:noreply,
     socket
     |> assign(:commit_pool, pool)
     |> assign(:deal_size, deal)
     |> assign(:organic_rate, rate)
     |> assign(:sim, simulate(pool, deal, rate))}
  end

  def handle_event("search_ontology", %{"q" => q}, socket) when q in [nil, ""] do
    {:noreply, assign(socket, :ontology_search, @ttl_text)}
  end

  def handle_event("search_ontology", %{"q" => q}, socket) do
    needle = String.downcase(q)

    filtered =
      @ttl_text
      |> String.split("\n")
      |> Enum.filter(fn line ->
        String.starts_with?(String.downcase(line), "@prefix") or
          String.contains?(String.downcase(line), needle)
      end)
      |> Enum.join("\n")

    {:noreply, assign(socket, :ontology_search, filtered)}
  end

  defp parse_num(nil, default), do: default

  defp parse_num(value, default) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> trunc(f)
      :error -> default
    end
  end

  defp parse_num(value, _default) when is_integer(value), do: value

  defp parse_num(value, _default) when is_float(value), do: trunc(value)

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-6xl p-6 space-y-8">
      <section id="hero">
        <h1 class="text-2xl font-bold">GCP Marketplace Lifecycle Explorer</h1>
        <div class="mt-4 grid grid-cols-3 gap-4">
          <div class="rounded-lg bg-slate-100 p-4" data-kpi="steps">
            <div class="text-3xl font-bold">{length(@steps)}</div>
            <div class="text-sm text-slate-600">p-plan Steps</div>
          </div>
          <div class="rounded-lg bg-slate-100 p-4" data-kpi="variables">
            <div class="text-3xl font-bold">{map_size(@variables)}</div>
            <div class="text-sm text-slate-600">p-plan Variables</div>
          </div>
          <div class="rounded-lg bg-slate-100 p-4" data-kpi="agents">
            <div class="text-3xl font-bold">{length(@agents)}</div>
            <div class="text-sm text-slate-600">Agents</div>
          </div>
        </div>
      </section>

      <section id="avatars">
        <h2 class="text-lg font-semibold mb-2">Stakeholder Avatars</h2>
        <div class="flex gap-2 mb-4">
          <.domain_button :for={domain <- @domains_ui} domain={domain} active={@active_domain} />
        </div>
        <div class="grid grid-cols-4 gap-4">
          <.card :for={agent <- visible_agents(@active_domain)} data-avatar={agent.id}>
            <div class="font-semibold">{agent.name}</div>
            <.badge color="info" size="xs" data-domain={agent.domain}>{agent.domain}</.badge>
            <div class="text-sm mt-2">{agent.title}</div>
            <div class="text-xs text-slate-600 mt-2">{@avatar_prose[agent.id]}</div>
          </.card>
        </div>
      </section>

      <section id="steps">
        <h2 class="text-lg font-semibold mb-2">Lifecycle Steps</h2>
        <div class="flex flex-wrap gap-2 mb-4">
          <button
            :for={step <- @steps}
            phx-click="select_step"
            phx-value-id={step.id}
            class={
              "rounded px-3 py-1 text-sm " <>
                if step.id == @active_step_id, do: "bg-blue-600 text-white", else: "bg-slate-200"
            }
            data-step-button={step.id}
          >
            {step.label}
          </button>
        </div>
        <.step_card step={active_step(@active_step_id)} prose={@step_prose} variables={@variables} />
      </section>

      <section id="simulator">
        <h2 class="text-lg font-semibold mb-2">FinOps Commitment Simulator</h2>
        <.form
          id="sim"
          for={%{}}
          phx-change="update_simulator"
          class="grid grid-cols-3 gap-6 rounded-lg border p-4"
        >
          <label>
            Commit Pool: {@commit_pool}
            <input
              type="range"
              name="sim[commit_pool]"
              min="1000000"
              max="20000000"
              step="100000"
              value={@commit_pool}
            />
          </label>
          <label>
            Deal Size: {@deal_size}
            <input
              type="range"
              name="sim[deal_size]"
              min="50000"
              max="5000000"
              step="50000"
              value={@deal_size}
            />
          </label>
          <label>
            Organic Rate %: {@organic_rate}
            <input
              type="range"
              name="sim[organic_rate]"
              min="0"
              max="100"
              step="5"
              value={@organic_rate}
            />
          </label>
        </.form>
        <div class="mt-4 grid grid-cols-4 gap-4">
          <div class="rounded bg-slate-100 p-3" data-kpi="gain">
            <div class="text-2xl font-bold">{@sim.gain_pct}%</div>
            <div class="text-xs text-slate-600">Pool Gain</div>
          </div>
          <div class="rounded bg-slate-100 p-3" data-kpi="organic">
            <div class="text-2xl font-bold">{@sim.organic_burn}</div>
            <div class="text-xs text-slate-600">Organic Burn</div>
          </div>
          <div class="rounded bg-slate-100 p-3" data-kpi="remaining">
            <div class="text-2xl font-bold">{@sim.remaining_pool}</div>
            <div class="text-xs text-slate-600">Remaining Pool</div>
          </div>
          <div class="rounded bg-slate-100 p-3" data-kpi="post-deal">
            <div class="text-2xl font-bold">{@sim.post_deal_pool}</div>
            <div class="text-xs text-slate-600">Post-Deal Pool</div>
          </div>
        </div>
        <div class="mt-4" data-burndown>
          <svg viewBox="0 0 240 100" width="480" height="200" role="img" aria-label="Burn-down curve">
            <polyline
              points={polyline_points(@sim.curve, 240, 100)}
              fill="none"
              stroke="#2563eb"
              stroke-width="2"
            />
          </svg>
        </div>
      </section>

      <section id="turtle">
        <h2 class="text-lg font-semibold mb-2">Lifecycle Ontology (Turtle)</h2>
        <.form id="turtle-search" for={%{}} phx-change="search_ontology" class="mb-2">
          <input type="text" name="q" placeholder="Filter turtle lines…" />
        </.form>
        <pre
          id="turtle-viewer"
          class="max-h-96 overflow-auto rounded bg-slate-900 p-4 text-xs text-slate-100"
        >{@ontology_search}</pre>
      </section>
    </div>
    """
  end

  defp domain_button(assigns) do
    ~H"""
    <button
      phx-click="filter_avatars"
      phx-value-domain={@domain}
      class={
        "rounded px-3 py-1 text-sm " <>
          if @domain == @active, do: "bg-indigo-600 text-white", else: "bg-slate-200"
      }
      data-domain-filter={@domain}
    >
      {@domain}
    </button>
    """
  end

  defp step_card(assigns) do
    ~H"""
    <.card data-step-card={@step.id}>
      <h3 class="font-semibold">{@step.label}</h3>
      <.badge color="success" size="xs">ontology-backed step</.badge>
      <p class="text-sm mt-1">{@prose[@step.id].summary}</p>
      <p class="text-sm mt-2 text-amber-700" data-risk>{@prose[@step.id].risk}</p>
      <div class="mt-3 grid grid-cols-2 gap-4 text-sm">
        <div>
          <div class="font-medium">Inputs</div>
          <ul data-inputs>
            <li :for={input <- @step.inputs} data-input={input}>{@variables[input]}</li>
          </ul>
        </div>
        <div>
          <div class="font-medium">Outputs</div>
          <ul data-outputs>
            <li :for={output <- @step.outputs} data-output={output}>{@variables[output]}</li>
          </ul>
        </div>
        <div>
          <div class="font-medium">Agents</div>
          <ul data-agents>
            <li :for={agent <- @step.agents}>{agent}</li>
          </ul>
        </div>
      </div>
    </.card>
    """
  end

  defp visible_agents("All"), do: @agents
  defp visible_agents(domain), do: Enum.filter(@agents, &(&1.domain == domain))

  defp active_step(id), do: Enum.find(@steps, &(&1.id == id))

  defp polyline_points(curve, w, h) do
    max = Enum.max(curve)
    min = Enum.min(curve)
    span = max - min

    curve
    |> Enum.with_index()
    |> Enum.map(fn {v, i} ->
      x = i / (length(curve) - 1) * w
      y = if span == 0, do: h / 2, else: (max - v) / span * h
      :erlang.float_to_binary(x, decimals: 1) <> "," <> :erlang.float_to_binary(y, decimals: 1)
    end)
    |> Enum.join(" ")
  end
end
