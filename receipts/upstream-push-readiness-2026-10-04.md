# Upstream Push-Readiness Receipt — 2026-10-04

Scope: three local upstream branches, read-only audit. No git state changes made.

| # | Repo | Branch | Tip | Verified |
|---|------|--------|-----|----------|
| 1 | ggen-marketplace | `errc-promote-engine-compat-gates` | `a1c3de3cd` | `git log -1` |
| 2 | ggen-marketplace | `errc-promote-workflow-pack-and-ashext-template` | `9b961d454` | `git log -1` |
| 3 | ggen_igniter | `errc-igniter-envelope-and-chain-fixes` | `d636106` | `git log -1` |

All three SHAs match the task's expected tips exactly.

## Branch 1 — errc-promote-engine-compat-gates @ a1c3de3cd

- Single commit on top of `503af6c27`; diff scope exactly **8 gate files, +13/-11** (5 evidence-standing-pack gates, 3 state-transition-pack gates) — matches claim.
- All 8 gate files at `a1c3de3cd` are EXISTS-free (grep for `FILTER (NOT )?EXISTS`: zero hits) — the sparql.ex 0.3.12 compat rewrites (MINUS / OPTIONAL+BOUND) are complete on the branch.
- R0 decision recorded: `ggen_igniter/docs/architecture/adr/0010-gate-convention-directory-is-convention.md` exists in the ggen_igniter working tree, contains the "## PR description text" section (lines 72–106) naming `ECO-GATE-CONVENTION-DECISION.md` (Option A, 2026-10-10... actually 2026-10-04), the misfiled-offender inventory (evidence-standing 8, state-transition 3; 111 gates / 66 unbound / 10 contracts), and a copy-as-is PR body for this exact branch.
- **Gap (informational)**: the ADR 0010 file and `ash_pplan/docs/jira/ECO-GATE-CONVENTION-DECISION.md` are both **untracked working-tree files** (igniter: `?? docs/architecture/adr/0010-...`; ash_pplan: `?? docs/jira/ECO-GATE-CONVENTION-DECISION.md`). The R0 decision is recorded in content but not committed in any repo. The PR body cites the ash_pplan path; the PR is mergeable without it, but a committed citation target should land in ash_pplan before/with merge.
- **Verdict: READY. Blockers: none for content. Push requires user authorization (AWAITING-USER).**

## Branch 2 — errc-promote-workflow-pack-and-ashext-template @ 9b961d454

3 commits: `f173b150c` (publish workflow pack), `e6496435b` (ash-extension-core 0.1.2 template port), `9b961d454` (R2 sync).

- Ontology re-validation (this session): `git show 9b961d454:packs/ash-pplan-workflow-pack/ontology.ttl` parses in rdflib, **1041 triples** — matches claim. Header-stripped (tail -n +5) SHA-256 = `cd212e7bd242d978fce18c5ac7640d63ac137377226761ea05a02fa0468208c8`, byte-identical to `ash_pplan:priv/ggen/ash-pplan-workflow-pack/ontology.ttl` (the canonical committed pack copy; diff of header-stripped bytes = empty).
- DERIVED_ROWS contract ported: `verify/cardinality.json` diff on `9b961d454` shows the VALUES→DERIVED_ROWS switch.
- Note: `ash_pplan` repo-root `ontology.ttl` header-stripped hash is now `aaaf310c...` (working tree has an uncommitted +717-line change and pack root hash moved past `cd212e7b`). This does NOT affect this branch — the branch is pinned to the pack copy at `cd212e7b`, which is intact and committed at `c40c04b9` in ash_pplan.
- **Verdict: READY. Blockers: none. AWAITING-USER push authorization.**

## Branch 3 — ggen_igniter errc-igniter-envelope-and-chain-fixes @ d66106 (d636106)

2 commits ahead of main: `df6b0b9` (envelope `passed` unconditional + receipt `parent_hash` base_dir) and `d636106` (DERIVED_ROWS contract mode).
Diff vs main: 4 files, +348/-118 (`gate_verify.ex`, `reconcile_reactor.ex`, `ggen_igniter.verify` task, verify-task test).

- Static diff review confirms all three claimed changes are present: unconditional `data.gates.passed` emission (payload-not-verdict comment), `put_new_parent_hash/2` base_dir fix (rootless-honest migration note), full DERIVED_ROWS contract mode with typed refusals (`{:gate_derived_query, ...}`, `missing_query`/`invalid_query`, query/query_file mutual exclusion, +110 lines in gate_verify.ex, 4 new real-subprocess test cases).
- Re-run: commit message claims 9/9 green with `--include integration`. A live re-run of the branch's tests was attempted via `git archive` to scratch but the extraction command was refused by the PreToolUse topology hook, so the re-run is **witnessed at commit time (commit message claim), not re-witnessed this session**.
- Working tree of ggen_igniter is on `main` (2 untracked files: ADR 0010, `ard_prd.ttl.eex` template — both untracked, not on any branch).
- **Verdict: READY (with re-run gap). Blockers: none content-side. AWAITING-USER push authorization.**

## Push commands (when authorized)

```bash
# Branch 1 (independent; do first)
cd /Users/sac/ggen-marketplace
git push origin errc-promote-engine-compat-gates
gh pr create --base main --head errc-promote-engine-compat-gates \
  --title "gates: rewrite FILTER EXISTS/NOT EXISTS for sparql.ex 0.3.12 compat" \
  --body-file <(cat <<'EOF'
### Gate scoring convention decided: directory-is-convention (ADR 0010)
[...paste the "PR description text" block verbatim from
 ggen_igniter/docs/architecture/adr/0010-gate-convention-directory-is-convention.md lines 72-106 ...]
EOF
) --fill
```

```bash
# Branch 2
cd /Users/sac/ggen-marketplace
git push origin errc-promote-workflow-pack-and-ashext-template
gh pr create --base main --head errc-promote-workflow-pack-and-ashext-template \
  --title "pack: ash-pplan-workflow-pack 26.10.3 + ash-extension-core 0.1.2 template port (R2 sync)" \
  --body-file <(cat <<'EOF'
- f173b150c: publish ash-pplan-workflow-pack 26.10.3 (upstream promotion, ERRC E2 step 1)
- e6496435b: port the consumer vendor-time patch into the ash-extension-core-pack template (0.1.2)
- 9b961d454: R2 sync — ontology.ttl (header-stripped SHA-256 cd212e7b..., rdflib 1041 triples,
  byte-identical to ash_pplan priv/ggen/ash-pplan-workflow-pack/ontology.ttl);
  verify/cardinality.json VALUES -> DERIVED_ROWS (row count 18 == 18, closes the KNOWN STANDING refusal);
  templates/placeholder.tmpl added. Reactor gates re-verified upstream: 4/15/15/4.
EOF
) --fill
```

```bash
# Branch 3
cd /Users/sac/ggen_igniter
git push origin errc-igniter-envelope-and-chain-fixes
gh pr create --base main --head errc-igniter-envelope-and-chain-fixes \
  --title "verify: DERIVED_ROWS contract mode + envelope passed/parent_hash fixes" \
  --body-file <(cat <<'EOF'
Two fixes to the gate-verification path:

- df6b0b9: `data.gates.passed` in the verify envelope is emitted unconditionally
  (payload, never verdict); receipt `parent_hash` writer now passes base_dir so
  `put_new_parent_hash/2` fires and the receipt chain is no longer all-rootless
  (existing nil-parent receipts stay honestly rootless — no silent rewrite).
- d636106: DERIVED_ROWS contract mode — expected count expressed as a contract
  query over the same graph, fail-closed both directions (non-executing query =
  typed `{:gate_derived_query, name, msg}`; ambiguous query/missing file =
  load-time contract refusal). 4 new real-subprocess test cases; 9/9 green with
  --include integration at commit time.

Diff: 4 files, +348/-118. Companion: ADR 0010 (gate convention, R0 Option A).
EOF
) --fill
```

## Standing summary

| Branch | Content | Validation | Blockers |
|---|---|---|Push|
| 1 `a1c3de3cd` | READY | EXISTS-free all 8 gates (re-checked) | AWAITING-USER |
| 2 `9b961d454` | READY | rdflib 1041 triples, hash `cd212e7b` == pack copy (re-checked) | AWAITING-USER |
| 3 `d636106` | READY | 9/9 claimed at commit; re-run refused by topology hook (static diff review done) | AWAITING-USER |

---

## Update (late 2026-10-04)

Refresh after the latest wave. Read-only re-verification (git log/rev-parse/status/grep over
exact SHAs); no state changes, no pushes.

### Branch 1 — ggen_igniter `errc-igniter-envelope-and-chain-fixes`

- Tip moved: now **f960d25** (docs: GateVerify convention, ADR 0010) on top of d636106
  (DERIVED_ROWS) <- df6b0b9 (envelope passed/parent_hash) <- 90a5c63 (release v26.10.5).
  Chain re-read directly off the branch ref.
- **New blocker — igniter ADR 0010 doc is untracked**: `?? docs/architecture/adr/0010-gate-convention-directory-is-convention.md`
  in ggen_igniter `git status`. f960d25 references ADR 0010 but the doc itself is not committed
  to the branch. **Must be committed to the branch before push**, otherwise the PR lands with a
  dangling reference.
- (Also untracked in the igniter working tree, unrelated to this branch: `priv/ggen/semantic-jira-pack/templates/ard_prd.ttl.eex`.)
- Verdict: **READY-pending-ADR-commit**; push authorization AWAITING-USER.

### Branch 2 — ggen_marketplace `errc-promote-engine-compat-gates`

- Tip moved: now **c76220c2a** ("re-home offender gates per ADR 0010 — directory-is-convention")
  on top of a1c3de3cd (the EXISTS -> OPTIONAL/UNBOUND rewrites). Prior tip a1c3de3cd is an
  ancestor; nothing rewritten was lost.
- EXISTS-free re-verified at the new tip against the gates this branch actually touches
  (state-transition-pack + evidence-standing-pack): re-homed
  `packs/evidence-standing-pack/verify/*.unbound.rq` (010/060/065/070 checked) and retained
  gates `packs/state-transition-pack/gates/030_reachable_states.rq` / `040_chain_policy_supported.rq`
  — all EXISTS-free. (Repo-wide `FILTER [NOT] EXISTS` matches still exist elsewhere — pre-existing,
  untouched by this branch, out of scope.)
- Verdict: **READY**; push authorization AWAITING-USER.

### Branch 3 — ggen_marketplace `errc-promote-workflow-pack-and-ashext-template` @ 9b961d454

- Tip unchanged: **9b961d454** (pack R2 sync — ontology + DERIVED_ROWS contract).
- Drift note: ash_pplan root `ontology.ttl` has since moved well past what the branch pins
  (1041-family -> 1272-family triples per wave log; working tree now 37bc291-era courts work).
  The branch pins the **committed pack copy** at 9b961d454
  (`packs/ash-pplan-workflow-pack/ontology.ttl`), which is self-consistent — root drift is a
  follow-up sync, not a blocker for this PR.
- Verdict: **READY (with drift note)**; push authorization AWAITING-USER.

### Refreshed push/PR command bodies

```bash
# Branch 2
cd /Users/sac/ggen-marketplace
git push origin errc-promote-engine-compat-gates
gh pr create --base main --head errc-promote-engine-compat-gates \
  --title "gates: sparql.ex 0.3.12 compat + ADR 0010 gate re-homing (state-transition, evidence-standing)" \
  --body-file <(cat <<'PEOF'
Rewrite FILTER [NOT] EXISTS to sparql.ex 0.3.12-compatible forms across the
state-transition and evidence-standing packs, then re-home verification queries
out of gates/ into verify/*.unbound.rq per ADR 0010 (directory-is-convention),
with witnesses and cardinality.json per pack.

- a1c3de3cd: EXISTS-free rewrites (8 offender gates)
- c76220c2a: re-home offender gates per ADR 0010 + witnesses

Diff-verified at c76220c2a: all touched gate/verify queries EXISTS-free.
PEOF
) --fill

# Branch 3
cd /Users/sac/ggen-marketplace
git push origin errc-promote-workflow-pack-and-ashext-template
gh pr create --base main --head errc-promote-workflow-pack-and-ashext-template \
  --title "fix(pack): ash-pplan-workflow-pack R2 sync (ontology + DERIVED_ROWS) + ash-extension-core-pack 0.1.2" \
  --body-file <(cat <<'PEOF'
Upstream promotion of the ash-pplan-workflow-pack and ash-extension-core-pack
template port.

- f173b150c: publish ash-pplan-workflow-pack 26.10.3 (E2 step 1)
- e6496435b: ash-extension-core-pack 0.1.2 (vendor-time patch ported into template)
- 9b961d454: pack R2 sync — ontology + DERIVED_ROWS contract

Note: ash_pplan root ontology.ttl has moved past the pinned pack copy since;
pack copy at 9b961d454 is self-consistent. Root->pack re-sync is follow-up.
PEOF
) --fill

# Branch 1 (run AFTER committing the ADR doc to the branch)
cd /Users/sac/ggen_igniter
git add docs/architecture/adr/0010-gate-convention-directory-is-convention.md
git commit -F <(cat <<'PEOF'
docs: add ADR 0010 (gate convention, directory-is-convention)

Dangling reference from f960d25; commit the ADR body before push.
PEOF
)
git push origin errc-igniter-envelope-and-chain-fixes
gh pr create --base main --head errc-igniter-envelope-and-chain-fixes \
  --title "verify: DERIVED_ROWS contract mode + envelope passed/parent_hash fixes + ADR 0010" \
  --body-file <(cat <<'PEOF'
Gate-verification path fixes plus the convention doc they introduce.

- df6b0b9: unconditional `data.gates.passed` in verify envelope (payload, never
  verdict); receipt parent_hash writer passes base_dir so chain is no longer rootless.
- d636106: DERIVED_ROWS contract mode — expected count expressed as a contract
  query over the same graph, fail-closed both directions. 9/9 green with --include
  integration at commit time.
- f960d25 + ADR doc: GateVerify convention (ADR 0010), directory-is-convention.
PEOF
) --fill
```

### Standing summary (refreshed)

| Branch | Tip | Verdict | Blocker |
|---|---|---|---|
| 1 igniter | `f960d25` | READY-pending-ADR-commit | ADR 0010 doc untracked — commit to branch first; push AWAITING-USER |
| 2 marketplace | `c76220c2a` | READY | push AWAITING-USER |
| 3 marketplace | `9b961d454` | READY (drift note) | push AWAITING-USER |
