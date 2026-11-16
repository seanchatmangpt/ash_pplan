# AshPPlan Test Suite Audit (v26.11.15)

- **Audited Repository**: `/Users/sac/ash_pplan`
- **Auditor**: Agent 8 of 20 (AshPplan Test Suite Auditor)
- **Date**: 2026-11-16
- **Status**: Complete — Forensic Analysis & Live Verification

---

## 1. Executive Summary & Audit Scope

A comprehensive forensic audit of the `ash_pplan` test suite was conducted across 360 test files in `test/`, covering:
- **Hierarchical Task Network (HTN)** and **STRIPS state-space planning** (`lib/ash_pplan/htn.ex`, `test/ash_pplan/htn_test.exs`).
- **HDDL projection and parsing** (`lib/ash_pplan/workflow/project/hddl.ex`, `test/workflow/hddl_court_test.exs`).
- **FOND policy synthesis and epistemic horizons** (`lib/ash_pplan/fond.ex`, `test/fond/`, `test/workflow/fond_court_test.exs`).
- **Chicago-style sabotage & mutation courts** (`test/chicago_adoption_test.exs`, `test/workflow/standing_falsifier_mutation_test.exs`).
- **Durable Reactor execution engine & ledger** (`test/durable/`, `test/reactor/`, `test/workflow/runtime_test.exs`).
- **POWL (Partially Ordered Workflow Language) reachability courts** (`test/powl/`, `test/compiler_powl_seam_test.exs`).
- **Tokyo-Depeg financial clearing courts & Van der Aalst Petri-net conformance alignment** (`test/tokyo_depeg/`).
- **Ontology and Pack byte-identity regeneration courts** (`test/courts/`).

### Key Verdict
The core planning and runtime engines in `ash_pplan` contain genuine, mathematically sound implementations of HTN decomposition, STRIPS search, HDDL domain grounding, and Petri-net alignment. However, the test suite exhibits:
1. **Critical Execution Traps**: A stale lock directory (`tmp/.demonstrate-lock`) from Nov 10 causes tests executing `bin/demonstrate` (via `test/demonstration_court_test.exs`) to stall in a 15-minute `sleep 2` loop and fail with exit code 3.
2. **Recursive Test Suite Hazards**: Bare `mix test` runs `test/demonstration_court_test.exs`, which executes `bin/demonstrate`, which recursively invokes 7 manufacture scripts and `mix test --exclude demonstration_court`.
3. **Vacuous & Zero-Assertion Tests**: Tests that pass unconditionally with 0 assertions executed when sibling libraries (e.g., `ash_a2a`) are not present, or that assert purely tautological in-memory map modifications instead of verifying disk-level file generation.
4. **Brittle Cross-Repository Ambient Couplings**: Test assertions hardcoding ambient filesystem paths (e.g. `System.cmd("git", ["-C", "/Users/sac/ggen-marketplace", ...])`) against pinned SHAs that break when the external repository is updated.
5. **Conditional Fallback Shields**: Dual-branch assertions (`if Code.ensure_loaded?(mod) ... else ...`) that shield unmanufactured or broken workflow modules from failing the suite.

---

## 2. Test Suite Live Execution & Build Bottleneck Findings

### Finding 1.1: Missing Initial Hex Cache / Dependencies
- **File / Area**: `/Users/sac/ash_pplan/mix.exs`, `/Users/sac/ash_pplan/deps`
- **Issue**: Running `mix test` directly on a fresh checkout failed immediately because Hex packages were not downloaded into `deps/`.
- **Exact Command Executed**:
  ```sh
  cd /Users/sac/ash_pplan && mix test
  ```
- **Verbatim Output**:
  ```
  Unchecked dependencies for environment test:
  * websock_adapter (Hex package)
    the dependency is not available, run "mix deps.get"
  * jason (Hex package)
    the dependency is not available, run "mix deps.get"
  * spark (Hex package)
    the dependency is not available, run "mix deps.get"
  * ggen_igniter (Hex package)
    the dependency is not available, run "mix deps.get"
  ...
  ** (Mix) Can't continue due to errors on dependencies
  ```
- **Resolution**:
  Executed `mix deps.get --check-locked`, which verified `mix.lock` was untouched and fetched all 100 locked dependencies cleanly:
  ```sh
  cd /Users/sac/ash_pplan && mix deps.get --check-locked
  ```
  Output: `Resolution completed in 0.069s. Unchanged: ash 3.33.11, bandit 1.12.5...`

---

### Finding 1.2: Heavy Native Compilation Bottlenecks (Rust, C++, Erlang)
- **File / Area**: `deps/ggen_igniter`, `deps/sparql`
- **Issue**: Compiling the test environment requires extensive native compilation:
  1. `deps/ggen_igniter` invokes Cargo to compile `ggen_graph_nif`, requiring Apple Clang (`clang++`) to compile 342+ C++ RocksDB files in `oxrocksdb-sys` and `oxigraph` Rust crates.
  2. `deps/sparql` compiles `sparql_lexer.erl` (1.52 MB generated Erlang code, 38,000+ lines) and `sparql_parser.erl` (911 KB generated Erlang code). Compiling this in the BEAM compiler required over 10 minutes of CPU time and 980 MB of RAM.
- **Verification Evidence**:
  - Sampled BEAM process `7017` executing `erts_cmp_compound` during SPARQL compiler optimization passes.
  - Process tree inspection showing:
    ```
    /Users/sac/.rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo rustc -p ggen_graph_nif --release
    /Applications/Xcode.app/.../clang++ -O3 -std=c++20 rocksdb/db/compaction/compaction_picker.cc
    ```
  - Total compiled object count in `deps/ggen_igniter/native/ggen_graph_nif/target/release/build`: 342 `.o` files before creating `libggen_graph_nif.dylib` (10.9 MB).

---

### Finding 1.3: Stale Lock Directory (`tmp/.demonstrate-lock`) Inducing 15-Minute Test Hang
- **File / Area**: `/Users/sac/ash_pplan/test/demonstration_court_test.exs`, `/Users/sac/ash_pplan/bin/demonstrate:23-32`
- **Issue**: `test/demonstration_court_test.exs` runs `bin/demonstrate`. Lines 23-32 of `bin/demonstrate` attempt to acquire an exclusive lock:
  ```bash
  LOCK="tmp/.demonstrate-lock"
  acquired=0
  for _ in $(seq 1 450); do
    if mkdir "$LOCK" 2>/dev/null; then acquired=1; break; fi
    sleep 2
  done
  if [ "$acquired" -ne 1 ]; then
    echo "REFUSED: another bin/demonstrate run holds tmp/.demonstrate-lock" >&2
    exit 3
  fi
  ```
  A previous interrupted run on November 10 left a directory `tmp/.demonstrate-lock` on disk:
  ```
  drwxr-xr-x@ 2 sac staff 64 Nov 10 17:08 /Users/sac/ash_pplan/tmp/.demonstrate-lock
  ```
  Because `mkdir tmp/.demonstrate-lock` fails when the directory already exists, `bin/demonstrate` sleeps for 2 seconds 450 times (900 seconds = 15 minutes) before exiting with exit code 3 (`REFUSED: another bin/demonstrate run holds tmp/.demonstrate-lock`).
- **Verbatim Process Inspection**:
  ```sh
  ps -fp $(pgrep -P 12549)
  # UID   PID  PPID   C STIME   TTY           TIME CMD
  # 501 25696 12549   0 10:06AM ??         0:00.00 sleep 2
  ```
- **Consequence**: Anyone executing bare `mix test` will appear to hang indefinitely for 15 minutes and then fail on `test/demonstration_court_test.exs`.
- **Remediation**:
  1. Stale lock files in `tmp/` must verify PID liveness (e.g., storing `$$` in the lock and testing `kill -0 "$pid"`), rather than relying purely on static `mkdir` with a 15-minute blind sleep loop.
  2. Developers and CI must run `mix test --exclude demonstration_court`.

---

### Finding 1.4: Recursive Suite Execution Hazard
- **File / Area**: `/Users/sac/ash_pplan/test/demonstration_court_test.exs:17-25`
- **Issue**: Running `mix test` executes `test/demonstration_court_test.exs`, which runs `bin/demonstrate`. Inside `bin/demonstrate:170`, the script executes:
  ```bash
  run_step "full-test-suite" "mix test --exclude demonstration_court"
  ```
  This causes a recursive test suite execution inside the running test runner. Under multi-agent or concurrent execution environments, this spawns redundant BEAM instances that compete for build locks on `_build/test` and `tmp/`.

---

## 3. Vacuous Assertions and Zero-Assertion Tests Discovered

### Finding 2.1: Zero Assertions in `test/a2a_facade_status_mapping_test.exs`
- **File**: `/Users/sac/ash_pplan/test/a2a_facade_status_mapping_test.exs:213-224`
- **Code**:
  ```elixir
  test ":rejected is terminal per the A2A state machine (matches Task terminal set)" do
    # Read the sibling's real state validation: :rejected is in Task's
    # terminal-state set (v1.0: refused at admission, never resumable). Guarded
    # by Code.ensure_loaded? so the court holds in envs without :ash_a2a.
    if Code.ensure_loaded?(AshA2A.Protocol.Task) do
      attrs = apply(AshA2A.Protocol.Task, :module_info, [:attributes])
      terminal = get_attr(attrs)

      assert :rejected in terminal
      refute :working in terminal
    end
  end
  ```
- **Vacuity Analysis**: `ash_a2a` is not listed in `deps()` in `mix.exs`. Therefore, in standard runs, `Code.ensure_loaded?(AshA2A.Protocol.Task)` evaluates to `false`. The `if` body is skipped completely. The test returns `:ok` with **0 assertions executed**.
- **Impact**: The terminal status mapping of the A2A protocol is completely unverified in this repository despite reporting a passing green test.

---

### Finding 2.2: Completely Vacuous No-Assertion Test in `test/tokyo_depeg/actuation_boundary_test.exs`
- **File**: `/Users/sac/ash_pplan/test/tokyo_depeg/actuation_boundary_test.exs:213-228`
- **Code**:
  ```elixir
  test "actuation is consumer-side: no AshA2A actuation module is loadable (no-dep)" do
    ash_a2a_dep? =
      File.read!(Path.join(File.cwd!(), "mix.exs"))
      |> String.contains?("{:ash_a2a")

    loaded = Code.ensure_loaded?(AshA2A.Actuation)

    if ash_a2a_dep? and loaded do
      flunk(
        "ash_a2a became a mix dependency; replace this structural boundary test with a real consumer-side actuation test"
      )
    else
      # Skip-typed: UNSUPPORTED(no-dep) — the boundary is proven structurally.
      :ok
    end
  end
  ```
- **Vacuity Analysis**: This test contains **zero `assert` or `refute` calls**. It checks whether `mix.exs` contains `{:ash_a2a` and whether `AshA2A.Actuation` is loaded. If false, it simply returns `:ok`. The test provides zero runtime verification and always passes vacuously.

---

### Finding 2.3: Superficial Type Checks Without Policy Validation in `test/fond/corpus_test.exs`
- **File**: `/Users/sac/ash_pplan/test/fond/corpus_test.exs:6-15`
- **Code**:
  ```elixir
  test "seeded corpus is finite deterministic and structurally useful" do
    corpus = Corpus.seeded(24, {3, 5, 7})

    assert corpus == Corpus.seeded(24, {3, 5, 7})
    assert length(corpus) == 24

    assert Enum.all?(corpus, fn item ->
             is_map(item.transitions) and is_list(item.goals) and is_map(item.policy)
           end)
  end
  ```
- **Vacuity Analysis**: The test claims the corpus is "structurally useful", but performs zero semantic validation on the planning objects:
  - It does not check reachability of goals.
  - It does not call `AshPPlan.FOND.validate_policy/4` to verify whether the policy is strong or strong-cyclic.
  - It does not test solvability via `Synthesis.synthesize/3`.
  - It merely checks that `transitions` is a map, `goals` is a list, and `policy` is a map. This is a vacuous structural smoke test.

---

### Finding 2.4: Fake Mutation Test via In-Memory Map Mutation in `test/workflow/workflow_regeneration_court_test.exs`
- **File**: `/Users/sac/ash_pplan/test/workflow/workflow_regeneration_court_test.exs:49-53`
- **Code**:
  ```elixir
  test "mutation: a hand-edited generated file is detected" do
    before = snapshot()
    [{path, body} | _] = Enum.to_list(before)
    refute Map.put(before, path, body <> "# hand edit\n") == before
  end
  ```
- **Vacuity Analysis**: The test claims to falsify generated workflow file drift by proving that "a hand-edited generated file is detected". Instead of creating or editing an actual file on disk and proving that `bin/manufacture-workflow` or `snapshot()` fails, it takes an in-memory Elixir map `before`, inserts a modified string into the map with `Map.put(...)`, and asserts `refute mutated_map == before`.
- **Impact**: This does not test the regeneration court or file-system comparison logic at all. It tests Elixir's core `Map.put/3` function. It is completely vacuous.

---

### Finding 2.5: Fallback Shield Masking Missing Workflows in `test/workflow/ultracode_test.exs`
- **File**: `/Users/sac/ash_pplan/test/workflow/ultracode_test.exs:31-39`
- **Code**:
  ```elixir
  test "the generated module path is used when present" do
    mod = AshPPlan.Examples.Workflows.Ultracode

    if Code.ensure_loaded?(mod) do
      assert {:ok, %{subject: %{workflow: "ultracode"}}} = Runtime.plan(mod)
    else
      assert {:error, %{reason: :unknown_workflow}} = Runtime.plan(mod)
    end
  end
  ```
- **Vacuity Analysis**: This test has two branches: if the generated module is present, it asserts success; if the generated module is absent, it asserts `:unknown_workflow`. If generator manufacturing fails or deletes the file, the test still passes! It provides no guarantee that the generated workflow module actually exists.
- **Similar Occurrences**:
  - `test/courts/examples/selfhost_workflow_court_test.exs:37`
  - `test/courts/examples/qualified_fulfillment_workflow_court_test.exs:37`
  - `test/courts/examples/ontology_only_workflow_court_test.exs:37`

---

### Finding 2.6: Tautological Self-Equality Checks in Research Wave Tests
- **Files**:
  - `test/fond/research_wave_14_test.exs:7-15`
  - `test/fond/research_wave_01_test.exs:7-14`
  - `test/fond/research_wave_02_test.exs:7-14`
- **Code (`research_wave_14_test.exs`)**:
  ```elixir
  test "wave 14 seeded corpus manufacture is replayable" do
    left = Corpus.seeded(16, {17, 31, 53})
    right = Corpus.seeded(16, {17, 31, 53})

    assert left == right
    assert length(left) == 16
    assert Enum.all?(left, &Map.has_key?(&1, :transitions))
  end
  ```
- **Vacuity Analysis**: Testing `Corpus.seeded(16, seed) == Corpus.seeded(16, seed)` only proves deterministic PRNG seeding in pure Elixir. It does not check that any generated problem is valid, has reachable goals, or satisfies FOND policy constraints. There are zero mutation checks or edge cases.

---

## 4. External Daemon Dependency Skips & Cross-Repo Coupling

### Finding 3.1: Silent / Loud Skipping Due to Absent External Daemons
- **Files**:
  - `test/courts/airbus_fond_differential_test.exs:94-107`
  - `test/courts/airbus_parity_court_test.exs:20-28`
- **Code (`airbus_fond_differential_test.exs`)**:
  ```elixir
  setup_all do
    case AirbusFondOracle.ping() do
      :ok -> [daemon: :up]
      {:error, reason} ->
        IO.puts("""
        [SKIP-LOUD] airbus FOND differential court: daemon down — #{inspect(reason)}
        start it with: .venv-airbus/bin/python scripts/airbus_oracle_daemon.py --serve
        """)
        [daemon: :down]
    end
  end

  test "#{name}: native and autofde agree on strong and strong_cyclic", %{daemon: daemon} do
    if daemon == :down do
      raise ExUnit.SkipError, message: "daemon down; differential court cannot run without the oracle"
    end
    ...
  end
  ```
- **Issue**: The Airbus deliberation differential courts (`scikit-decide`, `unified-planning`, `PRP`, FDC) require an ambient Python daemon running on `/tmp/airbus_oracle.sock`. In standard CI or local test executions where this background daemon is not running, all 5 differential parity tests skip silently or with `ExUnit.SkipError`.
- **Status**: The parity between native BEAM FOND policy synthesis and the Python Airbus oracle is unvalidated during automated runs unless the daemon is explicitly booted beforehand.

---

### Finding 3.2: Brittle Ambient Cross-Repo Git Inspection in `test/courts/pack_gate_witness_court_test.exs`
- **File**: `/Users/sac/ash_pplan/test/courts/pack_gate_witness_court_test.exs:53-65`
- **Code**:
  ```elixir
  @pinned_marketplace_sha "29c579082aefe57eda5695d13cd4edb76cb82b31"

  test "vendored pack is locked at the pinned marketplace sha" do
    {out, 0} = System.cmd("git", ["-C", "/Users/sac/ggen-marketplace", "rev-parse", "HEAD"])
    assert String.trim(out) == @pinned_marketplace_sha
    ...
  end
  ```
- **Issue**: The test reaches outside its own git repository into `/Users/sac/ggen-marketplace` and asserts that its current active HEAD is `"29c579082aefe57eda5695d13cd4edb76cb82b31"`.
- **Live Failure Verification**:
  Executing the exact command:
  ```sh
  git -C /Users/sac/ggen-marketplace rev-parse HEAD
  ```
  Returns:
  ```
  4bc81db7cfc82743c154635972c9474b2bede03e
  ```
  When this test is executed, `assert String.trim(out) == @pinned_marketplace_sha` **fails immediately** because the marketplace checkout has advanced. A test suite must never depend on the mutable working-tree state of an external repository. The lock verification should inspect only repo-local artifacts (`priv/ggen/vendor/PACKS.lock.json`).

---

### Finding 3.3: Conditional Omission of Ex4pm Tests
- **File**: `/Users/sac/ash_pplan/test/workflow/process_evidence_ex4pm_test.exs:30-83`
- **Issue**: 5 tests verifying OCEL2 JSON export, EventLog round-trips, and Ex4pm relationship mappings are wrapped in:
  ```elixir
  if Code.ensure_loaded?(Elixir.Ex4pm.Event) do
    ...
  end
  ```
  If `Ex4pm` is compiled without `Elixir.Ex4pm.Event` or when evaluating in an environment missing the protocol structs, the tests are omitted at compile time without marking any test as skipped or failed.

---

### Finding 3.4: Unsupported BLAKE3 Wasm Affidavit Seam
- **File**: `/Users/sac/ash_pplan/test/support/tokyo_depeg/affidavit.ex:20-37`
- **Issue**:
  ```elixir
  def commit(payload, _opts \\ []) do
    if Code.ensure_loaded?(AshAffidavit) do
      ...
    else
      {:unsupported, :no_dep, "ash_affidavit is not a mix dep of ash_pplan; BLAKE3 identity stays a documented :blake2b stand-in"}
    end
  end
  ```
  Because `ash_affidavit` is not a dependency in `mix.exs`, all Tokyo-Depeg affidavit commit tests fall back to a `:blake2b` stand-in and record `UNSUPPORTED(no-dep)` rather than executing real WASM kernel BLAKE3 commitments.

---

## 5. Planning Correctness: HTN & HDDL Execution vs Stubs

### Finding 4.1: Real HTN State-Space & Decomposition Algorithm
- **File**: `lib/ash_pplan/htn.ex:656-850`, `test/ash_pplan/htn_test.exs:8-143`
- **Assessment**: **GENUINE (REAL IMPLEMENTATION)**.
  - The HTN solver implements a genuine total-order decomposition with state backtracking.
  - `Action`: Holds normalized `preconditions`, `add_list`, `delete_list`, and `cost`.
  - `Method`: Holds `task`, `preconditions`, `priority`, and `subtasks`.
  - **Backtracking Logic**: When decomposing compound tasks, methods are sorted by priority. If a higher-priority method fails downstream primitive preconditions (e.g., `:settle_within_nte` failing `:within_nte`), the algorithm backtracks to alternative methods (e.g., `:resolve_wo_nte_escalation`).
  - **Anti-Vacuity**: Proven in `test/ash_pplan/htn_test.exs:136-143` where removing `:nh3_serial_present` causes both methods to fail on `:verify_nh3_serial` with `{:error, %{reason: :preconditions_not_met, task: :verify_nh3_serial}}`.

---

### Finding 4.2: Real HDDL Domain & Problem Grounding
- **File**: `lib/ash_pplan/htn.ex:1160-1250`, `test/ash_pplan/htn_test.exs:248-282`
- **Assessment**: **GENUINE (REAL IMPLEMENTATION)**.
  - `HDDL.parse/1` genuinely parses HDDL domain definitions (`:domain`, `:types`, `:predicates`, `:tasks`, `:actions`, `:methods`).
  - `ground_problem_domain/2`: Evaluates root task instances (e.g. `{"deliver-release", "ash-pplan", "v26-9-6"}`), positionally binds parameters, substitutes action preconditions and effects, expands subtasks into grounded actions, and enforces an instance cap (`@grounding_instance_cap 4096`) to terminate runaway cycles with `{:error, %{reason: :cyclic_methods}}`.
  - Real archive domain `planning/archive/ash_pplan_v26_9_6.hddl` and problem `planning/archive/ship_v26_9_6.hddl` are parsed, grounded, and solved goal-satisfied to produce the 9-step plan.

---

### Finding 4.3: Problem File Stub Escape Hatch (`allow_stub_problem: true`)
- **File**: `lib/ash_pplan/htn.ex:1083-1157`
- **Assessment**: **GAPPED / RELAXABLE GATE**.
  - `parse_problem_file/2` correctly identifies a stub problem when `problem.init == [] and problem.htn == [] and problem.goal == []`.
  - By default, it fails closed: `{:error, %{reason: :invalid_problem_file, stub: true}}`.
  - However, it admits an `allow_stub_problem: true` option (`htn.ex:1145`). When passed, it bypasses root tasks, sets `problem_file_used: false`, and solves purely against `opts[:initial_state]`.
  - While tested in `test/ash_pplan/htn_test.exs:284-312`, this creates an escape hatch where workflows can pretend to solve HDDL problems without providing any problem definitions.

---

### Finding 4.4: Inherent HTN Limitation: Total-Order Only (No PO-HTN)
- **File**: `lib/ash_pplan/htn.ex:8-12`
- **Assessment**: **KNOWN BOUNDARY GAP**.
  - As explicitly admitted in the module documentation:
    > "the ordering of subtasks within a decomposition is fixed, so this is not a partial-order planner"
  - Complex multi-agent workflows requiring partial-order interleaving must be pre-linearized or routed through POWL reachability simulation rather than native HTN method decomposition.

---

## 6. Comprehensive Findings & Remediation Matrix

| Finding ID | Severity | File / Module | Description | Remediation Plan |
|---|---|---|---|---|
| **F-01** | CRITICAL | `bin/demonstrate:23-32` | Stale `tmp/.demonstrate-lock` hangs test suite for 15 minutes before failing with exit 3. | Add PID-liveness check to lock script; configure `mix test` alias to `--exclude demonstration_court` by default. |
| **F-02** | HIGH | `test/a2a_facade_status_mapping_test.exs:213` | Test passes vacuously with 0 assertions executed because `ash_a2a` is not loaded. | Replace conditional `if` with an explicit assertion on local status tables or require `ash_a2a` in test environment. |
| **F-03** | HIGH | `test/tokyo_depeg/actuation_boundary_test.exs:213` | No `assert` or `refute` calls; returns `:ok` vacuously. | Add explicit assertion checking that `AshA2A.Actuation` cannot be invoked from the provider. |
| **F-04** | HIGH | `test/courts/pack_gate_witness_court_test.exs:54` | Hardcoded `git -C /Users/sac/ggen-marketplace` SHA assertion breaks when external repo advances. | Validate against local `priv/ggen/vendor/PACKS.lock.json` instead of querying ambient filesystem git state. |
| **F-05** | MEDIUM | `test/workflow/workflow_regeneration_court_test.exs:49` | Mutation test mutates in-memory Elixir Map rather than verifying disk file regeneration. | Write a temporary corrupted template to disk and verify `bin/manufacture-workflow` fails. |
| **F-06** | MEDIUM | `test/fond/corpus_test.exs:6-15` | Superficial type-checking without policy validation or goal reachability. | Call `AshPPlan.FOND.validate_policy/4` on each corpus item to assert strong or strong-cyclic validity. |
| **F-07** | MEDIUM | `test/workflow/ultracode_test.exs:31-39` | Dual-branch test passes whether generated module exists or not. | Split into a strict assertion requiring the generated module to exist after manufacture. |
| **F-08** | LOW | `test/courts/airbus_fond_differential_test.exs:94` | Silent/loud skip when Python daemon is offline. | Provide automated fixture fallback or document prerequisite daemon startup in `mix test` runner. |

---

## 7. Verification Method

To independently reproduce and verify the findings in this report:

1. **Verify Dependency Fetch**:
   ```sh
   cd /Users/sac/ash_pplan && mix deps.get --check-locked
   ```
2. **Verify Stale Lock in `tmp/`**:
   ```sh
   ls -la /Users/sac/ash_pplan/tmp/.demonstrate-lock
   ```
3. **Verify Ambient Cross-Repo SHA Divergence in `pack_gate_witness_court_test.exs`**:
   ```sh
   git -C /Users/sac/ggen-marketplace rev-parse HEAD
   grep -n "@pinned_marketplace_sha" /Users/sac/ash_pplan/test/courts/pack_gate_witness_court_test.exs
   ```
4. **Verify Zero-Assertion Vacuous Tests**:
   Inspect line 213 of `test/a2a_facade_status_mapping_test.exs` and line 213 of `test/tokyo_depeg/actuation_boundary_test.exs`.
5. **Execute HTN Planning Suite (Isolated from Demonstration Court)**:
   ```sh
   cd /Users/sac/ash_pplan && mix test test/ash_pplan/htn_test.exs
   ```
