# Publish Dry Run — ash_pplan v26.10.1

Date: 2026-10-01 · Lane A5 · Branch `docs/diataxis-fanout` (HEAD d32cb9c) · MIX_BUILD_ROOT=_build-a5 · No git mutations, no `mix hex.publish` executed.

## Release Ladder

| Step | Command | Exit | Result |
|---|---|---|---|
| 1 | `mix deps.get --check-locked` | 0 | Resolution completed; 88 deps unchanged vs mix.lock |
| 2 | `mix hex.audit` | 0 | "No retired or security advisory packages found" |
| 3 | `mix format --check-formatted` | 0 | All files formatted |
| 4 | `mix compile --warnings-as-errors` | 0 | 134 files compiled, app generated, zero warnings |
| 5 | `./bin/verify-package` | 0 | Tarball built via `mix hex.build`, unpacked, `MIX_ENV=prod mix compile --warnings-as-errors` from its own contents passed: "package ash_pplan-26.10.1 compiles from its own contents" |

## Tarball Checksum

```
a99c09be2150a4f74c3bb4f5b2887938e1ee5778f5121ae2857acfe1c9e94fb3  ash_pplan-26.10.1.tar
```

(sha256, file at repo root, produced by `mix hex.build` inside `./bin/verify-package`.)

## Metadata Review (mix.exs package/2)

- licenses: `["MIT"]`, links: `{"GitHub" => @source_url}` — present, non-empty.
- files: `~w(lib priv bin ontology.ttl ontology planning docs ecosystem.lock.toml mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)`
- Verified against the built `contents.tar.gz`:
  - `lib/` — 135 paths including `lib/ash_pplan/generated/plan_catalog.ex`, `projection_catalog.ex`, and `lib/ash_pplan/reactor/durable/store/{ets,dets}.ex` (durable Store.Ets) — all present.
  - `priv/` — all runtime-read assets present: `priv/schemas/fond_replay.schema.json`, `fond_counterexample.schema.json`, all 6 ggen packs (workflow, ash-pplan, standing, durable-chaos, durable-tla, store-conformance) including gates/templates/bin, `priv/tla/durable/*` (.tla/.cfg/transitions.exs/model.rs), `priv/mappings/fond_tla_projection.json`.
  - `bin/`, `docs/`, `planning/`, `ontology/`, `ontology.ttl`, `ecosystem.lock.toml`, CHANGELOG/LICENSE/README/.formatter.exs all present.
- No runtime-read file is omitted: grep for `priv_dir`/`app_dir` in lib/ found no direct reads outside Application priv dir conventions; the only "receipts" string in lib/ is a doc comment. The prod-compile-from-tarball gate (step 5) is the stronger proof.

## Docs

`mix.exs` has **no `ex_doc` dependency and no `@docs`/docs configuration** — `mix docs` is not applicable. Package publishes without HTML docs on hexdocs.pm. Flagged, not fixed.

## RESERVED / Prerequisites (User-Gated)

1. **#1 PREREQUISITE — merge before publish.** The package builds from the working tree of branch `docs/diataxis-fanout` (HEAD d32cb9c), which carries 4 unpushed/unmerged commits. `mix hex.publish` releases working-tree content; publishing before the branch merges to `main` would ship unmerged content. Merge `docs/diataxis-fanout` → `main` first, then publish from `main` at the merge commit (re-verify checksum on main — it may change if the merge changes files).
2. Hex credential prerequisite: `mix hex.user` authenticated key with publish scope (`mix hex.docs` not needed without ex_doc; docs publish flag unnecessary).
3. Publish command: `mix hex.publish` (answer yes to confirm; hex will re-run `mix hex.build` and ask to publish docs if configured — decline docs or add ex_doc first).
4. After publish, verify checksum on hex matches `a99c09be...fb3` only if working tree is byte-identical to what was published (i.e., publish from the same tree as this dry run, post-merge from main may differ — recompute then).

## Falsifiers (how this receipt is wrong)

- Tarball checksum is of the .tar wrapper (hex.build output), not the contents.tar.gz; hex computes its own checksum at publish.
- Step 5's prod compile reuses local deps via copy — it proves package contents compile, not dependency resolution from scratch.
- Checksum taken 2026-10-01 on this tree; any subsequent file change invalidates it.
