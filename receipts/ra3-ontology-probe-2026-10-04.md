# RA3 Probe Receipt — `ggen ontology status/list` vs vendored ontologies

Date: 2026-10-04 · Mode: read-only probe · Tool: ggen 26.9.28 · Subject: /Users/sac/ash_pplan

## Question

Can `ggen ontology status` / `list` detect drift in ash_pplan's vendored ontologies
(`priv/ggen/*/ontology.ttl`, 10 packs), or do they require marketplace/registry registration?

## Evidence (actual commands + output)

1. `ggen ontology --help` — subcommands: install, search (marketplace placeholder),
   namespaces, info, lock (writes `.ggen/lock`), status, list.
2. `ggen ontology list` → exactly 3 ontologies, all embedded core bundle:
   `rdf` (375B), `rdfs` (413B), `owl` (474B). No local/vendored entries.
   `list --embedded` flag confirms the scope is the embedded bundle.
3. `ggen ontology status --uri "https://w3id.org/ash-pplan#"` (the base URI actually
   declared in `priv/ggen/ash-pplan-pack/ontology.ttl`) →
   `{"uri": "...ash-pplan#", "embedded": false, "location": "not-found", "size": null, "name": null}`,
   exit 0. Same for `http://` variant.
4. `status` accepts only `--uri <URI>` — no file-path mode exists. There is no
   read-only command that can point at `priv/ggen/<pack>/ontology.ttl`.
5. Write-capable commands exist but were NOT run (per probe constraints):
   `ontology install` (marketplace fetch + lock update), `ontology lock` (writes
   `.ggen/lock`). Neither registers a local file path; both operate on
   package@version registry entries.

## Registry determination

The registry ggen reads is the **embedded core bundle compiled into the binary**
(rdf/rdfs/owl only) plus the marketplace registry for install/search. It does not
scan the filesystem, the repo, or `ggen.toml` for local ontology files.
`status` on any vendored ontology URI returns `not-found` — not because of drift,
but because local packs are outside the registry's model entirely.

## Verdict: PARK PERMANENTLY (eliminate)

`ggen ontology status/list` cannot see vendored local packs and has no wiring path
that could make it see them (no `--path` / file input; registration requires a
marketplace package, which these packs are not). Falsifier for any later
re-adoption: a single command invocation returning `location: not-found` for
`https://w3id.org/ash-pplan#` (reproduced 2026-10-04, ggen 26.9.28).

Drift detection for `priv/ggen/*/ontology.ttl` is already covered by the existing
mechanism the packs themselves declare: SHA-256 provenance headers against the
canonical repo-root `ontology.ttl` and the pack-digest court (ggen_igniter >=
26.10.1). No gap to close.

## Receipt fields

- Subject: ggen 26.9.28 (`ggen ontology` subtree), ash_pplan working tree @ 9a89aac (dirty, read-only probe)
- Commands run: `ontology --help`, `status --help`, `list --help`, `list`,
  `status --uri` x2 — all read-only, all exit 0
- Writes performed: only this receipt file
- Consequence: RA3 item moves PARK/UNKNOWN → PARKED-PERMANENT (eliminated), falsifier recorded
- Standing: ALIVE for the verdict on this subject+tool version; UNKNOWN for future
  ggen versions until falsifier re-run
