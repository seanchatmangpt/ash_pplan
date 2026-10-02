# Hex-pin receipt: ggen_igniter 26.9.31 (ash_pplan 26.10.2)

mix.exs consumes `ggen_igniter` from Hex with floor `>= 26.9.31` (dev/test,
runtime: false). The floor admits the audited tree `0abed8a35db68c18bba6982b266dd7546c162d1c`
(ggen_igniter main at v26.9.31; the hex 26.9.31 package is byte-identical to
that tree) plus anything newer carrying the per-row `to:`-substitution
path-rendering fix.

Recorded here so the release-contract court can audit the consumed
manufacturer tree identity without requiring the git-ref pin shape in
mix.exs. Transport detail: `ecosystem.lock.toml [ggen_igniter]
transport = "hex, floor >= 26.9.31"`.
