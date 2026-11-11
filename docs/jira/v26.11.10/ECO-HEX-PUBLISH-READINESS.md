# ECO: Hex Package Publish Readiness & Boundary Verification

- **Ticket Key**: `PPLAN-261110-05`
- **Milestone**: `v26.11.10`
- **Target Version**: `26.11.10`
- **Status**: VERIFIED (`PARTIAL_ALIVE` — Hex tarball, standalone compile, & dry-run green; `ALIVE` gated on exact-head CI & pre-tag contract/advisory gates)

---

## 1. Hex Packaging Boundary Law

Per `docs/PACKAGE-BOUNDARY.md` and `ash_pplan/AGENTS.md`:
- `./bin/verify-package` proves the built package compiles as an end-consumer receives it without relying on local uncommitted artifacts or git tracking.
- All compile-time inputs (`lib/HANDWRITTEN.md`, `ontology.ttl`, manifests) must be listed in `mix.exs` `package[:files]`.
- No generated code directory named `generated/` is permitted.

## 2. Package Files Manifest Audit

The package file manifest (`863` packaged entries in `contents.tar.gz`) includes:
- `lib/` (including manufactured catalogs, workflow definitions, and providers; `lib/mix/` and `lib/ash_pplan/playground/` excluded)
- `config/`
- `ontology.ttl` & `ontology/shapes.ttl`
- `planning/` (`12` active HDDL/FOND planning files; `planning/archive/**` excluded and guarded by `test/package_hygiene_test.exs`)
- `docs/` (Diataxis tutorials, reference, explanation, how-to; `docs/jira/`, `docs/sjira/`, `docs/archive/`, `docs/case-studies/receipts/` excluded)
- `ecosystem.lock.toml`, `mix.exs`, `README.md`, `LICENSE`, `CHANGELOG.md`, `.formatter.exs`

## 3. Publication Protocol, Checksums & Safety Gate

Per BRCE doctrine (zero unreceipted actuation):
- **`mix hex.build`**: Exit `0` — built `ash_pplan-26.11.10.tar` (`879,616` bytes / `859 KB`, Hex tarball `VERSION=3`).
  - **Package / Outer Tarball SHA-256**: `4d2e75ccfce3996f2632d81b882a981b4e0276a45585e49d177b9b273b41cc95`
  - **Inner Hex `CHECKSUM` (`SHA256(VERSION || metadata.config || contents.tar.gz)`)**: `9c995189923c2ea2a70b80c9edd97cbad8548eb5ac034c5b412bceac05ae283a`
- **`./bin/verify-package`**: Exit `0` — `package ash_pplan-26.11.10 compiles from its own contents` (`MIX_ENV=prod mix compile --warnings-as-errors`, zero warnings).
- **`mix hex.publish --dry-run --yes`**: Exit `0` — verified package build, ExDoc HTML/Markdown/EPUB generation (`doc/index.html`, `doc/llms.txt`, `doc/ash_pplan.epub`), and Hex publication preflight with zero live network actuation.
- **Residual Pre-Publish / Exact-Head Release Gate Notes** (documented in `HEX-RELEASE-COURT-RECEIPT.md`):
  1. `test/release_contract_test.exs` (`35/38` passed, `3` failed): `ontology.ttl` (`owl:versionInfo "26.11.7"`), pack ontology sync, and `ecosystem.lock.toml` (`release = "v26.10.8-1"`) require bump/sync to `26.11.10` prior to final release commit.
  2. `mix hex.audit` (exit `1`): reports upstream OSV/EEF advisories in `mix.lock` (`ash 3.33.11`, `ecto 3.14.2`, `decimal 3.1.1`, and dev/test `bandit 1.12.5`, `phoenix_html 4.3.0`, `plug_crypto 2.2.0`).
  3. Exact-head CI on the committed release SHA is required before promoting standing from `PARTIAL_ALIVE` to `ALIVE` per `AGENTS.md`.
