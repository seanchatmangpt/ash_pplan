# Gate Receipt: workflow + execution_receipt tests — 2026-10-04

Lane: read-mostly verification lane (`_build-gate-wf` build root, deleted after).

## Commands and exits

1. `MIX_BUILD_ROOT=_build-gate-wf mix compile --warnings-as-errors` → **exit 0**
   (fresh build of full dep tree + ash_pplan, no errors; third-party deps emitted
   deprecation warnings only, all outside ash_pplan sources)
2. `MIX_BUILD_ROOT=_build-gate-wf mix test test/workflow/ test/execution_receipt_test.exs` → **exit 2**

## Test counts

`359 tests, 1 failure` (Finished in 47.2 seconds; 4.2s async, 43.0s sync)

## Failure (verbatim, from rerun for capture)

```
  1) test adapter is registered and always available (AshPPlan.Workflow.DurableAdapterTest)
     test/workflow/durable_adapter_test.exs:29
     Assertion with == failed
     code:  assert Enum.sort(Durable.ops()) == Enum.sort(Map.keys(@ops))
     left:  [:event_await, :human_approve, :schedule_deferred,
             :scheduling_deferred, :scheduling_wakeup, :state_await,
             :workflow_dispatch]
     right: [:event_await, :human_approve, :schedule_deferred,
             :scheduling_deferred, :state_await, :workflow_dispatch]
     stacktrace:
       test/workflow/durable_adapter_test.exs:33: (test)
```

Diagnosis (observation only, no fix applied per lane constraints): the Durable
adapter registers op `:scheduling_wakeup` which is absent from the test's
`@ops` expectation list. The failure reproduced identically on both runs.

## Retry policy

Compile succeeded first attempt; no retry needed.

## Cleanup

`rm -rf _build-gate-wf` → OK, directory confirmed gone.

No git commands run. No source/test files edited.
