# Receipt: Elixir Floor Enablement — 2026-10-04

## Identity

- Repo: `/Users/sac/ash_pplan` (canonical checkout). **Zero repo file edits; no git commands.**
- Gate step that currently SKIPs: `mix test on the declared Elixir floor` (`bin/gate:321-328`) —
  runs only when `elixir --version` reports `^Elixir 1\.17\.` on PATH.
- One receipt file written, per lane contract: this file.

## Enabling Actions

- Version managers: `asdf 0.20.0` at `/opt/homebrew/bin/asdf` present; `mise`/`rtx` absent.
- asdf already had `erlang 27.2.4` installed. Elixir 1.17 supports OTP 26/27; OTP 27 kept
  (consistent with the existing `1.18.4-otp-27` install).
- Installed `elixir 1.17.3-otp-27` via `asdf install elixir 1.17.3-otp-27`
  (precompiled zip, 7196 KB download, finished with "Copying release into place").
- Repo `.tool-versions` NOT touched (read-only mandate). Toolchain selected by prepending
  asdf install bin dirs to PATH:
  `/Users/sac/.asdf/installs/erlang/27.2.4/bin` and
  `/Users/sac/.asdf/installs/elixir/1.17.3-otp-27/bin`.
- Verified before the run: `Elixir 1.17.3 (compiled with Erlang/OTP 27)` on
  `Erlang/OTP 27 [erts-15.2.2]`.
- First background attempt was killed at the harness 10-minute background cap mid
  dep-compile; resumed in the same `MIX_BUILD_ROOT=_build-floor-20261004` and completed.
  97 dependency libraries compiled from scratch on 1.17.3 before ash_pplan itself.

## Floor Run (exact bin/gate step semantics)

Command: `MIX_ENV=test MIX_BUILD_ROOT=_build-floor-20261004 mix test` — the command the gate's
floor step runs (`step "mix test on the declared Elixir floor" mix test`), isolated to a fresh
build root so the main 1.20.4 toolchain's `_build` was untouched.

**Result: FAIL at compilation — the test suite never ran.** Two findings surfaced.

### Finding 1 — Elixir-1.19-only API in test support (warning at compile, crash at runtime)

Verbatim:

```
    warning: Enum.sum_by/2 is undefined or private. Did you mean:

          * max_by/2
          * max_by/3
          * max_by/4
          * min_by/2
          * sum/1

    │
 63 │       |> Enum.sum_by(& &1.amount)
    │               ~
    │
    └─ test/support/marketplace_sim/vendor/metering_server.ex:63:15: Vendor.MeteringServer.handle_call/3

    warning: Enum.sum_by/2 is undefined or private. Did you mean:

          * max_by/2
          * max_by/3
          * max_by/4
          * min_by/2
          * sum/1

    │
 71 │         {ent, Enum.sum_by(events, & &1.amount)}
    │                    ~
    │
    └─ test/support/marketplace_sim/vendor/metering_server.ex:71:20: Vendor.MeteringServer.handle_call/3
```

`Enum.sum_by/2` was added in Elixir 1.19. On 1.17 it warns here and would crash at runtime
whenever `Vendor.MeteringServer.handle_call/3` runs.

### Finding 2 — vendored EEx template matches the `*_test.exs` glob (fatal on 1.17)

Verbatim, complete:

```
warning: test/petal_framework/demo_graph/deps/phoenix/lib/phoenix/test/channel_test.ex does not match "*_test.exs" and won't be loaded
warning: test/petal_framework/demo_graph/deps/phoenix/lib/phoenix/test/conn_test.ex does not match "*_test.exs" and won't be loaded
warning: test/petal_framework/demo_graph/deps/phoenix_live_view/lib/phoenix_live_view/test/live_view_test.ex does not match "*_test.exs" and won't be loaded

== Compilation error in file test/petal_framework/demo_graph/_build-pfw-demo/dev/lib/phoenix/priv/templates/phx.gen.auth/settings_live_test.exs ==
** (SyntaxError) invalid syntax found on test/petal_framework/demo_graph/_build-pfw-demo/dev/lib/phoenix/priv/templates/phx.gen.auth/settings_live_test.exs:1:13:
    error: syntax error before: '='
    │
  1 │ defmodule <%= inspect context.web_module %>.<%= inspect Module.concat(schema.web_namespace, schema.alias) %>SettingsLiveTest do
    │             ^
    │
    └─ test/petal_framework/demo_graph/_build-pfw-demo/dev/lib/phoenix/priv/templates/phx.gen.auth/settings_live_test.exs:1:13
    (elixir 1.17.3) lib/kernel/parallel_compiler.ex:543: Kernel.ParallelCompiler.require_file/2
    (elixir 1.17.3) lib/kernel/parallel_compiler.ex:431: anonymous fn/5 in Kernel.ParallelCompiler.spawn_workers/8
```

This is an EEx template (`<%= ... %>`) committed under
`test/petal_framework/demo_graph/_build-pfw-demo/...` whose filename ends in `_test.exs`.
Elixir 1.17's `mix test` attempts to compile it as Elixir source and dies; 1.19/1.20 do not
load it (that is why the main toolchain passes the same step).

## Standing

BLOCKED. Toolchain enablement itself SUCCEEDED (1.17.3-otp-27 installed and verified; 97 deps
compile). The floor gate step is not enableable until the repo fixes two real 1.17
incompatibilities, both in test-only code:

1. `Enum.sum_by/2` at `test/support/marketplace_sim/vendor/metering_server.ex:63,71` —
   replace with 1.17-compatible code.
2. `test/petal_framework/demo_graph/_build-pfw-demo/dev/lib/phoenix/priv/templates/phx.gen.auth/settings_live_test.exs` —
   an EEx template matching the `*_test.exs` test glob; exclude/relocate/rename it (it is
   inside a committed demo `_build` tree).

Per lane mandate, both were captured verbatim, not fixed. Enabling the floor step requires a
repo edit outside this lane's read-only constraint.
