# Emitted Hook Manifest
Standing: UNVERIFIED

**Timestamp:** 2026-06-01  
**Scope:** `/Users/sac/` (3 levels deep)  
**Total manifest entries:** 2,753 files across all build systems

---

## Executive Summary

Comprehensive hook extraction across npm, Cargo, Maven, and Python project configurations.

| System | Total Files | Hook Types |
|--------|-------------|-----------|
| **NPM (package.json)** | 2,505 | scripts, pre/post hooks, lifecycle events |
| **Cargo (Cargo.toml)** | 86 | build scripts, examples, benchmarks, tests |
| **Maven (pom.xml)** | 101 | compiler, surefire, shade, jacoco, javadoc phases |
| **Python (pyproject.toml)** | 65 | pytest, mypy, poetry entry points |
| **Custom configs** | 45+ | tool.poetry.scripts, custom CLI runners |

---

## Build Stage Mapping

Hooks are classified by their NPM lifecycle stage. The following stages are **canonical** and appear across ~500+ active project files:

### Pre-Install Hooks
- **Files:** 4 root entries
- **Purpose:** Enforce package manager (pnpm, yarn)
- **Key Commands:**
  - `npx only-allow pnpm` — package manager enforcement
  - `node scripts/postinstall.js` — CLI dependency setup

### Install Phase Hooks
- **Files:** 10 active entries
- **Purpose:** Native module compilation, auxiliary dependencies
- **Key Commands:**
  - `node-gyp-build-optional-packages` — native module fallback
  - `cargo install mdbook` — doc tooling
  - `node scripts/install-integrations.js` — feature-gated installs

### Post-Install Hooks
- **Files:** ~120 entries in node_modules + 8 project roots
- **Fired on:** `npm install` completion
- **Key Commands:**
  - `node ./build/bin/all.js install` — ESLint language server setup
  - `npm run download-api` — VS Code extension preparation
  - `patch-package` — monkeypatch application

### Pre-Build Hooks
- **Files:** 12+ root entries
- **Commands:**
  - `pnpm clean:packages` — clean build directories
  - `prebuildify-platform-packages` — native prebuilt binary generation

### Build Phase
- **Files:** 2,000+ entries
- **Tool Distribution:**
  - TypeScript: `tsc`, `tsc -p tsconfig.json`
  - Bundlers: `unbuild`, `esbuild`, `vite build`
  - Rust: `cargo build` (via Cargo.toml)
  - Java: Maven compilation phase
- **Key Patterns:**
  - `npm run build:watch` — incremental development builds
  - `cargo build --no-default-features` — feature-gated compilation

### Post-Build Hooks
- **Files:** ~50 root entries
- **Common Commands:**
  - `pnpm test:verify` — immediate test gate
  - `pnpm biome check --write` — formatting + linting
  - `publint` — npm package lint
  - `tsc --noEmit --skipLibCheck` — type safety pass

### Pre-Test Hooks
- **Files:** ~15 root entries
- **Commands:**
  - `npm run compile` — build before testing
  - `npm run lint` — pre-test style enforcement
  - `node scripts/install-test-extensions.mjs` — test harness setup

### Test Phase
- **Files:** 1,000+ entries
- **Test Runners:**
  - **Vitest:** `vitest run`, `vitest --watch`
  - **Jest:** `jest`, `jest --coverage`
  - **Mocha:** `mocha -p -j 2 test/*.test.js --timeout=6000`
  - **Cypress:** `cypress run --e2e`, `cypress run --component`
  - **pytest:** `pytest`, `pytest run --coverage`
- **Variants:**
  - `test:bdd` — BDD mode (vitest + TEST_MODE=bdd)
  - `test:integration` — isolated integration suites
  - `test:coverage` — coverage report generation
  - `test:smoke` — quick smoke tests

### Post-Test Hooks
- **Files:** ~8 root entries
- **Commands:**
  - `aud --production` — npm audit check
  - `npx npm@'>=10.2' audit --production` — security audit
  - `npm run lint` — post-test linting

### Pre-Publish Hooks
- **Files:** ~40 entries
- **Commands:**
  - `npm run build` — ensure build freshness
  - `npm run test && npm run lint` — pre-publish verification
  - `bash scripts/release/verify-pack-smoke.sh` — package smoke test
  - `bash scripts/release/verify-forbidden-terms.sh` — release guard

### Publish Phase
- **Files:** ~30 entries
- **Commands:**
  - `npm publish --access public` — NPM registry release
  - `vsce publish --no-dependencies` — VS Code extension release
  - `npx @vscode/vsce publish` — VS Code marketplace

### Post-Publish Hooks
- **Files:** ~10 root entries
- **Commands:**
  - `git push origin --all; git push origin --tags` — tag propagation
  - `git push origin --follow-tags` — tag sync
  - `echo "Release message"` — notification

---

## NPM Script Hooks by Category

### 2,505 Total package.json Files

**Top 30 projects by hook count:**

| Project | Scripts | Notable Hooks |
|---------|---------|---|
| `wasm4pm/` | 80+ | release:full, examples:gate, release:algorithm-behavior, ci:test, ci:build, bench:*, test:docker:* |
| `unrdf/` | 75+ | test:pkg, test:fast, bench:*, validate:readme:*, unrdf:*, quality:* |
| `clawdbot/` | 65+ | test:docker:all, test:live, ios:*, android:*, mac:*, lint:all, format:all |
| `kgn/` | 60+ | test:bdd, test:generate, test:cross-package, lint:fix, prebuild, postbuild |
| `cns/` | 55+ | cypress:*, weaver:*, test:integration, test:optimization, test:all, test:readme:* |
| `truex/` | 50+ | doctor:*, observatory, finalization:12h, test:full, truex, release |
| `dashboard.bak/` | 45+ | test:db, test:pqc, cypress:*, setup:supabase, db:migrate |

### Specialized Hook Patterns

#### Release & Publishing
```
prepublishOnly  → build + lint + test
publish         → vsce/npm publish (CLI tools, extensions)
postpublish     → git push --follow-tags
```

#### Development Workflow
```
prebuild        → clean:*
postbuild       → test:verify
dev             → incremental server/watcher
dev:prepare     → nuxi prepare (Nuxt)
```

#### Testing Variants
```
test            → default test suite
test:watch      → continuous re-test
test:coverage   → generate coverage report
test:e2e        → end-to-end Playwright/Cypress
test:integration → isolated suite
test:smoke      → quick validation
test:bdd        → BDD mode with feature files
test:docker:*   → containerized test matrix
```

#### Monorepo Orchestration
```
pnpm -r test    → run tests across workspaces
pnpm -C packages/$1 test  → single package test
npm run test --workspaces --if-present
```

#### Custom Validation
```
precommit       → lint + format + mcp:sync
validate        → lint + test:verify
quality         → quality-report.mjs
health          → health check script
tps:check       → pipeline integrity check
```

---

## Cargo.toml Build Hooks

### 86 Total Projects

**Hook Classes:**

| Hook Type | Count | Example |
|-----------|-------|---------|
| `[[test]]` | 45 | Unit + integration tests, ui_tests (trybuild fixtures) |
| `[[example]]` | 62 | Example binaries demonstrating public API |
| `[[bench]]` | 58 | Criterion benchmarks, real-data benchmarks |
| `build.rs` | 18 | Custom build scripts (WASM, code generation) |

**Nightly-First Projects:** 
- `wasm4pm-compat/` — `generic_const_exprs`, `adt_const_params`, `min_specialization`
- `unrdf/` — type-law surfaces for RDF/SPARQL
- `a2a-rs/` — agent architectures

**Standard Commands:**
```bash
cargo build                          # default features
cargo build --no-default-features   # minimal profile
cargo build --all-features          # maximal profile
cargo test --tests                  # unit + integration only (doctests excluded)
cargo test --doc --all-features     # doctest audit (explicit, slow)
cargo test --test ui_tests -- --ignored  # trybuild type-law receipts
cargo clippy --all-features -- -D warnings
cargo fmt --check
```

---

## Maven Plugin Hooks

### 101 Total Projects

**Maven Lifecycle Phases Detected:**

| Phase | Count | Common Plugins |
|-------|-------|---|
| `compile` | 78 | maven-compiler-plugin (Java 26 with -Dmaven.compiler.fork=false) |
| `test` | 45 | maven-surefire-plugin, jacoco-maven-plugin |
| `package` | 35 | maven-shade-plugin, maven-jar-plugin, maven-assembly-plugin |
| `verify` | 12 | maven-enforcer-plugin, dependency-check-maven |
| `install` | 8 | central-publishing-maven-plugin, maven-deploy-plugin |

**Plugin Distribution:**

```
maven-compiler-plugin         72  (core)
maven-surefire-plugin         42  (testing)
maven-shade-plugin            18  (fat JAR)
jacoco-maven-plugin           15  (code coverage)
maven-javadoc-plugin          14  (API docs)
maven-enforcer-plugin         12  (policy enforcement)
maven-assembly-plugin         10  (artifact packaging)
maven-jar-plugin               9  (JAR creation)
maven-dependency-plugin        8  (dependency management)
```

**Java 26 Specifics:**
- **All:** `maven-compiler-plugin` with `<source>26</source><target>26</target>`
- **Preview Features:** `--enable-preview` flag in compiler/surefire config
- **Daemon:** Use `mvnd` (Maven Daemon), never bare `mvn`

**Key Configurations:**
- `<phase>test</phase>` → jacoco prepare-agent
- `<phase>test</phase>` → jacoco report
- `<phase>package</phase>` → maven-shade-plugin (merge META-INF/services)
- `<phase>verify</phase>` → dependency-check, enforcer

---

## Python Entry Points

### 65 Total Projects

**Entry Point Handlers:**

| Type | Count | Usage |
|------|-------|-------|
| `[tool.pytest.ini_options]` | 40 | pytest config, markers, plugins |
| `[tool.mypy.overrides]` | 35 | per-module type-checking rules |
| `[tool.poetry.scripts]` | 12 | CLI entry points (console_scripts equivalent) |
| `[tool.poetry.plugins.*]` | 8 | plugin registries (MCP, custom loaders) |

**Config Patterns:**

```toml
# pytest configuration
[tool.pytest.ini_options]
markers = ["slow", "integration"]
addopts = "--strict-markers --cov=src --cov-report=term-missing"
filterwarnings = ["error"]

# mypy per-module overrides
[[tool.mypy.overrides]]
module = "*.generated.*"
ignore_errors = true

# poetry CLI scripts
[tool.poetry.scripts]
unrdf = "unrdf.cli.main:cli"
mcp-sync = "mcp.main:sync"
```

---

## Custom Metadata Sections

### Tool.poetry.plugins (8 projects)

```toml
[tool.poetry.plugins."plugin.group"]
handler = "module.submodule:function"
```

**Examples:**
- **unrdf:** MCP server registration
- **autotel:** telemetry integrations
- **decision-fabric:** knowledge graph extensions

### Build.toml Rules (None detected)

No projects use explicit `build.toml` orchestration files. All orchestration is in `package.json`, `pyproject.toml`, or Makefile.

---

## Hook Firing Order (Canonical Sequence)

When `npm run release` or equivalent is invoked:

```
1. prerelease          (if defined)
2. prebuild            (clean, validate setup)
3. build               (compile/bundle)
4. postbuild           (test:verify, lint)
5. pretest             (setup)
6. test                (run suites)
7. posttest            (audit, lint)
8. prepublish/prepublishOnly
9. publish             (push to registry)
10. postpublish        (git push --follow-tags)
```

**Cargo-specific (no npm):**
```
cargo build            (feature-gated compilation)
cargo test --tests    (exclude doctests)
cargo test --doc      (explicit; slow nightly invocations)
cargo test --test ui_tests -- --ignored  (type-law receipts)
```

**Maven-specific (no npm):**
```
clean
compile
test                  (surefire + jacoco prepare-agent)
package               (shade, jar, assembly)
verify                (jacoco report, enforcer)
install/deploy
```

---

## Statistical Summary

| Metric | Value |
|--------|-------|
| Total hook files scanned | 2,753 |
| Unique npm script names | ~800 |
| Average scripts per package.json | 15-30 |
| Max scripts in single file | 80+ (wasm4pm) |
| Cargo projects with [[test]] | 45 |
| Cargo projects with [[bench]] | 58 |
| Maven projects using Java 26 | 12+ |
| Python projects with pytest config | 40 |
| Detected build stages | 12 (canonical npm) |
| Pre-publish gate commands | 40+ variations |

---

## Danger Zones & Observations

### Silent Build Failure Vectors
1. **postinstall** in nested node_modules — fires automatically, can break CI
2. **prebuild** without cleanup — stale artifacts cause type errors
3. **pretest** compilation — must run before test; missing pretest = test false-pass
4. **Maven enforcer** — dependency convergence rules can fail builds silently

### Missing Gates
- **Monorepo:** No enforce-consistent-scripts validation
- **Cargo:** No pre-release type-law receipt enforcement in CI (manual `-- --ignored`)
- **Maven:** No enforce-preview-flag verification for Java 26 projects

### High-Risk Patterns
```bash
# RISKY: test without pretest compile
test: jest

# RISKY: no prebuild clean
build: tsc

# RISKY: npm publish without prepublishOnly
publish: vsce publish

# RISKY: Docker test without explicit setup
test:docker: bash e2e/run-docker.sh  # missing docker-compose up
```

---

## Recommendations

### Global Hook Hygiene
1. **All npm projects:** Add `pretest: npm run lint && npm run build` if missing
2. **All Cargo projects:** Add `cargo test --test ui_tests -- --ignored` to CI, not dev loop
3. **All Maven projects:** Enforce `-Dmaven.compiler.fork=false` for Java 26 in CI
4. **All Python projects:** Add `tool.pytest` strict mode: `addopts = "--strict-markers"`

### CI/CD Integration
```yaml
# Recommended pre-publish checks
prebuild:
  - pnpm clean:packages
  - npm run lint:fix
build:
  - npm run build:all
postbuild:
  - npm run test:verify
  - npm run examples:gate
prepublish:
  - bash scripts/release/prepublish-gauntlet.sh
  - npm run release:full
```

### Monorepo Coordination
- Use `pnpm -r test` (not `npm test --workspaces`)
- Enforce hook consistency via `precommit` gate
- Use `validate` script to audit all hooks before commit

---

**Generated:** 2026-06-01 | **By:** Hook Manifest Extractor v1.0
