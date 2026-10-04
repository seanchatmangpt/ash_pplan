# FLEET-BASELINE

Generated: 2026-10-04T03:21:56Z. Deltas are bands vs the previous JSON snapshot when one exists (note: mixed machine load; treat small deltas as noise).

| repo | version | compile | tests | failures | bench |
|---|---|---|---|---|---|
| ex4pm | 26.10.2 | ok | 887 | 0 | no bench |
| ash_ex4pm | 26.10.3 | ok | 131 | 0 | no bench |
| beam4pm | 26.10.1 | ok | 1693 | 3 | skipped (tests failed or timed out) |
| xaas | 26.10.2 | ok | 3068 | 7 | skipped (tests failed or timed out) |
| ash_graphlaw | 26.10.1 | ok | 975 | 0 | no bench |
| ash_affidavit | 26.10.1 | ok | 100 | 0 | no bench |
| ash_surface | 26.10.1 | ok | 1200 | 0 | no bench |
| ash_pplan | 26.10.3 | ok | TIMEOUT@20min | 0 | skipped (tests failed or timed out) |
| ash_r2rml | 26.9.28 | ok | 998 | 0 | ok (/Users/sac/ash_r2rml/bench/compilation_and_rendering.exs) |
| ash_a2a | 26.10.2 | ok | 2669 | 6 | skipped (tests failed or timed out) |

## Bench deltas vs previous run (bands)

| repo | bench script | delta |
|---|---|---|
| ash_r2rml | /Users/sac/ash_r2rml/bench/compilation_and_rendering.exs | see log excerpt in JSON |

Bench timing deltas require benchee-style JSON output per repo; raw logs are under bench/fleet/logs/. Load conditions (parallel lane builds, other processes) are not controlled here — treat sub-10% deltas as noise.
