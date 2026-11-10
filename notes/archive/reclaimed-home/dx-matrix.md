# DX Matrix — Project × Verb Coverage
Standing: UNVERIFIED

**Generated:** 2026-06-10  
**Projects:** 72  
**Verbs:** 14 (maximal vocabulary)

## Legend
✓ = recipe present | — = not applicable / no backing command

## Verb Key
| # | Verb | Meaning |
|---|------|---------|
| 1 | `test` | fast suite |
| 2 | `test-full` | slow/ignored/e2e |
| 3 | `test-watch` | watch mode |
| 4 | `polish` | fmt + lint fix-in-place |
| 5 | `verify` | arch/conformance scan |
| 6 | `build` | debug build |
| 7 | `build-release` | optimized build |
| 8 | `dev` | dev server / watch loop |
| 9 | `bench` | benchmarks |
| 10 | `doc` | build docs |
| 11 | `clean` | remove artifacts |
| 12 | `publish` | release w/ preflight |
| 13 | `audit` | security audit |
| 14 | `ci` | gate: polish+verify+test-full |

## Coverage Matrix

| Project | test | test-full | test-watch | polish | verify | build | build-release | dev | bench | doc | clean | publish | audit | ci |
|---------|------|-----------|------------|--------|--------|-------|---------------|-----|-------|-----|-------|---------|-------|----|
| **Rust (cargo-make)** | | | | | | | | | | | | | | |
| wasm4pm-compat | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | — | ✓ | ✓ | — | ✓ |
| wasm4pm | ✓ | ✓ | — | ✓ | — | ✓ | — | — | ✓ | — | ✓ | ✓ | — | ✓ |
| clap-noun-verb | ✓ | ✓ | — | ✓ | — | ✓ | — | — | ✓ | ✓ | ✓ | — | — | ✓ |
| chicago-tdd-tools | ✓ | ✓ | — | ✓ | — | ✓ | — | — | ✓ | ✓ | ✓ | — | — | ✓ |
| dteam | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | ✓ | ✓ | — | — | ✓ |
| mcpp | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | ✓ | ✓ | ✓ | — | ✓ |
| unibit | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| clnrm | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | ✓ | ✓ | — | — | ✓ |
| ggen-mcp | ✓ | — | — | — | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| **Rust (plain cargo)** | | | | | | | | | | | | | | |
| speckit-ralph | ✓ | ✓ | — | ✓ | ✓ | ✓ | — | — | — | ✓ | ✓ | — | — | ✓ |
| knhk | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| sos | ✓ | — | — | ✓ | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| open-ontologies | ✓ | — | — | ✓ | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| unrdf | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| yawl | ✓ | ✓ | — | — | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| lsp-types-max | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | — | ✓ | ✓ | — | ✓ |
| a2a-rs | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | ✓ | ✓ | ✓ | — | ✓ |
| obsr | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | ✓ | ✓ | — | ✓ | ✓ |
| pm4py-lsp | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| cargo-cicd | ✓ | ✓ | — | ✓ | — | ✓ | ✓ | — | — | ✓ | ✓ | ✓ | — | ✓ |
| blue_river_dam | ✓ | ✓ | — | ✓ | — | ✓ | ✓ | — | — | ✓ | ✓ | — | — | ✓ |
| capability-map | ✓ | ✓ | — | ✓ | — | ✓ | ✓ | — | — | ✓ | ✓ | — | — | ✓ |
| semantic_bit | ✓ | ✓ | — | ✓ | — | ✓ | ✓ | — | — | ✓ | ✓ | — | — | ✓ |
| stpnt | ✓ | ✓ | — | ✓ | — | ✓ | ✓ | — | — | ✓ | ✓ | — | — | ✓ |
| universe-chain | ✓ | ✓ | — | ✓ | — | ✓ | ✓ | — | — | ✓ | ✓ | — | — | ✓ |
| chatmangpt | ✓ | — | — | ✓ | — | ✓ | ✓ | — | — | ✓ | ✓ | — | — | ✓ |
| osx-clnr | ✓ | — | — | ✓ | — | ✓ | ✓ | — | — | — | ✓ | — | — | ✓ |
| knowd | ✓ | ✓ | — | ✓ | — | ✓ | — | — | ✓ | ✓ | ✓ | — | — | ✓ |
| **lsp-max (custom)** | | | | | | | | | | | | | | |
| lsp-max | ✓ | — | — | — | — | — | — | — | — | — | — | — | — | — |
| **Node (npm)** | | | | | | | | | | | | | | |
| ai-chatbot | — | — | — | ✓ | — | ✓ | — | ✓ | — | — | — | — | — | ✓ |
| ai-first-2026 | — | — | — | — | — | ✓ | — | ✓ | — | — | — | — | — | ✓ |
| app | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | ✓ | — | — | ✓ | — | — | ✓ |
| helloworld | ✓ | — | — | — | — | — | — | — | — | — | — | — | — | ✓ |
| interview | — | — | — | ✓ | — | ✓ | — | ✓ | — | — | — | — | — | ✓ |
| intvw | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | — | — | ✓ |
| practice | — | — | — | ✓ | — | ✓ | — | ✓ | — | — | — | — | — | ✓ |
| test-unjucks-nuxt4 | ✓ | — | — | — | — | — | — | — | — | — | — | — | — | ✓ |
| unlsp | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| zoeapp | ✓ | — | — | ✓ | — | — | — | ✓ | — | — | — | — | — | ✓ |
| zoela | ✓ | ✓ | — | ✓ | — | — | — | ✓ | — | — | — | — | — | ✓ |
| pcp | ✓ | — | — | ✓ | — | ✓ | — | — | — | — | — | — | — | ✓ |
| powlv2lsp | ✓ | — | — | — | — | ✓ | — | — | — | — | — | — | — | ✓ |
| helloworld | ✓ | — | — | — | — | — | — | — | — | — | — | — | — | ✓ |
| **Node (pnpm)** | | | | | | | | | | | | | | |
| knowtro | ✓ | ✓ | — | ✓ | — | ✓ | — | ✓ | — | — | — | — | — | ✓ |
| neako | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | — | — | ✓ |
| ai | ✓ | ✓ | — | ✓ | — | ✓ | — | ✓ | — | — | ✓ | — | — | ✓ |
| citty-test-utils | ✓ | ✓ | ✓ | — | — | ✓ | — | — | — | — | — | — | — | ✓ |
| clawdbot | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | — | — | ✓ |
| un-test-utils | ✓ | ✓ | ✓ | — | — | ✓ | — | — | — | — | — | — | — | ✓ |
| unjucks | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | ✓ | ✓ | — | ✓ | — | ✓ | ✓ |
| unrdf-clean | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | ✓ | ✓ | ✓ | ✓ | — | ✓ | ✓ |
| zod-to-from | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | — | — | — | — | — | — | ✓ |
| **Node (mixed)** | | | | | | | | | | | | | | |
| truex | ✓ | ✓ | — | ✓ | — | ✓ | — | ✓ | — | — | ✓ | — | — | ✓ |
| kgn | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | ✓ | — | — | ✓ | — | — | ✓ |
| hive-queen | ✓ | ✓ | — | ✓ | — | ✓ | — | ✓ | — | — | — | — | — | ✓ |
| remo | ✓ | ✓ | — | ✓ | — | ✓ | — | ✓ | — | — | ✓ | — | — | ✓ |
| bytestar | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | ✓ | ✓ | ✓ | ✓ | — | — | ✓ |
| cns | ✓ | — | — | ✓ | — | ✓ | — | — | — | — | — | — | — | ✓ |
| optimus | ✓ | — | — | ✓ | — | ✓ | — | — | — | — | — | — | — | ✓ |
| **Erlang** | | | | | | | | | | | | | | |
| mcp_erl | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| mcp-mqtt-erl | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| **Java (Maven)** | | | | | | | | | | | | | | |
| jotp | ✓ | ✓ | — | ✓ | — | ✓ | ✓ | — | ✓ | — | ✓ | — | — | ✓ |
| yawlv6 | — | — | — | — | — | ✓ | ✓ | — | — | — | ✓ | — | — | ✓ |
| java-maven-template | ✓ | — | — | — | — | ✓ | ✓ | — | — | — | ✓ | — | — | ✓ |
| **Go** | | | | | | | | | | | | | | |
| wf | ✓ | ✓ | — | ✓ | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| **Python** | | | | | | | | | | | | | | |
| yaml-server | — | — | — | — | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| ycloud | ✓ | — | — | ✓ | — | — | — | — | — | — | — | — | — | ✓ |
| **Make / mixed** | | | | | | | | | | | | | | |
| autotel | ✓ | — | — | ✓ | — | ✓ | — | — | — | ✓ | ✓ | — | — | ✓ |
| hive-mind-monorepo | ✓ | — | — | ✓ | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| cre | ✓ | — | — | ✓ | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| claude-desktop-context | ✓ | — | — | ✓ | — | ✓ | — | ✓ | — | — | — | — | — | ✓ |
| storehouse | ✓ | — | — | — | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |
| bitstar | ✓ | — | — | — | — | ✓ | — | — | — | — | ✓ | — | — | ✓ |

## Summary Stats

| Verb | Coverage |
|------|----------|
| `ci` | 71/72 (99%) |
| `test` | 62/72 (86%) |
| `build` | 65/72 (90%) |
| `clean` | 53/72 (74%) |
| `polish` | 52/72 (72%) |
| `test-full` | 42/72 (58%) |
| `dev` | 28/72 (39%) |
| `test-watch` | 15/72 (21%) |
| `doc` | 17/72 (24%) |
| `bench` | 9/72 (13%) |
| `build-release` | 14/72 (19%) |
| `publish` | 7/72 (10%) |
| `audit` | 4/72 (6%) |
| `verify` | 2/72 (3%) |

## Excluded Directories (not projects)

| Directory | Reason |
|-----------|--------|
| `otp_src_28.3.1` | upstream Erlang/OTP source tree |
| `*-backup*`, `wasm4pm-backups`, `claude-backup`, `backup-critical` | named backups |
| `homebrew-clnrm` | Homebrew tap (formula only, no build surface) |
| `Library`, `Movies`, `Music`, `Pictures`, `Public`, `Applications` | macOS system dirs |
| `receipts`, `reports`, `research`, `results`, `ostar`, `teleport`, `process-intelligence` | data/doc dirs |
| `pigsty*`, `storehouse-infrastructure`, `weaver-driven-development-book` | infrastructure/docs |
| `SparsePrimingRepresentations`, `linkedin-public-canon`, `phd-thesis`, `portfolio-reports` | doc/data only |
| `bitactor` | loose C artifacts, no root Makefile |
| `miniconda3`, `google-cloud-sdk`, `go`, `multipass` | toolchains |
| `pgdata`, `cachedir_joblib`, `local_cache`, `.cache` | caches |
