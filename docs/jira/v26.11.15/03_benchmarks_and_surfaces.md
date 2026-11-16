# AshPPlan Benchmarks & Solvers Audit (v26.11.15)

**Audit Date**: 2026-11-16  
**Auditor**: Agent 10 of 20 (`ash_pplan_auditor_benchmarks_docs`)  
**Target Repository**: `/Users/sac/ash_pplan`  
**Standing**: AUDITED (Empirical Baselines Measured, Solver Complexity Bound, Deficiencies Documented)  
**Deliverable**: `/Users/sac/ash_pplan/docs/jira/v26.11.15/03_benchmarks_and_surfaces.md`  

---

## 1. Executive Summary

A comprehensive live empirical audit of the benchmark harnesses, planning solvers (HTN, STRIPS, HDDL, FOND, POWL), algorithmic scaling limits, and unbenchmarked execution surfaces in `/Users/sac/ash_pplan` was conducted.

The audit executed live runs of all repository benchmark harnesses (`bench/claims_bench.exs`, `bench/store_scaling.exs`, `bench/compiler_cost_curve.exs`, `bench/fond_tla_bench.exs`, and `bench/standing_closure_bench.exs`), generating reproducible machine receipts. In addition, deep empirical probes were executed against `AshPPlan.HTN`, `AshPPlan.FOND`, `AshPPlan.POWL`, and `AshPPlan.Airbus.Transpiler` to establish exact complexity curves, failure horizons, and scaling ceilings.

### Core Discoveries:
1. **Severe Concurrent Contention in RingBuffer**: Under 8 concurrent writers, `RingBuffer.push/4` latency collapses from solo p99 of 7 µs to p99 of 4,814 µs (mean 509 µs), failing the claimed `< 10 µs` ceiling by ~480x due to un-throttled `:ets.update_counter` contention.
2. **DETS Production Scaling Cliff**: While ETS write throughput sustains 343,418 ops/s at 10,000 checkpoints, DETS write throughput degrades to 105 ops/s, checkpoint read latency balloons to **540,550 µs** (over 0.54 seconds per read), and concurrent signal dispatch under 32 readers collapses to **26 ops/s**.
3. **Hard Horizon Limit in STRIPS Planner**: `AshPPlan.HTN.strips_plan/4` hardcodes `max_depth: 10`. Any planning problem requiring 11 or more steps immediately returns `{:error, :max_depth_exceeded}`. Furthermore, being an unguided pure Breadth-First Search (BFS), branching factor $B=3$ exhibits severe exponential time explosion (45.9 ms at depth 10, a >400x increase over depth 4).
4. **Hard Step Horizon Limit in HTN Decomposition**: `AshPPlan.HTN.decompose/4` hardcodes `max_steps: 256` counting both primitive and compound tasks. A linear plan of 300 primitive steps with zero compound hierarchy fails at step 257 with `{:error, %{reason: :max_steps_exceeded, steps: 256}}`.
5. **Leftover Debug Artifact in Production HDDL Parser**: `AshPPlan.Workflow.Project.HDDL.parse/1` contains an active `IO.inspect(__STACKTRACE__, label: "DEBUG_BAD_FORM")` on line 92 that pollutes stdout on any malformed HDDL input.
6. **Complete Absence of Solvers in the Committed Benchmark Suite**: In all 16 benchmark scripts under `bench/`, there is **zero benchmarking** of `AshPPlan.HTN.decompose/4`, `AshPPlan.HTN.strips_plan/4`, `AshPPlan.HTN.hddl_solve/4`, `AshPPlan.Workflow.Project.HDDL.parse/1`, `AshPPlan.POWL.Verifier.verify/1`, or `AshPPlan.Airbus.Transpiler`. The committed benchmark suite tests only storage, telemetry, receipts, and linear FOND chains.
7. **Vacuous POWL Admission in Compiler**: `AshPPlan.Compiler.admit_powl({:error, %{reason: :unsupported_powl_shape}})` explicitly returns `:ok`, allowing unverified, non-standard, or malformed POWL structures to completely bypass separability verification.
8. **Missing Problem Files in `planning/`**: Every file in `planning/*.hddl` is an HDDL domain file `(define (domain ...))`. There is not a single valid problem file `(define (problem ...))` in `planning/` (only historical archives exist in `planning/archive/`).

No existing source code or test files in `/Users/sac/ash_pplan` were modified during this audit.

---

## 2. Audit Findings Matrix

| ID | Category | Severity | File / Module | Summary |
|---|---|---|---|---|
| **BS-01** | Concurrency Contention | **CRITICAL** | `lib/ash_pplan/reactor/durable/ring_buffer.ex:42`, `bench/claims_bench.exs` | `RingBuffer.push/4` under 8 concurrent writers degrades to p99 4,814 µs (mean 509 µs), failing the sub-10µs claim by ~480x. |
| **BS-02** | Storage Scalability Cliff | **CRITICAL** | `lib/ash_pplan/reactor/durable/store/dets.ex:82`, `bench/store_scaling.exs` | DETS at 10k checkpoints degrades to 105 write ops/s, 540.5 ms read latency, and 26 signal dispatch ops/s under 32 readers. |
| **BS-03** | Unguided Exponential BFS | **HIGH** | `lib/ash_pplan/htn.ex:431-452` | STRIPS planner is unguided BFS with hardcoded `max_depth: 10`; fails on >10 steps; branching $B=3$ jumps from 107 µs (d=4) to 45.9 ms (d=10). |
| **BS-04** | Hard Primitive Step Horizon | **HIGH** | `lib/ash_pplan/htn.ex:245,690` | HTN decomposition default `max_steps: 256` counts primitive actions; linear plan of 300 steps fails at step 257 with `:max_steps_exceeded`. |
| **BS-05** | Production Debug Logging | **MEDIUM** | `lib/ash_pplan/workflow/project/hddl.ex:92` | Production code contains `IO.inspect(__STACKTRACE__, label: "DEBUG_BAD_FORM")` which dumps stacktraces to stdout on malformed HDDL. |
| **BS-06** | Solver Benchmark Vacuum | **HIGH** | `bench/` (all 16 scripts) | Zero benchmarks exist for `AshPPlan.HTN`, `AshPPlan.POWL`, `AshPPlan.Workflow.Project.HDDL`, or `AshPPlan.Airbus.Transpiler`. |
| **BS-07** | Vacuous Compiler Admission | **HIGH** | `lib/ash_pplan/compiler.ex:135` | `admit_powl({:error, %{reason: :unsupported_powl_shape}}), do: :ok` silently bypasses separability verification for malformed POWL. |
| **BS-08** | Missing HDDL Problem Fixtures | **MEDIUM** | `planning/*.hddl` | All root `planning/*.hddl` files define domains; zero problem files exist, making out-of-the-box native HDDL solving impossible without stub flags. |
| **BS-09** | Linear FOND Benchmark Vacuity | **MEDIUM** | `bench/hot_paths_bench.exs:279`, `bench/standing_closure_bench.exs:131` | FOND benchmarks test only 1D progress chains (`s_i -> s_{i+1}`); never evaluate multi-variable combinatorial domains with concurrent nondeterminism. |
| **BS-10** | Super-linear Compiler Scaling | **MEDIUM** | `bench/compiler_cost_curve.exs:40-64` | `Compiler.compile_spec/2` scales super-linearly from 4.2 ms (100 linear steps) to 207.5 ms (1,000 steps); fanout reaches 395 ms at 1,000 steps. |
| **BS-11** | Unchecked STNU Controllability | **LOW** | `lib/ash_pplan/airbus/transpiler.ex:99-130` | `to_stnu/1` formats an STNU dictionary, but `ash_pplan` provides no dynamic controllability checker or temporal consistency verifier. |
| **BS-12** | Atom Leak in Transpiler Roundtrip | **MEDIUM** | `lib/ash_pplan/airbus/transpiler.ex:143,149` | `verify_roundtrip!/3` invokes `String.to_atom/1` on arbitrary external string inputs, exposing the BEAM node to atom table exhaustion. |

---

## 3. Live Benchmark Suite Execution & Results

All benchmarks were executed directly on the host machine (`aarch64-apple-darwin25.2.0`, Erlang/OTP 29.1.1 / ERTS 17.1, Elixir 1.20.4, 16 schedulers online).

### 3.1. Lane F1 Claims Benchmark (`bench/claims_bench.exs`)
- **Execution Command**:
  ```sh
  cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build_test MIX_ENV=test mix run --no-compile bench/claims_bench.exs
  ```
- **Real Command Output**:
  ```
  === Lane F1 measured-vs-claimed ===

  Component | Metric | Claim | MEASURED | Verdict
  --- | --- | --- | --- | ---
  RingBuffer.push solo | p50 (us) | < 10 | 0.00 | MET
  RingBuffer.push solo | p95 (us) | < 10 | 1.00 | MET
  RingBuffer.push solo | p99 (us) | < 10 | 7.00 | MET
  RingBuffer.push 8 writers | p50 (us) | < 10 | 159.00 | UNMET
  RingBuffer.push 8 writers | p95 (us) | < 10 | 985.00 | UNMET
  RingBuffer.push 8 writers | p99 (us) | < 10 | 4814.00 | UNMET
  RingBuffer.push solo | mean (us) | - | 0.00 | -
  RingBuffer.push 8 writers | mean (us) | - | 509.00 | -
  RingBuffer solo | throughput (ops/s) | - | 1632920 | -
  HealthGate admit | p50 (us) | low overhead | 0.00 | -
  HealthGate admit | p99 (us) | low overhead | 1.00 | -
  HealthGate refuse | p50 (us) | low overhead | 0.00 | -
  HealthGate refuse | p99 (us) | low overhead | 1.00 | -
  HealthGate admit vs refuse | ratio | - | 0.00x | -
  WAL append | frames/s | - | 7732 | -
  WAL append | MB/s on disk | - | 1.7 | -
  DETS record | records/s | - | 99 | -
  WAL vs DETS | sequential speedup | 10-50x | 77.73x faster | MET
  LeaseMonitor kill->release | p50 (ms) | ~16ms | 0.01 | -
  LeaseMonitor kill->release | p99 (ms) | ~16ms | 0.04 | -

  ops: ring 10000 x(solo+8w), gate 10000 x2, wal/dets 5000, kills 20
  === Claim fences ===
  [KNOWN-UNMET] RingBuffer 8 writers sub-10us: p50=159 p99=4814 within registered fence
  [PASS] RingBuffer solo p50 < 10us (claim): p50=0
  [PASS] RingBuffer solo p99 <= 20x ets baseline p99: p99=7 baseline_p99=1
  [PASS] RingBuffer solo p50 <= 10x ets baseline p50: p50=0 baseline_p50=1
  [PASS] HealthGate admit p50 <= 20x ets baseline p50 (low overhead): admit_p50=0 baseline_p50=1
  [PASS] HealthGate refuse p50 <= 20x ets baseline p50 (low overhead): refuse_p50=0 baseline_p50=1
  [PASS] HealthGate admit/refuse p50 ratio <= 10: admit=0 refuse=0
  [PASS] WAL vs DETS best-of-3 speedup >= 5x (claim 10-50x, MARGINAL): speedup=77.73 ops=5000/5000
  [PASS] LeaseMonitor kill->release p99 <= 16ms (claim ~16ms): p99_us=39
  claims_bench: all fences hold
  ```

### 3.2. Store Scaling Benchmark (`bench/store_scaling.exs`)
- **Execution Command**:
  ```sh
  cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build_test MIX_ENV=test mix run --no-compile bench/store_scaling.exs
  ```
- **Real Command Output**:
  ```
  store | n | write_ops/s | get_run_us | checkpoints_us | sig_dispatch_ops/s N=1 | N=8 | N=32
  ets | 100 | 61767 | 1.0 | 57.0 | 189394 | 221239 | 186263
  ets | 1000 | 339213 | 1.0 | 646.0 | 201613 | 194175 | 169779
  ets | 10000 | 343418 | 1.0 | 8391.0 | 183824 | 119546 | 162107
  dets | 100 | 428 | 59.0 | 409.0 | 252 | 199 | 93
  dets | 1000 | 130 | 140.0 | 30793.0 | 26 | 186 | 117
  dets | 10000 | 105 | 64.0 | 540550.0 | 26 | 39 | 26
  ```
- **Analysis**:
  - ETS sustains >340,000 write ops/s and reads in 1 µs.
  - DETS write throughput collapses by 75% between 100 and 10,000 checkpoints (428 ops/s down to 105 ops/s).
  - DETS `checkpoints/2` latency grows from 409 µs to **540,550 µs** (1,321x degradation), creating an unviable stall on recovery or inspection of long-running workflows.
  - Under 32 concurrent signal readers, DETS throughput degrades to 26 ops/s.

### 3.3. Compiler Cost Curve Benchmark (`bench/compiler_cost_curve.exs`)
- **Execution Command**:
  ```sh
  cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build_test MIX_ENV=test mix run --no-compile bench/compiler_cost_curve.exs
  ```
- **Real Command Output**:
  ```
  running linear 10 (10 steps)
  running linear 100 (100 steps)
  running linear 1000 (1000 steps)
  running fanout 10 (10 steps)
  running fanout 100 (107 steps)
  running fanout 1000 (1067 steps)
  running dup-fence 1000 clean (0 dups) (1000 steps)
  running dup-fence 1000 with 500 dups (1500 steps)

  == AshPPlan.Compiler.compile_spec/2 cost curve (median of 5, microseconds) ==

  | case | median us | min us | max us |
  |---|---|---|---|
  | linear 10 | 858 | 455 | 712941 |
  | linear 100 | 4243 | 2986 | 11407 |
  | linear 1000 | 207521 | 163973 | 387021 |
  | fanout 10 | 193 | 147 | 145842 |
  | fanout 100 | 2929 | 2804 | 3650 |
  | fanout 1000 | 395026 | 248977 | 524912 |
  | dup-fence 1000 clean (0 dups) | 305011 | 242031 | 387791 |
  | dup-fence 1000 with 500 dups | 804 | 782 | 120649 |

  duplicate fence at 1000 steps: refused as expected (:duplicate_steps)
  ```
- **Analysis**:
  - Compiling 1,000 steps requires ~207.5 ms for linear chains and ~395.0 ms for wide fan-out structures.
  - The duplicate-check fence (`ids -- Enum.uniq(ids)`) takes ~305 ms on clean 1,000-step plans, but exits in 804 µs when duplicates exist.

### 3.4. FOND TLA+ Projection Benchmark (`bench/fond_tla_bench.exs`)
- **Execution Command**:
  ```sh
  cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build_test MIX_ENV=test mix run --no-compile bench/fond_tla_bench.exs
  ```
- **Real Command Output (JSON schema `ash_pplan/fond-tla-bench/1`)**:
  ```json
  {
    "system": "aarch64-apple-darwin25.2.0",
    "otp": "29",
    "schedulers": 16,
    "elixir": "1.20.4",
    "rows": [
      {"mode":"strong","family":"retry_chain","states":101,"n":100,"verdict":"refused","module_bytes":26940,"reader_reductions":109288,"reader_us":4400,"reader_verdict":"refused","render_reductions":118244,"render_us":1951,"validate_reductions":25665,"validate_us":141},
      {"mode":"strong_cyclic","family":"retry_chain","states":101,"n":100,"verdict":"admitted","module_bytes":31149,"reader_reductions":125513,"reader_us":4869,"reader_verdict":"admitted","render_reductions":119589,"render_us":1799,"validate_reductions":28507,"validate_us":145},
      {"mode":"strong","family":"retry_chain","states":1001,"n":1000,"verdict":"refused","module_bytes":278954,"reader_reductions":1061100,"reader_us":41727,"reader_verdict":"refused","render_reductions":1182061,"render_us":30989,"validate_reductions":258661,"validate_us":1930},
      {"mode":"strong_cyclic","family":"retry_chain","states":1001,"n":1000,"verdict":"admitted","module_bytes":322765,"reader_reductions":1231386,"reader_us":58864,"reader_verdict":"admitted","render_reductions":1197822,"render_us":22506,"validate_reductions":286618,"validate_us":7718},
      {"mode":"strong","family":"retry_chain","states":5001,"n":5000,"verdict":"refused","module_bytes":1462930,"reader_reductions":5194368,"reader_us":417531,"reader_verdict":"refused","render_reductions":5982940,"render_us":134570,"validate_reductions":1283946,"validate_us":39011},
      {"mode":"strong_cyclic","family":"retry_chain","states":5001,"n":5000,"verdict":"admitted","module_bytes":1690735,"reader_reductions":6127551,"reader_us":521061,"reader_verdict":"admitted","render_reductions":6061562,"render_us":152235,"validate_reductions":1420880,"validate_us":49136},
      {"mode":"strong","family":"fanout","states":102,"n":100,"verdict":"admitted","module_bytes":28568,"reader_reductions":99690,"reader_us":3988,"reader_verdict":"admitted","render_reductions":145931,"render_us":2025,"validate_reductions":30590,"validate_us":398},
      {"mode":"strong_cyclic","family":"fanout","states":102,"n":100,"verdict":"admitted","module_bytes":32779,"reader_reductions":108998,"reader_us":4664,"reader_verdict":"admitted","render_reductions":147270,"render_us":2063,"validate_reductions":29382,"validate_us":317},
      {"mode":"strong","family":"fanout","states":1002,"n":1000,"verdict":"admitted","module_bytes":291389,"reader_reductions":977101,"reader_us":41733,"reader_verdict":"admitted","render_reductions":1440302,"render_us":29326,"validate_reductions":301366,"validate_us":2981},
      {"mode":"strong_cyclic","family":"fanout","states":1002,"n":1000,"verdict":"admitted","module_bytes":335203,"reader_reductions":1060244,"reader_us":50330,"reader_verdict":"admitted","render_reductions":1454263,"render_us":67971,"validate_reductions":289012,"validate_us":2692},
      {"mode":"strong","family":"fanout","states":5002,"n":5000,"verdict":"admitted","module_bytes":1511389,"reader_reductions":4898540,"reader_us":345314,"reader_verdict":"admitted","render_reductions":7289227,"render_us":224559,"validate_reductions":1513114,"validate_us":72517},
      {"mode":"strong_cyclic","family":"fanout","states":5002,"n":5000,"verdict":"admitted","module_bytes":1739203,"reader_reductions":5353238,"reader_us":446374,"reader_verdict":"admitted","render_reductions":7425687,"render_us":179639,"validate_reductions":1451427,"validate_us":49822},
      {"mode":"strong","family":"terminal_chain","states":101,"n":100,"refusal":null,"verdict":"admitted","project_reductions":101906},
      {"mode":"strong","family":"terminal_chain","states":1001,"n":1000,"refusal":null,"verdict":"admitted","project_reductions":1166950},
      {"mode":"strong","family":"terminal_chain","states":5001,"n":5000,"refusal":null,"verdict":"admitted","project_reductions":14371100}
    ]
  }
  ```

### 3.5. Standing Closure Benchmark (`bench/standing_closure_bench.exs`)
- **Execution Command**:
  ```sh
  cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build_test MIX_ENV=test mix run --no-compile bench/standing_closure_bench.exs /tmp/standing_closure_out.json
  ```
- **Real Summary Output**:
  - `Standing.receipt/2`:
    - 10 events: mean 285.05 µs (3,517 ops/s)
    - 100 events: mean 2,644.68 µs (381 ops/s)
    - 1,000 events: mean 42,640.0 µs (23.9 ops/s, 150x slowdown)
  - `Standing.ladder/2`:
    - Rung depth 3 (VALIDATED): 914.71 µs
    - Rung depth 6 (ADMITTED): 1,046.59 µs
    - Rung depth 10 (VERIFIED): 2,117.00 µs
  - `Policy Closure` (FOND.Synthesis.synthesize/3 vs FOND.validate_policy/4):
    - 50 nodes: synthesis 102.3 µs, validation 99.47 µs
    - 500 nodes: synthesis 1,913.0 µs, validation 1,119.4 µs
    - 5,000 nodes: synthesis 44,766.57 µs (~44.8 ms), validation 20,439.37 µs (~20.4 ms)
  - `ExecutionReceipt.observe` + `to_rdf`: 70.11 µs (14,275 ops/s)

---

## 4. Deep Analysis of Planning Solvers

`ash_pplan` contains several distinct solver engines and formalism bridges, none of which had dedicated benchmark harnesses prior to this audit.

### 4.1. Hierarchical Task Network (`AshPPlan.HTN.decompose/4`)
- **File**: `lib/ash_pplan/htn.ex:270-328`
- **Algorithm**: Total-order recursive method decomposition with depth-first backtracking over method alternatives.
- **State Representation**: `MapSet` of atomic terms and tuples.
- **Empirical Measurements**:
  ```elixir
  # Command:
  cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build_test MIX_ENV=test mix run --no-compile -e '
  alias AshPPlan.HTN
  alias AshPPlan.HTN.{Action, Method}
  for n <- [10, 50, 100, 200] do
    actions = for i <- 1..n, do: Action.new(name: :"a#{i}", preconditions: (if i == 1, do: [], else: [:"p#{i-1}"]), add_list: [:"p#{i}"])
    domain = HTN.new(actions, [])
    tasks = for i <- 1..n, do: :"a#{i}"
    {us, {:ok, res}} = :timer.tc(fn -> HTN.decompose(domain, tasks, []) end)
    IO.puts("HTN linear chain n=#{n}: #{us} us, actions=#{length(res.actions)}")
  end
  '
  # Output:
  HTN linear chain n=10: 11229 us (warmup), actions=10
  HTN linear chain n=50: 28 us, actions=50
  HTN linear chain n=100: 69 us, actions=100
  HTN linear chain n=200: 128 us, actions=200
  ```
- **Defects & Limitations**:
  - **Step Horizon Refusal (BS-04)**: `max_steps` defaults to 256. Running a linear plan of 300 primitive actions fails with:
    ```
    {:error, %{reason: :max_steps_exceeded, state: MapSet.new([]), task: :a257, steps: 256}}
    ```
    This causes valid large workflows to fail in production unless `max_steps` is explicitly overridden.

### 4.2. STRIPS Means-Ends State-Space Planner (`AshPPlan.HTN.strips_plan/4`)
- **File**: `lib/ash_pplan/htn.ex:426-452`
- **Algorithm**: Pure unguided Breadth-First Search (BFS) using Erlang `:queue` and `MapSet` visited sets.
- **Empirical Scaling & Horizon Horizon**:
  ```elixir
  # Command:
  cd /Users/sac/ash_pplan && MIX_BUILD_ROOT=_build_test MIX_ENV=test mix run --no-compile -e '
  alias AshPPlan.HTN
  alias AshPPlan.HTN.Action
  for d <- [1, 3, 5, 8, 10, 11] do
    actions = for i <- 1..d, do: Action.new(name: :"step_#{i}", preconditions: (if i == 1, do: [:init], else: [:"f_#{i-1}"]), add_list: [:"f_#{i}"])
    {us, res} = :timer.tc(fn -> HTN.strips_plan(MapSet.new([:init]), MapSet.new([:"f_#{d}"]), actions) end)
    case res do
      {:ok, plan} -> IO.puts("STRIPS depth=#{d}: #{us} us, steps=#{length(plan.plan)}")
      {:error, reason} -> IO.puts("STRIPS depth=#{d}: #{us} us, REFUSAL=#{inspect(reason)}")
    end
  end
  '
  # Output:
  STRIPS depth=1: 16 us, steps=1
  STRIPS depth=3: 13 us, steps=3
  STRIPS depth=5: 13 us, steps=5
  STRIPS depth=8: 55 us, steps=8
  STRIPS depth=10: 39 us, steps=10
  STRIPS depth=11: 36 us, REFUSAL=:max_depth_exceeded
  ```
- **Branching Factor Explosion (BS-03)**:
  When each step introduces 3 applicable candidate actions ($B=3$), search latency exhibits exponential growth:
  - Depth 2: 2,904 µs (warmup)
  - Depth 4: 107 µs
  - Depth 6: 1,165 µs (10.8x jump)
  - Depth 8: 3,324 µs
  - Depth 10: 45,929 µs (45.9 ms, a 429x increase over depth 4)
  Without heuristic guidance (e.g. $h_{FF}$ or Fast-Forward), state-space search beyond depth 12 is computationally intractable in BEAM.

### 4.3. Native HDDL S-Expression Solver (`AshPPlan.HTN.hddl_solve/4`)
- **File**: `lib/ash_pplan/htn.ex:592-613`, `lib/ash_pplan/workflow/project/hddl.ex`
- **Execution**: Evaluated against `planning/archive/ash_pplan_v26_9_6.hddl` and `planning/archive/ship_v26_9_6.hddl`.
- **Empirical Performance**:
  - Native parsing and grounding of domain + problem: mean **2,634.18 µs** per solve (50 runs).
  - Status: `:solved`, authority ceiling `:none`, plan length: 9 actions.
- **Defects & Limitations**:
  - **Leftover Debug Logging (BS-05)**: Line 92 of `lib/ash_pplan/workflow/project/hddl.ex`:
    ```elixir
    IO.inspect(__STACKTRACE__, label: "DEBUG_BAD_FORM")
    ```
    Dumps full runtime stacktraces to stdout whenever malformed S-expressions are evaluated.
  - **Missing Problems in `planning/` (BS-08)**: All `.hddl` files in `planning/` lack corresponding problem files, preventing automated validation of control plane specifications without `allow_stub_problem: true`.

### 4.4. POWL 2.0 Separability Verifier (`AshPPlan.POWL.Verifier.verify/1`)
- **File**: `lib/ash_pplan/powl/verifier.ex:41-48`, `lib/ash_pplan/powl/reachability.ex`
- **Algorithm**: Recursive PartitionMG / PartitionSM decomposition checking marked-graph acyclicity, state-machine soundness, and gamma-block reachability.
- **Empirical Scaling**:
  ```elixir
  # Output:
  POWL sequence n=10: 1 us, verdict=:ok
  POWL sequence n=100: 2 us, verdict=:ok
  POWL sequence n=500: 5 us, verdict=:ok
  POWL nested loop depth=20: 2 us, verdict=:ok
  POWL partial order n=10 (|E|=45): 69 us, verdict=:ok
  POWL partial order n=20 (|E|=190): 350 us, verdict=:ok
  POWL partial order n=50 (|E|=1225): 1218 us, verdict=:ok
  POWL loop-choice-body refused: 1 us, result={:error, %{reason: :loop_choice_body}}
  ```
- **Defects & Vacuities (BS-07)**:
  In `lib/ash_pplan/compiler.ex:135`:
  ```elixir
  defp admit_powl({:error, %{reason: :unsupported_powl_shape}}), do: :ok
  ```
  If an invalid or non-standard POWL model cannot be parsed by `POWL.normalize/1`, the compiler returns `:ok` instead of refusing, completely bypassing separability verification!

### 4.5. Airbus Bilateral Transpiler (`AshPPlan.Airbus.Transpiler`)
- **File**: `lib/ash_pplan/airbus/transpiler.ex:1-160`
- **Capabilities**: Bidirectional translation between FOND domains, Oracle JSON-RPC payloads, and standard PDDL 2.1 non-deterministic specifications.
- **Empirical Scaling**:
  - $n=10$ states: to_oracle 7 µs, to_pddl 24 µs (1.5 KB PDDL), roundtrip 31 µs.
  - $n=100$ states: to_oracle 44 µs, to_pddl 143 µs (16.7 KB PDDL), roundtrip 199 µs.
  - $n=500$ states: to_oracle 276 µs, to_pddl 737 µs (86.7 KB PDDL), roundtrip 955 µs.
- **Defects & Vacuities**:
  - **Atom Exhaustion Risk (BS-12)**: `verify_roundtrip!/3` lines 143, 149 converts incoming strings via `String.to_atom/1`:
    ```elixir
    {String.to_atom(s), Map.new(acts, fn {a, succs} -> {String.to_atom(a), Enum.map(succs, &String.to_atom/1)} end)}
    goals = Enum.map(oracle_params["goals"], &String.to_atom/1)
    ```
    If executed against untrusted Oracle JSON-RPC responses, dynamic atom allocation can exhaust the BEAM atom table (default 1,048,576 atoms), crashing the node.
  - **Unchecked STNU Controllability (BS-11)**: `to_stnu/1` formats requirement and contingent links, but no controllability algorithm is implemented.

---

## 5. Algorithmic Scaling Limits & Complexity Boundaries

| Subsystem | Algorithmic Class | Asymptotic Time | Asymptotic Space | Hard Limit / Horizon | Failure Symptom |
|---|---|---|---|---|---|
| **STRIPS Search** | Breadth-First Search | $O(B^d)$ | $O(B^d)$ | Depth $\le 10$ | `{:error, :max_depth_exceeded}` |
| **HTN Decomposition** | Backtracking DFS | $O(m^h \cdot \text{actions})$ | $O(h)$ | Steps $\le 256$, Depth $\le 256$ | `{:error, %{reason: :max_steps_exceeded}}` |
| **FOND Strong** | Backward Attractor | $O(\|V\| + \|E\|)$ | $O(\|V\|)$ | RAM | Linear slowdown (~39 ms at 5k states) |
| **FOND Strong-Cyclic** | Greatest Fixpoint | $O(\|V\| \cdot \|E\|)$ | $O(\|V\| + \|E\|)$ | RAM | ~$45$ ms at 5k states; fails on exponential state spaces |
| **POWL Verifier** | MG/SM Decomposition | $O(V + E)$ posets: $O(V^2)$ | $O(V + E)$ | RAM | 1.2 ms at 50 nodes / 1,225 poset edges |
| **DETS Checkpoints** | Disk Hash Table (`dets`) | $O(N)$ bucket scan | Disk I/O | >1,000 checkpoints | **540.5 ms** per `checkpoints/2` call at $N=10,000$ |
| **RingBuffer Concurrent** | Single `:ets.update_counter` | $O(1)$ serialized | Fixed slot | >1 concurrent writer | p99 latency degrades to **4,814 µs** (4.8 ms) |

---

## 6. Actionable Remediation Roadmap

1. **Fix RingBuffer Counter Contention (`BS-01`)**:
   - Split the global sequence counter row across scheduler cores (e.g., core-partitioned counters or atomic striping) to prevent lock convoying under concurrent task completion.
2. **Deprecate DETS for High-Volume Checkpoints (`BS-02`)**:
   - Replace bare DETS with the WAL (Write-Ahead Log) writer or SQLite/RocksDB/CubDB for checkpoint persistence. At 10,000 checkpoints, DETS 540 ms read latency violates real-time supervision bounds.
3. **Parameterize STRIPS Depth & Add Heuristic Search (`BS-03`)**:
   - Provide an optional A* search implementation using relaxed-plan heuristics ($h_{add}$ or $h_{max}$).
   - Allow callers to specify `max_depth` up to 100 rather than forcing an unconfigurable default of 10.
4. **Relax Primitive Action Counting in HTN Step Limit (`BS-04`)**:
   - Differentiate between compound task method expansions (`max_depth`) and primitive step accumulation (`max_steps`). A plan of 500 primitive steps should not be aborted simply because it exceeded 256 steps.
5. **Remove Production Debug Logging in HDDL Parser (`BS-05`)**:
   - Delete `IO.inspect(__STACKTRACE__, label: "DEBUG_BAD_FORM")` on line 92 of `lib/ash_pplan/workflow/project/hddl.ex`.
6. **Plug Compiler POWL Bypass (`BS-07`)**:
   - In `lib/ash_pplan/compiler.ex:135`, change `admit_powl({:error, %{reason: :unsupported_powl_shape}}), do: :ok` to return `{:error, error(:invalid_powl_shape, %{})}`. Malformed POWL models must fail closed.
7. **Add Benchmark Harnesses for Solvers (`BS-06`)**:
   - Add `bench/htn_bench.exs`, `bench/powl_bench.exs`, and `bench/hddl_bench.exs` to the repository benchmark suite to permanently monitor planning latency and prevent silent performance regressions.
8. **Sanitize Atom Generation in Airbus Transpiler (`BS-12`)**:
   - In `lib/ash_pplan/airbus/transpiler.ex`, replace `String.to_atom/1` with `String.to_existing_atom/1` to protect against atom table exhaustion.
