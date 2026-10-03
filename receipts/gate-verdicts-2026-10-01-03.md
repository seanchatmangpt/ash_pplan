# Gate verdicts distilled from tmp gate logs (promoted 2026-10-03)

Provenance: distilled from /Users/sac/ash_pplan/tmp/gate-d4.log (2026-10-01 18:55) and
/Users/sac/ash_pplan/tmp/gate-p1p1-rerun.log (2026-10-02 14:09); raw logs deleted as transient.

- gate-d4 (2026-10-01): package compiles from its own contents (ash_pplan-26.10.1, 134 files);
  `PASS verify-package`, `PASS receipt`; **GATE FAILED: "mix check manufacture leaves generated
  source unchanged"** (broken-pipe noise from bin/demonstrate in the same run).
- gate-p1p1-rerun (2026-10-02): `PASS receipt`; **GATE FAILED: mix format --check-formatted +
  ggen-verify (fail-closed pack verify)** — full verify envelopes were in tmp/ggen-verify/.
Both failures are historical (post-dated by pack/ontology fixes in the 26.10.x series); retained
as verdict evidence only.
