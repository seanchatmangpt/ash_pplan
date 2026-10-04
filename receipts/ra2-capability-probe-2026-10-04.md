# RA2 Capability Probe Receipt — 2026-10-04

READ-ONLY probe lane, `/Users/sac/ash_pplan` @ main (9a89aac dirty). ggen v26.9.28.
No files modified; no git commands run. Only file written: this receipt.

## Question

Prior audit: `ggen capability inspect` would make the hand-maintained pack lists in 3
bin scripts derivable + typo-refusing — but only if ash_pplan's packs register as a
capability surface. Probe that premise.

## 1. What a capability surface is

`ggen capability` (help output, ggen v26.9.28) exposes four verbs: `inspect`, `list`,
`enable`, `help`. A capability surface maps to "atomic packs" via
`resolve_capability_to_packs()` in
`/Users/sac/ggen/crates/ggen-marketplace/src/packs_registry/capability_registry.rs`.

Decisive finding: the surface→packs mapping is a **hardcoded `match` statement** on 7
marketplace surfaces (`mcp`, `compliance-soc2`, `web`, `devops`, `data-science`,
`startup`, `enterprise`). There is no project-local registration path:
- No `[capability]` section in `ggen.toml` (grep: zero hits).
- No capability declarations in installed pack manifests (`~/.ggen/packs/*/pack.toml`
  carry only `[pack]` id/version/installed_at; grep "capabilit" = zero hits).
- `ggen capability enable` only records an *already-registered* surface's expansion
  into the project lockfile; it does not define new surfaces.

## 2. Are ash_pplan packs registered?

**No.** `ggen capability list` returns 7 surfaces, all marketplace-generic. Testing
`ggen capability inspect ash-pplan-pack` returns the typed refusal:

```
ERROR: CLI execution failed: Argument parsing failed: Unknown capability surface 'ash-pplan-pack'.
Available surfaces: mcp, compliance-soc2, web, devops, data-science, startup, enterprise
```
(raw exit code 1 — typo-refusing works as designed.)

## 3. Hand-maintained pack lists in bin/

The prior audit's count of 3 is overstated. Actual grep of `bin/*` for pack lists:

| script | form | hand-typed names? |
|---|---|---|
| `bin/ggen-verify:18` | `PACKS="${GGEN_VERIFY_PACKS:-ash-pplan-pack ash-pplan-workflow-pack ash-pplan-standing-pack ash-pplan-durable-tla-pack ash-pplan-store-conformance-pack ash-pplan-durable-chaos-pack vendor/ash-pplan-protocol-court-pack}"` | yes — 7 literal names, the only typo-prone list |
| `bin/ggen-doctor:39` | `packs=(priv/ggen/ash-pplan-*/)` | no — glob, self-maintaining |
| `bin/manufacture` / `bin/manufacture-examples` | single hardcoded pack dirs (`priv/ggen/ash-pplan-pack`, `.../ash-pplan-workflow-pack`) | names appear, but single-point not lists |

**Only one hand-maintained list exists**: `bin/ggen-verify` line 18.

## 4. Verdict: DECLINE

Falsifier (witnessed): `ggen capability inspect ash-pplan-pack` exits 1 with
"Unknown capability surface", and ggen source shows the registry is a hardcoded
7-surface `match` with no project-local extension point. The adoption precondition —
"only if packs register as a capability surface" — **cannot be met from ash_pplan**;
it would require a ggen-side source change.

Secondary falsifier: the claimed benefit covers 3 scripts but only 1 hand-typed list
(`ggen-verify:18`) exists, so even if registration were possible, the payoff is ~1
line, not 3.

## 5. Nearest lawful alternative (for the RA2 backlog, not adopted here)

Derive the list from the already-canonical source, `ggen.toml` `[packs.*]`:

```sh
PACKS=$(awk -F'[][]' '/^\[packs\./ && $2 != "exemptions" {print $2"-pack"}' ggen.toml)
```

or a `yq`/toml reader. This makes `ggen-verify` typo-refusing at the config layer
(`ggen.toml` is already the pack-inventory court's source) with zero ggen changes.

## Commands run (all read-only)

- `ggen capability --help`, `ggen capability inspect --help`, `ggen capability enable --help` (exit 0)
- `ggen capability list` (7 surfaces, WARNs for uninstalled marketplace packs)
- `ggen capability inspect mcp --format json` → `{"capability":"mcp","atomic_packs":["mcp-rust"]}`
- `ggen capability inspect ash-pplan-pack` → typed refusal, exit 1
- greps over `bin/`, `ggen.toml`, `~/.ggen/packs/`, ggen source (read-only)
