# Gate Receipt: Full-Suite Gate 2026-10-04b

- **Subject**: /Users/sac/ash_pplan, branch main, HEAD at gate start 9a89aac (+ uncommitted tree per `git status` snapshot)
- **Command**: `MIX_BUILD_ROOT=_build-gate-full mix compile --warnings-as-errors && MIX_BUILD_ROOT=_build-gate-full mix test`
- **Log**: /tmp/gate_full_20261004b.log (1913 lines, both runs)

## Results

| step | exit | note |
|---|---|---|
| mix compile --warnings-as-errors | 0 | PASS — ash_pplan + all deps compiled clean, no warnings escalated |
| mix test | 1 | BLOCKED — test-suite compile error before any test executed |

## Test counts

**None.** Zero tests ran in either attempt (`grep -c "Finished in"` → 0). The ExUnit
runner never started: `mix test` compiles the test tree first and died there.

## Failure (verbatim)

Both the initial run and the 5-minute retry produced the identical error:

```
== Compilation error in file test/petal_framework/demo_graph/deps/phoenix/priv/templates/phx.gen.auth/settings_controller_test.exs ==
** (SyntaxError) invalid syntax found on test/petal_framework/demo_graph/deps/phoenix/priv/templates/phx.gen.auth/settings_controller_test.exs:1:13:
    error: syntax error before: '='
    │
  1 │ defmodule <%= inspect context.web_module %>.<%= inspect Module.concat(schema.web_namespace, schema.alias) %>SettingsControllerTest do
    │             ^
    │
    └─ test/petal_framework/demo_graph/deps/phoenix/priv/templates/phx.gen.auth/settings_controller_test.exs:1:13
    (elixir 1.19.5) lib/kernel/parallel_compiler.ex:648: Kernel.ParallelCompiler.require_file/2
    (elixir 1.19.5) lib/kernel/parallel_compiler.ex:531: Kernel.ParallelCompiler.spawn_workers/8
TEST_EXIT=1
```

## Blocker classification

Not a lane flake — deterministic tree state, retry did not clear it:

- `test/petal_framework/` is **untracked** (`?? test/petal_framework/`) — a demo-clone
  artifact from a concurrent lane (mix.exs:73 comment says "The test/petal_framework clone
  stays on disk as the NetworkGraph hook's dev home but is no longer a dep").
- Its vendored Phoenix copy `test/petal_framework/demo_graph/deps/phoenix/priv/templates/phx.gen.auth/settings_controller_test.exs`
  is an EEx **generator template** (contains `<%= %>` at line 1, col 13), which can never
  compile as Elixir. `mix test` globs the entire `test/` tree, so the vendored template is
  picked up and kills the suite at the compile stage.
- No `demonstration` tag exists (`test/test_helper.exs` is a bare `ExUnit.start()`), so the
  `--exclude demonstration` fallback was not applicable.

## Retry

One retry after 5 minutes per protocol: `git status --porcelain test/petal_framework` still
`??`, file still present, second `mix test` → identical SyntaxError, `TEST_EXIT=1`.

## Cleanup

`rm -rf _build-gate-full` → OK (directory confirmed absent after).

## Standing

**BLOCKED (test-suite-compile-blocker, vendored-template-in-test-tree)**

The gate cannot certify the full suite until either (a) the `test/petal_framework/` clone
is removed from the canonical checkout, or (b) the test glob excludes it (e.g. rename to a
non-`.exs`-matched location or configure `test_paths`/`test_pattern` in mix.exs). No source
or test file was modified (read-only gate lane).
