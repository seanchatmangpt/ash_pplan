# PPLAN W3C Audit 2026-10-04

Date: 2026-10-04
Audited subject: repository `/Users/sac/ash_pplan` at working tree (branch `main`, head `c42ee19`
plus uncommitted changes)
Scope: P-PLAN/PROV-O ontology conformance ONLY — vocabulary, axioms, README mapping fidelity, RDF
hygiene, semantic gaps. Software-engineering quality of the runtime is out of scope.

## 1. Status of this document

This section is informative. This report is a point-in-time conformance audit of the
`ash_pplan` ontology profile (`ontology.ttl`, 685 triples) and the modules the README
maps to P-PLAN/PROV-O concepts, checked against:

- **[P-PLAN]** The P-PLAN ontology v1.3, `http://purl.org/net/p-plan#`
  (deref of `http://purl.org/net/p-plan`, resolves to
  `https://vocab.linkeddata.es/p-plan/p-plan.owl`; `dcterms:modified 2014-03-12`,
  `owl:versionInfo 1.3`). Retrieved 2026-10-04.
- **[PROV-O]** W3C Recommendation PROV-O: The PROV Ontology,
  `https://www.w3.org/TR/prov-o/` (normative sections 1.1, 1.2, 3, 4, B per its §1.1);
  vocabulary namespace `http://www.w3.org/ns/prov#`, ontology IRI
  `http://www.w3.org/ns/prov-o#`. Retrieved 2026-10-04.
- **[RDF11]** RDF 1.1 Concepts and Abstract Syntax (W3C Recommendation) for literal,
  IRI, and N-Triples conformance.
- **[N-TRIPLES]** RDF 1.1 N-Triples (W3C Recommendation) for the serialization emitted
  by `AshPPlan.ExecutionReceipt.to_rdf/1`.

Normative keywords MUST / SHOULD / MAY in this document follow RFC 2119 usage as in
W3C specifications. A finding marked MUST is a conformance violation against [P-PLAN],
[PROV-O], [RDF11], or the project's own stated contract; SHOULD violations are
advisable to repair; MAY items are hygiene observations.

### 1.1 Conformance verdict

**PARTIAL.**

The project's use of P-PLAN and PROV-O vocabulary is *correct*: every `p-plan:` and
`prov:` term referenced anywhere in the ontology or emitted by code exists in the
published vocabulary (0 undefined terms out of 8 P-PLAN terms, 8 PROV terms), every
`p-plan:` property use in the ontology satisfies its published `rdfs:domain` /
`rdfs:range`, the code-emitted N-Triples round-trip through a standards parser, and the
executable SHACL profile (`ontology/shapes.ttl`) both passes (`./bin/conform`:
`CONFORMS=True`, 685 triples) and is provably non-vacuous (`./bin/conform-falsify`: 13
counterexamples refused). However, RDF hygiene defects exist at MUST level: the shipped
pack copy of the ontology has drifted from the canonical file while its provenance
header claims byte-identity (and the README claims a symlink that does not exist), and
a class (`ap:Provider`) plus 13 properties are used without declaration. Semantic gaps
(P-PLAN execution correspondence and agent participation implemented in code but never
declared or serialized) are SHOULD/MAY level.

## 2. Conformance clauses

### 2.1 Vocabulary conformance (audit item 1)

**C1 (MUST — PASS).** Every P-PLAN term used by the profile MUST be defined in [P-PLAN].
*Verified by script* (rdflib 7.x): the terms referenced are exactly `p-plan:Plan`,
`p-plan:Step`, `p-plan:Variable`, `p-plan:isStepOfPlan`, `p-plan:isPrecededBy`,
`p-plan:hasInputVar`, `p-plan:hasOutputVar`, `p-plan:isVariableOfPlan` — all defined in
P-PLAN 1.3 with matching IRI spellings (`isVariableOfPlan` matches the published IRI;
note the published label is `isVariableofPlan`, the IRI is authoritative).
Result: **0 undefined P-PLAN terms.**

**C2 (MUST — PASS).** Every `prov:` term used or emitted MUST be defined in [PROV-O].
Referenced/emitted terms: `prov:Activity`, `prov:Entity`, `prov:Agent`,
`prov:Plan` (as superclasses), `prov:used`, `prov:wasGeneratedBy`,
`prov:startedAtTime`, `prov:endedAtTime`. Validated against the live PROV-O graph
(`https://www.w3.org/ns/prov-o`, 1146 triples loaded). Result: **0 undefined PROV terms.**

**C3 (MUST — PASS).** Namespace IRIs MUST be the canonical ones.
`ontology.ttl:2-3`: `p-plan:` = `http://purl.org/net/p-plan#` (matches
`vann:preferredNamespaceUri` in P-PLAN 1.3) and `prov:` = `http://www.w3.org/ns/prov#`
(PROV-O terms namespace) — both correct. The OWL imports at `ontology.ttl:15` use the
correct *ontology* IRIs (`http://purl.org/net/p-plan#`, `http://www.w3.org/ns/prov-o#`),
not the term namespaces. **Correct.**

**C4 (MUST — PASS).** Class specialization MUST use sanctioned extension points.
Per [PROV-O] §3.2/§3.3, `prov:Plan`, `prov:Role` are explicitly "left to be extended by
applications"; subclassing `prov:Activity`/`prov:Entity` is the sanctioned pattern.
All 15 specialized ap: classes subclass `prov:Activity` (3: `BackgroundActivation`,
`TemporalActivation`, `SemanticExecution`, `ReleaseObservation`), `prov:Entity` (9), or
`prov:Plan` (2: `FONDPolicy`, `PolicyDecision`). No local term shadows or redefines a
P-PLAN/PROV term; no re-declaration of a foreign class under the ap: namespace
(`ap:sourceTerm ap:Projection ... ap:sourceTerm p-plan:Plan` is a *reference*, not a
redefinition). **Correct.**

**C5 (SHOULD — FIXED 2026-10-04: `ap:FONDPolicy`/`ap:PolicyDecision` now `rdfs:subClassOf prov:Plan,
p-plan:Plan` at `ontology.ttl:66-67,75-76`).** Since the profile claims a P-PLAN *projection*, local
plan-like classes SHOULD subclass `p-plan:Plan` (which adds the P-PLAN-specific
execution linkage axioms) in addition to `prov:Plan`.
`ap:FONDPolicy` (`ontology.ttl:61-64`) and `ap:PolicyDecision` (`ontology.ttl:70-73`)
subclass only `prov:Plan`. A P-PLAN-aware consumer cannot relate a FONDPolicy to
`p-plan:isSubPlanOfPlan`/`p-plan:isDecomposedAsPlan` without inferring the missing
subclass. Same observation applies to `ap:SemanticExecution` (§2.5, G1).

**C6 (MUST — PASS).** Property usage MUST satisfy published domain/range axioms.
Scripted check of the fixture graph (`ontology.ttl:226-245`) under the union of P-PLAN
1.3 + local axioms with subclass closure: `isStepOfPlan(Step,Plan)`,
`isPrecededBy(Step,Step)`, `hasInputVar(Step,Variable)`, `hasOutputVar(Step,Variable)`,
`isVariableOfPlan(Variable,Plan)` — **0 violations**.

**C7 (MUST — PASS).** Code-emitted PROV triples MUST satisfy PROV-O domain/range.
`AshPPlan.ExecutionReceipt.to_rdf/1` (verified by real execution on this machine, 11
triples, rdflib round-trip clean):
- `prov:wasGeneratedBy` from receipt (`prov:Entity`) to execution (`ap:SemanticExecution`
  ⊑ `prov:Activity`) — Entity→Activity ✓
- `prov:used` from execution (Activity) to plan IRI (Entity) ✓
- `prov:startedAtTime`/`prov:endedAtTime` on the Activity, `^^xsd:dateTime` ✓

**C8 (SHOULD — PASS).** N-Triples escaping MUST satisfy [N-TRIPLES] grammar.
`execution_receipt.ex:121-168`: IRIREF illegal bytes (≤0x20, `<>"{}|^\``, DEL,
non-UTF-8) percent-encoded; literal escapes for `"` `\` LF CR TAB and `\uXXXX` for
other control chars. Real output parsed by rdflib. **Correct.**

### 2.2 subClassOf / domain / range correctness (audit item 2)

**C9 (MUST — PASS).** No local `rdfs:subClassOf` creates a cycle or an unsatisfiable
combination with P-PLAN/PROV axioms. The superclass graph (extracted by script):
3 activity subclasses, 9 entity subclasses, 2 plan subclasses; one internal chain
(`ap:ContinuationEnvelope` ⊑ `ap:PersistentContinuation` ⊑ `prov:Entity`). No cycles,
no class/individual conflation (all `rdfs:Class` declarations are disjoint from
individuals in the same file).

**C10 (SHOULD — FAIL, minor).** `ap:Capability` (`ontology.ttl:249-251`),
`ap:ExecutionProperty` (`ontology.ttl:258-260`), `ap:Correspondence` (`ontology.ttl:262-264`),
`ap:CapabilityPack` (`ontology.ttl:266-268`), `ap:Projection` (`ontology.ttl:17-18`)
have no superclass at all — they are top-level `rdfs:Class`es. Per [PROV-O] this is
permitted (extension is left to applications), but in a profile whose value proposition
is projection onto PROV/P-PLAN, leaving the requirement-recording classes
(`Capability`, `ExecutionProperty`) unanchored SHOULD be revisited: `ap:Realization`
is anchored (⊑ `prov:Entity`, `ontology.ttl:253-256`) while its requirement-side
counterpart `ap:Capability` is not, making the
`requiresCapability`/`realizes` pair asymmetric under RDFS reasoning.

**C11 (MUST — PASS).** `ap:requiresCapability`/`ap:requiresProperty` domain
`p-plan:Step` (`ontology.ttl:280-293`): asserting
`p-plan:Step` as the domain is a *use* of the foreign class as a class expression,
which is allowed; asserting the property on any step individual types that individual
as `p-plan:Step` via RDFS entailment, which is consistent with the fixture.
**Correct.**

### 2.3 README concept-mapping table vs code (audit item 3)

**C12 (MUST — PASS).** Every module named in the README mapping table
(`README.md:9-37`) exists and exports the mapped behavior surface.
Verified by disk check (24/24 present, including `AshPPlan.ReactorOutcome`,
`AshPPlan.Action.Run`, `AshPPlan.ControlPlane`, `AshPPlan.Standing.{Receipt,Ladder}`,
`AshPPlan.Reactor.Durable.{Engine,Store,Store.Ets,Store.Dets,Counterfactual,Migration,PolicyDriver,LedgerOCEL}`,
`AshPPlan.FrontierEvidence`, `AshPPlan.ProcessEvidence`, `AshPPlan.ExecutionReceipt`,
`AshPPlan.Compiler`).
Result: **0 missing modules.**

C12a. `p-plan:Plan → Reactor definition/builder`: **holds**. `compiler.ex:80-92`
validates then builds via `Reactor.Builder` (`Builder.new(plan_iri)`, `add_input`,
`add_step`, `return`), with P-PLAN `isPrecededBy` edges compiled to real Reactor result
dependencies (`compiler.ex:248-286`); `README.md:98` ("P-PLAN precedence becomes Reactor
result dependencies") matches the code exactly (`Argument.from_result/2` at
`compiler.ex:253-256`).

C12b. `p-plan:Step → Ash.Reactor step/action binding`: **holds with a naming caveat.**
The compiler binds step IRI → `Reactor.Step` behaviour module (`compiler.ex:179-187`,
`Spark.implements_behaviour?(module, Reactor.Step)`), which is the "step/action
binding"; the README's "Ash.Reactor" naming refers to the Ash-side DSL. No P-PLAN
conformance impact; noted for the record.

C12c. `p-plan:Variable → Reactor input/argument/result`: **partially holds (SHOULD,
M3).** README row (`README.md:13`) claims variable mapping; the code treats variables
as *context data*: `compiler.ex:258-270` records `input_variables`/`output_variables`
in the step context but the only data flow into a step is the single
`Builder.add_input(..., :input)` (`compiler.ex:87`) plus named predecessor arguments
`predecessor_N` (`compiler.ex:22-39`). `p-plan:hasInputVar`/hasOutputVar are declared
and used on the ontology fixture only; no runtime object corresponds to a
`p-plan:Variable` individual. Consumers relying on the README row will over-expect.
Recommended: document that variables are bounded context, or emit
`p-plan:correspondsToVariable` triples at execution time.

C12d. `semantic execution → Compiler → Reactor.Builder` and
`execution evidence → ExecutionReceipt`: **holds.** See C7.

C12e. Durable ledger rows (`README.md:22-23, 31-34`): all modules exist and
`AshPPlan.Reactor.Durable.LedgerOCEL` exports OCEL 2.0 JSON (`ledger_ocel.ex:108-114`)
with the documented honesty note that checkpoint timestamps reflect export time
(`ledger_ocel.ex:11-13`). **Holds; timestamp fidelity is a documented, honest MAY
observation (M2 below).**

C12f. `prov:Agent → Ash actor/authority context` (`ontology.ttl:153-160`):
**declared but never serialized (SHOULD, G3).** No module emits any agent triple
(`prov:wasAssociatedWith`, `prov:actedOnBehalfOf`, or a typed agent resource); the
actor/authority context exists only in Ash context maps. The catalog row is therefore
aspirational for RDF consumers.

C12g. Module-name spelling drift in the ontology itself (SHOULD, M1):
`ontology.ttl:165,174,183` declare `ap:targetRuntime "AshPplan.Reactor.Durable"`
(lowercase second p) but the actual module is `AshPPlan.Reactor.Durable`; the typo is
propagated into the generated catalog (`catalog/projection_catalog.ex:57,65,73`).
Elixir module names are case-sensitive, so the ontology's own projection rows point at
non-resolvable module names. The README uses the correct spelling. Repair the three
ontology literals and re-run `./bin/manufacture`.

### 2.4 RDF hygiene (audit item 4)

**C13 (MUST — FAIL at audit time; F1 — FIXED 2026-10-04 late, see §5 F1 receipt for current
evidence).** The shipped pack copy of the ontology MUST NOT diverge from
the canonical file, and its provenance header MUST NOT make false claims.
`README.md:94` (contract item 2) states `priv/ggen/ash-pplan-pack/ontology.ttl`
"remains a symlink to that source, so ggen_igniter cannot drift onto a second
ontology." Reality on 2026-10-04:
- It is a **regular file**, not a symlink.
- Its header (`priv/ggen/ash-pplan-pack/ontology.ttl:1-3`) claims "real-file copy of
  the canonical repo-root ontology.ttl (**same SHA-256**)".
- Actual SHA-256: canonical `f8575e82928efea0…`, pack copy `f32d7dffe4189cff6…` — they
  **differ**. The pack copy is missing the entire Spark DSL extension vocabulary block
  exactly the terms consumed by the ggen DSL pack — i.e. it IS a second ontology on
  disk: the failure mode the contract exists to prevent.

Evidence: `diff` + `shasum -a 256` run 2026-10-04; missing terms include
`ap:DslExtension`, `ap:DslEntity`, `ap:dslModule`, `ap:dslWrapperModule`,
`ap:dslSectionName`, `ap:dslEntityName` — all of `ontology.ttl:465-525` is absent from
the copy).

**C14 (MUST — F2 FIXED 2026-10-04: `ap:Provider a rdfs:Class` at `ontology.ttl:296`; all 13
properties declared, one `a rdf:Property` each).** Every property and class IRI used in the ontology
graph
MUST be declared in that graph (self-description / OWL-DL profile).
`ap:Provider` is used as a class 12 times (`ontology.ttl:347-463`) and **never
declared** (no `ap:Provider a rdfs:Class` anywhere in the file). Thirteen properties
are used without declaration: `ap:capabilityId`, `ap:family`, `ap:providerId`,
`ap:providerModule`, `ap:cost`, `ap:supportsCapability`, `ap:supportsProperty`,
`ap:emitsEvidence`, `ap:realization`, `ap:adapter`,
`ap:operation`, `ap:stepOptions`, `ap:name` (blank-node blocks at
`ontology.ttl:354-463` and `ontology.ttl:512-517`). Consequence: a foreign consumer
cannot close the profile over the file; OWL-DL reasoning requires declarations. (Note:
the local SHACL gate passes because `shapes.ttl` constrains only the Projection/plan/
variable shapes, not the provider section — the gate and the file are consistent, the
gap is in the ontology's self-description.)

**C15 (SHOULD — M5 FIXED 2026-10-04: receipt IRI is run-scoped).** Receipt IRIs MUST/SHOULD identify
the described receipt.
`to_rdf/1` mints `urn:ash-pplan:receipt:<outcome_digest>` where the digest covers only
the *outcome term* (`execution_receipt.ex:227-250`, `observe/5` at :171-186); `run_id`
is not in the digest. The moduledoc states two runs observing the same result share a
digest (`execution_receipt.ex:10-12`). Therefore two runs of the same plan with the same
result produce the **same receipt IRI with different `ap:runIdentifier` literals**
(e.g. `"run-1"` vs `"run-2"`), yielding a non-lean, self-contradictory graph under
any merge. Repair options: include run identity in the receipt IRI, or stop asserting
`ap:runIdentifier` on the shared IRI. Marked SHOULD (not MUST) because a single-run
graph is always well-formed; merging across runs is where it breaks.

**C16 (SHOULD — M4 FIXED 2026-10-04: `to_rdf/1` emits `ap:repo`/`ap:subjectSha`/`ap:baseSha` when
present, `execution_receipt.ex:114-120`; declarations added to root `ontology.ttl:113-127`, mirror
packs not yet re-synced — see F1).** Struct fields that exist for identity SHOULD appear in the
RDF projection. `ExecutionReceipt` carries `repo`, `subject_sha`, `base_sha` with a
dedicated validator (`execution_receipt.ex:189-216`), documented as subject-identity
anchoring, but `to_rdf/1` (`execution_receipt.ex:80-103`)
emits none of them. An RDF consumer of the receipt graph cannot see the anchored
repository identity that the Elixir-side contract guarantees. Suggested terms: local
`ap:repo`, `ap:subjectSha`, `ap:baseSha` declared with `rdfs:range xsd:string`
(or `prov:atLocation` for repo only — MAY).

**C17 (SHOULD — PASS; H1 partially fixed 2026-10-04: `dcterms:modified`, `owl:priorVersion`,
`vann:preferredNamespacePrefix/Uri` now present at `ontology.ttl:15,17,19-20`; `dcterms:license`
still absent).** Imports and version metadata.
`owl:versionInfo "26.10.3"` (`ontology.ttl:14`) and `dcterms:issued "2026-09-06"^^xsd:date`
(`:13`) present and correctly typed. Missing (MAY, H1): `dcterms:modified`,
`owl:priorVersion`, `vann:preferredNamespacePrefix/Uri`, `dcterms:license` —
advisable for a w3id.org-hosted profile. The two `owl:imports` resolve to real,
fetchable ontology documents (verified: purl.org dereferences;
prov-o dereferences to 1146-triple graph).

**C18 (MAY).** Typing of local terms: all classes typed `rdfs:Class` and all properties
typed `rdf:Property`. Valid RDFS; typing as `owl:Class` / `owl:ObjectProperty` /
`owl:DatatypeProperty` would let the profile close under OWL 2 DL (relevant since the
header declares `owl:imports` — an OWL concept). Properties with `xsd:string` ranges
(`ap:runIdentifier` `ontology.ttl:93-96`, `ap:executionStatus`, `ap:resultDigest`,
`ap:workflowSubject`, `ap:packId`, `ap:authorityCeiling`, the `ap:dsl*` family) are
naturally datatype properties; `ap:requiresCapability` etc. object properties.

**C19 (MAY, H2).** IRI local-name style is mixed across the same namespace:
`PascalCase` classes (`ap:ExecutionReceipt`), camelCase properties (`ap:runIdentifier`),
kebab-case individuals (`ap:projection-plan`), snake_case individuals
(`ap:cap_Domain_Create`, `ap:provider_domain`), and one camelCase individual
(`ap:dslSection_task` mixes both). Harmless to machines; a name policy would help
human reviewers.

**C20 (MAY, H3).** 167 blank nodes exist as subjects (provider realization blocks,
DSL transformer/verifier rows). Legal; mintable IRIs would let receipts and audits
reference specific realizations instead of structurally identifying them.

**C21 (MAY, H4).** `workflow/evidence.ex:124-129` appends the subject-binding triple by
raw string interpolation (`"<#{receipt_iri}> <#{@ap}workflowSubject> \"#{subject_id}\" .\n"`)
without the escaping `to_rdf/1` applies. The value is digest-constrained today
(`"sha256:" <> 64-hex`, `subject.ex:13-27`), so no live defect; use the same escaper
before anyone widens the input.

**C22 (MAY, M2).** `LedgerOCEL` event timestamps equal export time, not occurrence
time (`ledger_ocel.ex:46,55,72,97`), documented honestly in the
moduledoc (`:11-13`) with the authoritative `seq` carried in attributes. OCEL 2.0
JSON remains schema-valid; consumers of the *times* get export-time values. An
occurrence-time estimate SHOULD be recorded if the durable store later persists
wall-clock times.

**C23 (SHOULD — M6 FIXED 2026-10-04: both exporters use task_succeeded; `task_checkpointed` no
longer appears anywhere).** The two OCEL exporters name the same underlying event
class differently. `LedgerOCEL` emits `activity: "task_succeeded"` per standing
checkpoint (`ledger_ocel.ex:5,72`) while `Reactor.Middleware.Observation.ledger_events/2`
emits `task_checkpointed` for the same checkpoint kind (`observation.ex:205`).
Process-mining consumers merging both streams see two event types for one concept.
Pick one name (or declare both as `rdfs:subPropertyOf`-like sub-events of a common
term in the profile).

**C24 (MUST — PASS).** The executable profile is anti-vacuous. `./bin/conform` →
`CONFORMS=True` (685 triples), `./bin/conform-falsify` → **13 counterexamples refused**
(including plan-with-no-steps, step with two labels, literal source term, cross-plan
variable, step/variable outside any plan). The gate is real, not decorative.

### 2.5 Semantic gaps — implemented but undeclared (audit item 5)

**G1 (SHOULD — DECLARATION FIXED 2026-10-04: `ap:SemanticExecution rdfs:subClassOf prov:Activity,
p-plan:Activity` at `ontology.ttl:43-44`; emission of
`p-plan:correspondsToStep`/`correspondsToVariable` remains unimplemented).** Step-level execution
correspondence exists in code, not in the
ontology. `compiler.ex:258-270` writes `step_iri` (plus input/output variable lists and
predecessor maps) into each Reactor step context, and
`Reactor.Middleware.Observation` emits per-step events whose identity comes from
`AshPPlan.Reactor.identity_of/1` (`observation.ex:64-71`); `LedgerOCEL` emits
`{"Step", "step:<label>", …}` objects (`ledger_ocel.ex:73-77`). None of this is
expressed with the P-PLAN terms designed for it: no `ap:SemanticExecution` ⊑
`p-plan:Activity` (`ontology.ttl:38-41` subclasses `prov:Activity` only), and
`p-plan:correspondsToStep` / `p-plan:correspondsToVariable` are never used anywhere.
Consequence: an RDF consumer cannot verify "this activity executed that step" from the
published semantics. Minimal repair: declare `ap:SemanticExecution rdfs:subClassOf
p-plan:Activity` (safe: `p-plan:Activity` ⊑ `prov:Activity`), declare an
`ap:executesStep` property (or use `p-plan:correspondsToStep`, domain
`p-plan:Activity` → range `p-plan:Step`) and emit it from `to_rdf/1` or the step
evidence events.

**G1 continued (MAY).** `p-plan:MultiStep` / `isDecomposedAsPlan` / `isSubPlanOfPlan`
implement decomposition implicitly: workflow `methods` (HDDL decomposition,
`workflow.ex:17-21`, `task.ex`/`method.ex`) decompose tasks into substructure and
`Subject.correspondence/2` (`subject.ex:35-45`) computes cross-paradigm ids
(`pplan`/`hddl`/`fond`/`reactor`), yet no P-PLAN decomposition term is declared or
used; `ap:Correspondence` (`ontology.ttl:262-264`) is declared but no RDF is emitted
for it either.

`ap:Correspondence` has no `rdfs:range` on `ap:correspondsTo` (`ontology.ttl:295-297`)
and `ap:Correspondence` itself has no linkage to `Subject.bind/1`'s computed map.
Undeclared-in-RDF computed correspondence is the single largest
implemented-but-unexpressed region of the profile.

**G3 (SHOULD).** Agent participation: see C12f. Declared in the catalog
(`ontology.ttl:153-160`), implemented as Ash actor context, never serialized as
`prov:wasAssociatedWith` / `prov:actedOnBehalfOf` with a typed `ap:`-or-`prov:Agent`
resource.

**G4 (MAY).** Receipt time anchors: the receipt Entity carries no `prov:generatedAtTime`
(Entity domain, the PROV-correct term for when the evidence came to exist);
The execution Activity carries `startedAtTime`/`endedAtTime`, which is correct
but does not type the receipt Entity's generation time. Emitting
`prov:generatedAtTime` on the receipt would make the evidence entity's PROV record
complete without new vocabulary.

**G5 (MAY).** FrontierEvidence and standing receipts are not in the profile at all:
`AshPPlan.FrontierEvidence` emits a JSON envelope (`frontier_evidence.ex:17-44`) and
`AshPPlan.Standing.Receipt` is generated from a *separate* vocabulary
(`priv/ggen/ash-pplan-standing-pack/ontology.ttl`, namespace `sg:`), which does not
`owl:imports` or otherwise link to the canonical `ap:` ontology. Legitimate
design (separate vocabulary), but the audit notes the standing layer — the part of
ash_pplan that judges evidence — is outside the audited semantic profile, so P-PLAN
consumers get no standing semantics in RDF at all.

## 3. Findings index (ranked)

| # | Severity | ID | Summary | Evidence |
|---|---|---|---|---|
| 1 | MUST | F1 | **FIXED 2026-10-04 (re-verified post-R2 promotion, see §5 receipt)**: header-stripped body SHA-256 identical across root + all three mirrors (`0d6b827c1ec150e77…`) at 1041 triples; the cd212e7b mirror re-sync survived the R2 promotion. Residual whole-file differences are the provenance headers only (by construction) | `priv/ggen/*/{pack,dsl-pack,workflow-pack}/ontology.ttl` vs `ontology.ttl` (§5 F1 receipt) |
| 2 | MUST | F2 | **FIXED 2026-10-04**: `ap:Provider` declared (`ontology.ttl:296`); all 13 properties declared | `ontology.ttl:296+` |
| 3 | SHOULD | M5 | **FIXED 2026-10-04**: receipt IRI run-scoped `urn:ash-pplan:receipt:<run_id>:<outcome_digest>` | `execution_receipt.ex:85-90` |
| 4 | SHOULD | M1 | **FIXED 2026-10-04**: casing corrected (3 rows) in `ontology.ttl:185,194,203` and regenerated `projection_catalog.ex:57,65,73`; zero AshPplan matches | `ontology.ttl`; `catalog/projection_catalog.ex` |
| 5 | SHOULD | G1 | **PARTIALLY FIXED 2026-10-04**: `ap:SemanticExecution rdfs:subClassOf prov:Activity, p-plan:Activity` declared (`ontology.ttl:43-44`); `p-plan:correspondsToStep` emission still unimplemented | `ontology.ttl:43-44` |
| 6 | SHOULD | G3 | `prov:Agent` row declared in catalog but no agent ever serialized (wasAssociatedWith/actedOnBehalfOf absent everywhere) — unchanged | `ontology.ttl:153-160`; grep of `lib/` |
| 7 | SHOULD | M6 | **FIXED 2026-10-04**: unified on task_succeeded in both exporters | `ledger_ocel.ex:76` vs `observation.ex:127,207` |
| 8 | SHOULD | M4 | **FIXED 2026-10-04**: `to_rdf/1` emits `ap:repo`/`ap:subjectSha`/`ap:baseSha` when present; declarations in root `ontology.ttl:113-127` (mirror re-sync outstanding, see F1) | `execution_receipt.ex:114-120`; `ontology.ttl:113-127` |
| 9 | SHOULD | C5 | **FIXED 2026-10-04**: `ap:FONDPolicy`/`ap:PolicyDecision` now `rdfs:subClassOf prov:Plan, p-plan:Plan` | `ontology.ttl:66-67,75-76` |
| 10 | SHOULD | M3 | README `p-plan:Variable` row over-promises: variables are Reactor context data only; hasInputVar/hasOutputVar enforced nowhere at runtime | `README.md:13`; `compiler.ex:87,258-270` |
| 11 | MAY | H1 | **PARTIALLY FIXED 2026-10-04**: `dcterms:modified` (`:15`), `owl:priorVersion` (`:17`), `vann:preferredNamespacePrefix/Uri` (`:19-20`) added; `dcterms:license` still absent | `ontology.ttl:10-20` |
| 12 | MAY | H2 | Mixed IRI local-name conventions in one namespace | `ontology.ttl` (projection-plan vs cap_Domain_Create vs dslSection_task) |
| 13 | MAY | H3 | 167 blank-node subjects; realization/DSL rows unreferencable | `ontology.ttl:354-463,512-517` |
| 14 | MAY | H4 | workflowSubject triple built by raw interpolation, no escaping | `workflow/evidence.ex:124-129` |
| 15 | MAY | G4 | No `prov:generatedAtTime` on the receipt Entity | `execution_receipt.ex:87-101` |
| 16 | MAY | G5 | Standing/OCEL vocabularies (sg:, OCEL JSON) live outside the audited profile; standing pack ontology does not import the canonical ontology | `priv/ggen/ash-pplan-standing-pack/ontology.ttl:1-8` |
| 17 | MAY | M2 | LedgerOCEL event timestamps are export time, not occurrence time (documented) | `ledger_ocel.ex:11-13,46,72,97` |

## 4. Verification receipt (what was actually run)

- `curl -sL http://purl.org/net/p-plan` → P-PLAN 1.3 OWL (vocab.linkeddata.es), parsed.
- PROV-O fetched live (`https://www.w3.org/ns/prov-o`, 1146 triples) and term-checked.
- Scripted vocabulary + domain/range audit (rdflib): 0 undefined terms, 0 fixture
  domain/range violations, superclass graph extracted.
- `MIX_ENV=test mix run` real execution of `AshPPlan.ExecutionReceipt.to_rdf/1`
  (11 triples emitted) + rdflib N-Triples round-trip parse.
- `./bin/conform` → `CONFORMS=True`, `ONTOLOGY_TRIPLES=685`.
- `./bin/conform-falsify` → 13 counterexamples refused, exit 0.
- `shasum -a 256` + `diff` of `ontology.ttl` vs `priv/ggen/ash-pplan-pack/ontology.ttl`
  → hashes differ, 20+ lines of drift.
- Disk check: 24/24 README-mapped modules exist.

## 5. Fix receipts (2026-10-04)

Post-fix re-audit: each item re-verified by direct file inspection on the working tree
(head `c42ee19` plus uncommitted changes). Only statuses verified on disk were changed;
verdict text for unverified findings is untouched.

### F1 — FIXED (re-verified 2026-10-04, post-R2 promotion)

Re-verified 2026-10-04 after the R2 promotion grew the ontology (953 → 1041 triples;
root whole-file SHA-256 now `cd212e7bd242d978fce1…`, mirrors re-synced at `cd212e7b`).
The re-sync survived the promotion: header-stripped SHA-256 is identical across the
root and all three mirrors.

```
$ strip() { grep -v '^# ' "$1" | sed '/./,$!d'; }   # drop full GENERATED-PROVENANCE header block + leading blank
$ for f in ontology.ttl priv/ggen/ash-pplan-dsl-pack/ontology.ttl \
      priv/ggen/ash-pplan-pack/ontology.ttl priv/ggen/ash-pplan-workflow-pack/ontology.ttl; do
    strip "$f" | shasum -a 256; done
0d6b827c1ec150e77f80d1f0d2f6e051f17ac2f6fe46cc1f9e24204aaf30f664  (all four identical)

# whole-file SHA-256 (raw, header included — differs by construction):
root                          cd212e7bd242d978fce18c5ac7640d63ac137377226761ea05a02fa0468208c8
ash-pplan-pack                c8abcb1b14d159f14aebf4c5a2479d0982b3cc37ec5c852bd15330b103ab1e65
ash-pplan-dsl-pack            b63fa769911d0aec9eee6f32fb8d2ad6f1de6e41cfec0173a31d6dd48818ac23
ash-pplan-workflow-pack       c8abcb1b14d159f14aebf4c5a2479d0982b3cc37ec5c852bd15330b103ab1e65
# post-strip residual diff vs root: only the header comment lines themselves
# (`# pack-digest court…`, `# Keep in sync…`) + the blank separator line;
# dsl-pack has no blank 4th line. Zero body divergence.
```

Court gate (isolated build root `_build-f1v`), 2026-10-04:
`MIX_BUILD_ROOT=_build-f1v mix compile --warnings-as-errors` → exit 0, clean compile.
`MIX_BUILD_ROOT=_build-f1v mix test test/courts/ontology_semantics_court_test.exs
test/courts/pplan_upstream_court_test.exs`
→ **10 tests, 0 failures**.

`./bin/conform` on this working tree: `ONTOLOGY_TRIPLES=1041` (matches the R2
promotion) but `CONFORMS=False` — the failure is **not F1**: ggen law-validate refuses
pack `ash-pplan-chaos` with `[FM-PACK-005] zero templates under
priv/ggen/vendor/ash-pplan-chaos-pack/templates` (vendor pack regression, owning lane =
whatever owns the vendor chaos-pack / the deleted `priv/ggen/ash-pplan-chaos-pack-acp-rows.ttl`;
out of F1's scope, mirrors' ontology bodies are unaffected).

### F2 — FIXED

```
$ grep -n "ap:Provider a rdfs:Class" ontology.ttl
296:ap:Provider a rdfs:Class ;

$ for p in capabilityId family providerId providerModule cost supportsCapability \
      supportsProperty emitsEvidence realization adapter operation stepOptions name; do
    printf "%s: " "$p"; grep -c "ap:$p a rdf:Property" ontology.ttl; done
capabilityId: 1
family: 1
providerId: 1
providerModule: 1
cost: 1
supportsCapability: 1
supportsProperty: 1
emitsEvidence: 1
realization: 1
adapter: 1
operation: 1
stepOptions: 1
name: 1
```

### M1 — FIXED

```
$ grep -n "AshPplan" ontology.ttl lib/ash_pplan/catalog/projection_catalog.ex
(no output, exit 1)

$ grep -n "AshPPlan.Reactor.Durable" ontology.ttl lib/ash_pplan/catalog/projection_catalog.ex
lib/ash_pplan/catalog/projection_catalog.ex:57:      target: "AshPPlan.Reactor.Durable",
lib/ash_pplan/catalog/projection_catalog.ex:65:      target: "AshPPlan.Reactor.Durable",
lib/ash_pplan/catalog/projection_catalog.ex:73:      target: "AshPPlan.Reactor.Durable",
ontology.ttl:185:    ap:targetRuntime "AshPPlan.Reactor.Durable" ;
ontology.ttl:194:    ap:targetRuntime "AshPPlan.Reactor.Durable" ;
ontology.ttl:203:    ap:targetRuntime "AshPPlan.Reactor.Durable" ;
```

### M4 — FIXED (emission; root declarations present, mirror re-sync outstanding)

```
$ sed -n '114,120p' lib/ash_pplan/execution_receipt.ex
    identity_triples =
      [
        {"repo", receipt.repo},
        {"subjectSha", receipt.subject_sha},
        {"baseSha", receipt.base_sha}
      ]
      |> Enum.reject(fn {_pred, value} -> is_nil(value) end)

$ grep -n "ap:repo a\|ap:subjectSha a\|ap:baseSha a" ontology.ttl
113:ap:repo a rdf:Property ;
118:ap:subjectSha a rdf:Property ;
123:ap:baseSha a rdf:Property ;
```

### M5 — FIXED

```
$ sed -n '85,90p' lib/ash_pplan/execution_receipt.ex
    receipt_iri =
      "urn:ash-pplan:receipt:" <>
        URI.encode(run_identifier(receipt.run_id), &URI.char_unreserved?/1) <>
        ":" <> receipt.outcome_digest
```

### M6 — FIXED

```
$ grep -n "task_succeeded\|task_checkpointed" \
    lib/ash_pplan/reactor/durable/ledger_ocel.ex lib/ash_pplan/reactor/middleware/observation.ex
lib/ash_pplan/reactor/middleware/observation.ex:127:      stop: "task_succeeded",
lib/ash_pplan/reactor/middleware/observation.ex:207:  activity: if(cp.undone_at, do: "task_undone", else: "task_succeeded"),
lib/ash_pplan/reactor/durable/ledger_ocel.ex:76:          activity: "task_succeeded",
(no `task_checkpointed` matches)
```

### G1 / C5 (SemanticExecution, FONDPolicy, PolicyDecision) — DECLARATIONS FIXED

```
$ grep -n "subClassOf" ontology.ttl | grep -n "p-plan:"
44:    rdfs:subClassOf prov:Activity, p-plan:Activity ;      (ap:SemanticExecution, :42)
67:    rdfs:subClassOf prov:Plan, p-plan:Plan ;              (ap:FONDPolicy, :65)
76:    rdfs:subClassOf prov:Plan, p-plan:Plan ;              (ap:PolicyDecision, :74)
```

### H1 — PARTIALLY FIXED

```
$ grep -n "dcterms:modified\|priorVersion\|vann:" ontology.ttl
15:    dcterms:modified "2026-10-03"^^xsd:date ;
17:    owl:priorVersion <https://w3id.org/ash-pplan/26.10.2> ;
19:    vann:preferredNamespacePrefix "ap" ;
20:    vann:preferredNamespaceUri <https://w3id.org/ash-pplan#> .
(dcterms:license: no match)
```
