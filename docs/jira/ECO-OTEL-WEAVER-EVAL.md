# ECO-OTEL-WEAVER-EVAL — otel-weaver-ocel-pack applicability to ledger_ocel.ex

ERRC G4, evaluation only. Read-only on:
`/Users/sac/ggen-marketplace/packs/otel-weaver-ocel-pack`
and `/Users/sac/ash_pplan/lib/ash_pplan/reactor/durable/ledger_ocel.ex`.
No source edits, no git.

## 1. What the pack actually does

The pack is an RDF ontology (`ontology.ttl`) of `otelocel:MappingRule`s plus a
ggen template that renders a Rust transformer (`otel_to_ocel.rs`) which:
consumes an OTEL span (`trace_id/span_id/parent_span_id/name/start_time/
attributes/resource_attributes`), and admits it into wasm4pm-compat's typed
OCEL v2 evidence carrier (`Evidence<T, Admitted, Ocel20>` via a named `Admit`
impl — never Raw→Admitted free conversion). Gates (gates/010) refuse any
mapping fact that skips a resource-attribute-derived object relationship or
asserts a span→event mapping without a named object type.

Key mapping rule for this eval (`ontology.ttl` rule-event-time, order 30):

```
otelocel:rule-event-time ... sourceField "span.start_time_unix_nano"
  targetField "OCELEvent.time"
  derivation "time = span start time, parsed to chrono::DateTime<FixedOffset>"
```

The pack also validates semantic conventions via OpenTelemetry Weaver's
`registry check`/`live-check` (consumed through chicago-tdd-tools), and ships
a deployed hand-written `ocel_accumulator` sidecar (istio-system,
kind-platform-eng-colima) that is NOT ggen-templated.

## 2. Does it eliminate the export-time-stamp problem?

No. The pack does not weave timestamps from a stored non-timestamp source; it
ASSUMES them present. `rule-event-time` reads `span.start_time_unix_nano`
directly off the span. OTLP spans carry a start time by protocol construction
— every span is timestamped at the emitter, so the pack's entire pipeline is
"map an already-timestamped span honestly into OCEL v2". It has no notion of
a timestampless event being backstamped.

ash_pplan's problem is one step upstream: the durable
`AshPPlan.Reactor.Durable.Checkpoint` record (`records.ex`) has no wall-clock
field at all — only `run_id/step_key/label/name/output/impl/args/seq/
undone_at`. There is no stored per-checkpoint timestamp to feed any mapper,
pack or otherwise. `LedgerOCEL.build_events/3` correctly stamps
`Clock.now()` at export and carries `seq` in attributes; the moduledoc marks
this caveat load-bearing, and it is.

The only path by which the pack would apply is: ash_pplan starts emitting
each checkpoint as a real OTEL span at checkpoint time (persisting
`start_time_unix_nano` at claim/complete time — i.e. add a stored `at` to
`Checkpoint`, or run an `:otel` handler inline in the durable engine). Once a
stored timestamp source exists, the pack's mapping becomes exactly the right
consumer; until then it changes nothing.

## 3. What Rust/OTEL surface ash_pplan would have to adopt

- OTLP span shape as the emission contract: per-checkpoint span with
  `trace_id/span_id/parent_span_id/name/start_time_unix_nano/attributes/
  resource_attributes`.
- An Elixir-side OTel SDK path (opentelemetry / opentelemetry_ecto-style
  exporter) or a persisted-span sidecar the Rust transformer can read.
- The Rust transformer itself (cargo + wasm4pm-compat dep
  `Evidence<T, Admitted, Ocel20>` admission door) — a Rust toolchain in the
  ash_pplan verify ladder.
- OpenTelemetry Weaver `registry check` for the event semantic conventions
  (`task_succeeded`, `run_started`, `run_ended`).
- Deployment coupling to the already-deployed `ocel-accumulator` sidecar is
  optional but is the pack's real running integration.

## 4. Verdict: ADOPT-PARTIAL

Adopt the slice that is real capital for ash_pplan today:
- The OCEL v2 shape/admission discipline (typed events/objects with named
  object types and qualifiers, admitted via a named witness, never a free
  conversion) as the spec `ProcessEvidence.export/3` must keep satisfying —
  this is what `ocel_v2_mapping_court` already polices.
- The gate discipline (refuse mappings lacking object type/qualifier) as a
  model for pack gates on the ash-pplan-workflow-pack OCEL export.

Decline-for-now the runtime slice (Rust transformer + Weaver + accumulator
sidecar): its input contract is "a span that already has a stored
start_time". ash_pplan checkpoints have no stored timestamp, so the
transformer has no honest input — adopt it only after checkpoints carry
stored `at` values (falsifier for full adoption: an exported
`task_succeeded` event whose `time` differs from the checkpoint's stored
`at` — that must be unrepresentable).

### Courts that must stay green (either slice)

- `test/courts/ocel_v2_mapping_court_test.exs`
- `test/durable/ledger_ocel_hardening_test.exs`
- (supporting) `test/durable/semantic_reality_ocel_court_test.exs`,
  `test/burn_in/ocel_digest_endurance_test.exs`

### Honest remaining gap

The caveat survives full strength. Even under ADOPT-PARTIAL, exported
`task_succeeded` events carry export-time timestamps and only the ledger's
`seq` is authoritative order — standard miners still cannot consume the log
honestly without reading `seq` as the temporal key. The pack neither removes
nor mitigates this; it targets a pipeline (OTEL spans) that already has the
thing ash_pplan lacks (stored per-event timestamps). The minimal real fix
lives in ash_pplan, not the pack: persist a timestamp on `Checkpoint`
(or claim time in the durable engine) so no export ever backstamps.
