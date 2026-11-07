# MANIFEST — airbus_parity corpus

Standing: PASS

Source: unified-planning (UP) 1.3.0 bundled test PDDL, Apache-2.0.
Package path: `unified_planning/test/pddl/<case>/` and `unified_planning/test/contingent_pddl/<case>/`,
copied verbatim into `priv/courts/airbus_parity/corpus/`.

## Corpus census

14 PDDL pair cases (31 .pddl files), all gates exit 0 (run 2026-11-07,
`scripts/.venv/bin/python scripts/airbus_to_pplan.py`).

| case | kind | gate |
|---|---|---|
| pddl/car_nl | sequential | PASS (46 triples) |
| pddl/citycar | sequential | PASS (74) |
| pddl/counters | sequential | PASS (17) |
| pddl/depot | sequential | PASS (83) |
| pddl/matchcellar | durative | PASS (29) |
| pddl/miconic | sequential | PASS (63) |
| pddl/parking_action_cost | durative | PASS (56) |
| pddl/robot_fastener | durative | PASS (28) |
| pddl/safe_road | sequential | PASS (14) |
| pddl/sailing | sequential | PASS (51) |
| pddl/tpp_metric | sequential | PASS (36) |
| pddl/visit_precedence | durative | PASS (15) |
| contingent_pddl/colorballs | contingent | PASS (47) |
| contingent_pddl/logistic_conf | contingent | PASS (87) |

Pre-existing root-level singles (not UP-sourced, excluded from the pair gate):
`aog_turnaround.hddl`, `avionics_bay.po.pddl`, `composite_cure.stnu`,
`fastener_torque.fond.pddl`.

The register of truth is the gate run output plus the 14 .ttl files on disk
under `transpiled/`.
