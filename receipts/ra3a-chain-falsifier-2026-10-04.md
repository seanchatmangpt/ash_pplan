# RA3a: `chain.ex.tmpl` vs `execution_receipt.ex` falsifier (2026-10-04)

## Question

The E3 reopen trigger (lib/HANDWRITTEN.md, 2026-10-04) recorded
evidence-standing-pack `chain.ex.tmpl` as "the first Elixir template class in
the standing/evidence domain" and stated it reopens `execution_receipt.ex` if
it covers the module's identity/serialization semantics. It fires only on that
condition. This receipt resolves the trigger.

## Sources

- Subject: `/Users/sac/ash_pplan/lib/ash_pplan/execution_receipt.ex` (367 LOC)
- Template: `/Users/sac/ggen-marketplace/packs/evidence-standing-pack/templates/chain.ex.tmpl` (117 lines, emits `lib/es/chain.ex`)

## 1. Public surface of execution_receipt.ex

| surface | line | semantics |
|---|---|---|
| `to_rdf/2` | 102 | PROV-O N-Triples serializer: 11 base triples (ExecutionReceipt/Entity, SemanticExecution/Activity, wasGeneratedBy, used, runIdentifier, executionStatus, resultDigest, startedAtTime/endedAtTime typed xsd:dateTime) + conditional identity anchors + step correspondence |
| `validate_identity/1` | 261 | DfCM subject-identity anchoring: repo non-blank, subject_sha/base_sha strict 40-lowercase-hex, `{:error, {:bad_identity, field}}` refusal |
| `run_identifier/1` | 169 | run-id term normalization (valid-UTF-8 binary / atom / integer / inspect fallback) |
| `observe/5-6` | 228 | receipt construction: wall/mono clocks, status classification over Reactor outcome shapes, outcome digest, opts threading (repo/subject_sha/base_sha/corresponds_to_steps) |
| `escape_iri/1` + `escape_literal/1` | 192, 209 | RFC 3986/N-Triples IRIs (percent-encode #x00-#x20, `<>{}|^` + backtick, DEL, non-UTF-8 bytes) and STRING_LITERAL_QUOTE escaping (\\, ", LF, CR, TAB, \uXXXX for other controls) |
| `corresponds_to_steps` opts | 150 | opt-in p-plan:correspondsToStep emission; call-site opts > persisted steps > none ("honest absence") |
| digest/canonical internals | 291-366 | deterministic term_to_binary SHA-256 over canonicalized outcome (refs/pids/ports/functions → tokens, structs minus stacktrace, sorted maps), halt/failed digest specialization |

## 2. What chain.ex.tmpl actually emits

A single module `Es.Chain` — an append/verify/seal **hash-chained ledger**:

- module constants interpolated from `es:ChainPolicy/Phase/Standing` RDF rows
  (`@algorithm`, `@genesis`, `@fields`, `@phases`, `@standings`, `@neutral`)
- `digest/1` — SHA-256/SHA-512 hex of a text blob (algorithm chosen from RDF)
- `canonical/1` — join `field=value` lines over a plain map, LF banned
- `make/7` (private) — builds an `%{entry_id, parent_hash, phase, standing,
  subject, action, pending_ref, seal, hash}` map chained to the parent hash
- `append_pending/4`, `append_outcome/5`, `seal/4`, `sealed?/1`, `unpaired/1`,
  `paired?/2` — pending→outcome pairing and single-seal enforcement
- `verify/1` — parent-hash + digest + pairing + seal-position reduction

What it does NOT emit: no struct (`defstruct`/`@enforce_keys` absent — entries
are ad-hoc maps), no PROV-O vocabulary, no RDF/N-Triples serialization of any
kind, no IRI or literal escaping, no DateTime handling, no identity
validation, no observe path, no Reactor-outcome status classification, no
corresponds_to_step semantics. Its output format is a newline-joined
`field=value` canonical string feeding a chain hash — not a serialization of
an observed execution into RDF.

## 3. Overlap

Shared: exactly one idiom — `:crypto.hash(:sha256, ...) |> Base.encode16(case: :lower)`
(chain.ex.tmpl:43; execution_receipt.ex:363-365, where it digests
`term_to_binary(term, [:deterministic])` of a canonicalized term, not a
`field=value` text). No function, type, semantic, or output-format overlap.
Overlap ≈ 1 LOC of 367 (< 1%).

Output file also disjoint: template targets `lib/es/chain.ex` (module
`Es.Chain`), subject is `lib/ash_pplan/execution_receipt.ex` (module
`AshPPlan.ExecutionReceipt`).

## Verdict: UNSUPPORTED (generator-capability)

The reopen trigger does NOT fire: `chain.ex.tmpl` covers hash-chain ledger
semantics (append/verify/seal over RDF-configured phases and standings), not
the module's identity/serialization semantics (PROV-O N-Triples projection,
DfCM identity validation, outcome observation). Zero emission overlap: no
template variable, branch, or loop in chain.ex.tmpl can produce a triple, an
IRI escape, or a receipt struct. `execution_receipt.ex` remains handwritten
residue; its existing UNSUPPORTED row (ERRC R4,
receipts/r4-falsifier-runs-2026-10-04.md) is confirmed and now dated against
this second, Elixir-template pack.

## Reopen trigger (updated)

`execution_receipt.ex` reopens only if a pack ships an Elixir template class
emitting PROV-O / RDF serialization (N-Triples subject/predicate/object lines,
typed-literal datatypes, IRI/literal escaping) or a DfCM identity-validation
class (40-hex subject anchoring). chain.ex.tmpl itself does not.
