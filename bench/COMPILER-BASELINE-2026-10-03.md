# Compiler Cost Curve Baseline — 2026-10-03

BENCH lane. `AshPPlan.Compiler.compile_spec/2` compile cost vs plan size, real compile
path (same path as `test/compiler_refusal_test.exs`: fail-closed validation → topological
sort → `Reactor.Builder`), pass-through `Reactor.Step` no-op handlers.

# Reproduce

```sh
cd /Users/sac/ash_pplan
MIX_ENV=test MIX_BUILD_ROOT=_build-ch7 mix run bench/compiler_cost_curve.exs
```

In-script harness (5 samples/case, median/min/max reported, `:erlang.garbage_collect/0`
between samples). No new deps. Both runs below are complete raw outputs.

# Results (median of 5, microseconds)

| case | steps | run 1 med | run 2 med | run 1 min–max | run 2 min–max |
|---|---|---|---|---|---|
| linear chain 10 | 10 | 191 | 192 | 153–88872 | 170–28195 |
| linear chain 100 | 100 | 3450 | 2673 | 2632–4783 | 2599–2700 |
| linear chain 1000 | 1000 | 107355 | 106911 | 97849–112852 | 99196–110031 |
| wide fan-out 10 | 10 | 175 | 175 | 164–1854 | 165–4957 |
| wide fan-out 100 | 107 | 3332 | 3333 | 3278–3396 | 3206–3369 |
| wide fan-out 1000 | 1067 | 131664 | 136755 | 130781–142022 | 132210–140850 |
| dup-fence 1000 clean | 1000 | 110735 | 108777 | 100496–115385 | 98719–131681 |
| dup-fence 1000, 500 dup IRIs | 1500 | 834 | 1001 | 824–888 | 990–1366 |

# Reading

- Compile cost is superlinear: linear 10→100 is ~15x, 100→1000 is ~35x (well above the
  linear 10x/100x scaling). At 1000 steps compile is ~107 ms per plan.
- Fan-out shape costs ~25% more than a linear chain at 1000 steps (~132–137 ms vs
  ~107 ms). Both shapes sit in the same superlinear band.
- The duplicate-IRI fence (`ids -- Enum.uniq(ids)` in `validate_steps/1`) refuses cheaply:
  a 1500-step plan with 500 duplicate IRIs refuses in ~0.8–1.0 ms, before topological
  sort or builder work. The fence is not a compile-cost problem; superlinear builder /
  validation cost is.

# Contract notes observed while building the fixtures

- Terminal steps are capped at 16 (`:too_many_terminal_steps`), and each step binds at
  most 16 predecessors (bounded argument-name list), so wide shapes are funnel trees
  (16-ary joins down to ≤16 terminals).
- Duplicate predecessor edges (`[a, a]`) are deduped and bind once (documented in the
  refusal tests).

# Environment

- Elixir 1.19.5, OTP (mix), MIX_ENV=test, MIX_BUILD_ROOT=_build-ch7, macOS arm64.
- Two consecutive runs of the same script; same subject
  (`lib/ash_pplan/compiler.ex` as of working tree 2026-10-03).
