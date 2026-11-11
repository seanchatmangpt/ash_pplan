# Receipt: Hex Release Court (`@agi-10` / `hex-release-court`)

- **Slice**: `hex-release-court` (Swarm Brief `#13`)
- **Milestone**: `v26.11.10`
- **Date**: `2026-11-10`
- **Base Git HEAD**: `ba9019c1b531967822e7bf3d0af09ad5a8e88e6b` (`main`, post-wave working tree formatted)
- **Hex Package**: `ash_pplan` `26.11.10`
- **Court Standing**: `PARTIAL_ALIVE` (Hex build, checksums, tarball isolation, standalone prod compile, and `mix hex.publish --dry-run --yes` all green; `ALIVE` requires green CI against the final committed release SHA plus pre-tag contract/advisory closure per `AGENTS.md`)

---

## 1. Hex Tarball & Cryptographic Checksums (`O*`)

| Artifact / Field | Observed Value |
|---|---|
| Tarball Path | `ash_pplan-26.11.10.tar` |
| Tarball Format Version | `3` (`VERSION`) |
| Tarball Byte Size | `879,616` bytes (`859 KB`) |
| **Package / Outer SHA-256** (`mix hex.build` & `shasum -a 256`) | `4d2e75ccfce3996f2632d81b882a981b4e0276a45585e49d177b9b273b41cc95` |
| **Inner Hex `CHECKSUM`** (`SHA256(VERSION \|\| metadata.config \|\| contents.tar.gz)`) | `9c995189923c2ea2a70b80c9edd97cbad8548eb5ac034c5b412bceac05ae283a` |
| Packaged Entry Count (`contents.tar.gz`) | `863` files (`0` directory entries, `0` forbidden path leaks) |
| Base `ReleaseReceipt` Digest (`./bin/receipt` @ `ba9019c`) | `691678b674c93b1b17f5368a7bc5802f19a823697ec0a27084bf38d17034b85f` |

### Boundary Exclusion Audit (`0` leaks)
Verified `contents.tar.gz` contains **zero** entries matching:
- `lib/mix/` (dev-only Igniter task excluded)
- `lib/ash_pplan/playground/`
- `priv/courts/`
- `planning/archive/` (`12` active `planning/**` files preserved; `5` archived files excluded)
- `docs/jira/`, `docs/sjira/`, `docs/archive/`, `docs/case-studies/receipts/`
- `test/`

---

## 2. Verification Ladder Executed

1. **`mix hex.build`**: **Exit `0`** — produced `ash_pplan-26.11.10.tar` with `Package checksum: 4d2e75ccfce3996f2632d81b882a981b4e0276a45585e49d177b9b273b41cc95`; byte-identical replay confirmed before and after `docs/jira/v26.11.10/` updates.
2. **Independent Python SHA-256 Tarball Recomputation**: **Exit `0`** — unpacked `ash_pplan-26.11.10.tar` in isolated scratch directory and verified `SHA256(VERSION || metadata.config || contents.tar.gz) == 9c995189923c2ea2a70b80c9edd97cbad8548eb5ac034c5b412bceac05ae283a` and `FORBIDDEN_LEAKS == []`.
3. **`mix hex.publish --dry-run --yes`**: **Exit `0`** — built package + ExDoc HTML/Markdown/EPUB (`doc/index.html`, `doc/llms.txt`, `doc/ash_pplan.epub`) and passed Hex CLI dry-run checks with zero live remote publication (`authority: CONSTRUCT`).
4. **`mix test test/package_hygiene_test.exs`**: **Exit `0`** (`1/1` passed).
5. **`./bin/verify-package`** (witnessed in `#21` & consistent with final tarball): **Exit `0`** — `MIX_ENV=prod mix compile --warnings-as-errors` cleanly compiles all `173` packaged `.ex` files from extracted `contents.tar.gz`.
6. **`docs/jira/v26.11.10/` Completion Audit**: Verified all 8 milestone documents present, cross-linked, and updated (`000-SURVEY-RECEIPT.md`, `EPIC-RELEASE-v26.11.10.md`, `ECO-DURABLE-OBLIGATION-VERDICT.md`, `ECO-POWL-SOUNDNESS-VERDICT.md`, `ECO-ZERO-MOCK-DISCIPLINE.md`, `ECO-HEX-PUBLISH-READINESS.md`, `SWARM-REVIEW-SYNTHESIS.md`, `HEX-RELEASE-COURT-RECEIPT.md`).

---

## 3. Standing & Residual Pre-Live-Publish Gate Falsifiers

Per `AGENTS.md` (`Standing` & `Release gate`) and the Chatman Equation (`A = μ(O*)`):
- **Hex Packaging & Dry-Run Court Standing**: `PARTIAL_ALIVE` (all packaging, hygiene, standalone prod compilation, checksum, and `mix hex.publish --dry-run` checks pass locally with exit `0`).
- **Residual Falsifiers Before Promoting Release Standing to `ALIVE` / Live `mix hex.publish`**:
  1. **Cross-File Version Contract (`mix test test/release_contract_test.exs` -> `35/38` passed, `3` failed, exit `2`)**:
     - `ontology.ttl` still declares `owl:versionInfo "26.11.7"` (and pack ontology copies in `priv/ggen/ash-pplan-{pack,workflow-pack}/ontology.ttl` must match root `ontology.ttl`).
     - `ecosystem.lock.toml` still declares `release = "v26.10.8-1"` instead of `release = "v26.11.10"`.
  2. **Dependency Advisory Audit (`mix hex.audit` -> exit `1`)**:
     - Reports OSV/EEF advisories on current `mix.lock` pins (`ash 3.33.11`, `ecto 3.14.2`, `decimal 3.1.1`, plus dev/test `bandit 1.12.5`, `phoenix_html 4.3.0`, `plug_crypto 2.2.0`).
  3. **Exact-Head Commit & CI**:
     - Wave changes are currently uncommitted atop `ba9019c1b531967822e7bf3d0af09ad5a8e88e6b`; committing the release tree, re-minting `./bin/receipt`, and witnessing green CI on that exact SHA is required for `ALIVE` standing.
