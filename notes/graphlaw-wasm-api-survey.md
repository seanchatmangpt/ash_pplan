# GraphLaw WASM API Survey (lane W1)

Date: 2026-10-01. Read-only survey of `/Users/sac/graphlaw` (Rust) and the
consumer side in `/Users/sac/ash_pplan`. Facts below were read from source, not
inferred.

## 1. The wasm module

- Crate: `/Users/sac/graphlaw/wasm/Cargo.toml` — package `graphlaw-wasm`
  v26.9.29, `crate-type = ["cdylib"]`, depends on parent crate `graphlaw`
  with features `abi, wasi-patched-deps`.
- Target: `wasm32-wasip1` (WASI preview1). `wasm32-unknown-unknown` is
  explicitly unsupported (needs a JS host).
- Prebuilt artifact, built Sep 30:
  `/Users/sac/graphlaw/target/wasm32-wasip1/wasm/graphlaw_wasm.wasm`
  (6,657,549 bytes; a second copy under `target/wasm-abi/` at 6,657,612 bytes).
  Release CI also ships it as `graphlaw.wasm` on GitHub releases with a
  checksum.
- Imports are `wasi_snapshot_preview1` only (clock, random, stdio) — no
  JavaScript, no wasm-bindgen host shims.

## 2. Exports and wire format (from wasm/src/lib.rs)

Three C-ABI exports plus memory; request and response are UTF-8 JSON:

1. `gl_alloc(len: u32) -> ptr` — host reserves `len` bytes, writes the JSON
   request there.
2. `gl_call(ptr, len) -> u64` — runs the request, consumes (frees) the request
   buffer, returns `packed = (out_ptr << 32) | out_len`.
3. `gl_free(ptr, len)` — host frees the response buffer.

Response is always JSON: `{"ok":true,...}` or
`{"ok":false,"error":{kind, engine, dialect, message, details}}` with kinds
`NotSemanticContent | Ambiguous |EngineRejected | Unsupported | ResourceLimit`.
Limits: 16 MiB max request, JSON depth 64, 1,000 plan actions, 4,000 N3
iterations. `gl_alloc` returns null past limits; `gl_call` on a null buffer is
a typed error response, never a trap.

Note: this is a NEW plain-C JSON ABI. It is NOT the older `praxis_graphlaw.wasm`
(wasm-bindgen `graph_hash` exports) that `AshA2A.GraphLaw.WasmexHost` hosts —
do not copy that host's wbindgen stack-pointer dance; it does not apply. The
new ABI is simpler: three extern fns over linear memory.

## 3. RDF/SPARQL capability vs the 18 gates

`sparql` op: request `{"op":"sparql", "data": {"text":..., "dialect"?:"turtle"},
"query": "...", "base"?}`. Response is a tagged union on `kind`:
`solutions` (`variables[]`, `rows[][]` of term objects `{type: uri|bnode|literal,
value, datatype?, xml:lang?}`, unbound = `null`), or `graph` (`nquads`,
`quads`), or `boolean` (`value`).

Engine coverage per README/abi-reference: all RDF dialects, SPARQL 1.1, SHACL,
ShEx, RDF/RDFS/OWL-RL/D entailment, N3, Datalog, knowledge hooks — all inside
the module. There is a `parse` op that syntax-checks `sparql` dialect text, so
unsupported syntax is detectable up front.

Feature census over `/Users/sac/ash_pplan/priv/ggen/*/gates/*.rq`:
ORDER BY ×30, DISTINCT ×24, OPTIONAL ×4, BIND+AS ×3, UNION ×1, LIMIT ×1,
and ZERO aggregates (no GROUP BY / COUNT / aggregates). All used features are
SPARQL 1.1 core syntax; none is exotic. Residual risk is whether PurRDF's
SPARQL engine implements ORDER BY/OPTIONAL/BIND exactly — the go-gate falsifier
below covers this for zero code.

Falsifier: run all 18 gate .rq files through `{"op":"parse","text":<rq>,
"dialect":"sparql"}` (syntax) and then through `{"op":"sparql"}` against the
pack's data, and compare row counts to the current gate runner. This can be
done today in Rust via `tests/wasm_abi.rs` as the template (it drives every op
in a real wasm runtime, wasmi-based, 942 lines).

## 4. Elixir hosting: already-proven pattern, dep already in tree

wasmex is ALREADY in ash_pplan's dependency tree:
- `mix.lock`: `"wasmex": {:hex, :wasmex, "0.15.1", ...}` (via ex4pm `~> 0.14`
  and ggen_igniter `~> 0.9`).
- `beam4pm/mix.exs:89` `{:wasmex, "~> 0.15"}`; `ggen_igniter/mix.exs:294`
  `{:wasmex, "~> 0.9"}`.
- ggen_igniter already binds the OLD graphlaw wasm in-BEAM via
  `AshA2A.GraphLaw.WasmexHost` (kernel_differential.ex) — the pattern is field
  proven; only the ABI differs.

Recommended host pattern for `GgenIgniter.Engine.Graphlaw` (adapted from
`~/ash_a2a/lib/ash_a2a/graph_law/wasmex_host.ex`, minus the wbindgen parts):

- One long-lived supervised GenServer owning one `Wasmex.Store` +
  `Wasmex.Instance`, serialized `handle_call` (multi-step memory transactions
  must not interleave).
- Instantiate with WASI imports satisfied by wasmex's built-in WASI support
  (wasmex >= 0.9 supports `wasi: {path: ..., args: ...}`) or by supplying the
  three wasi_snapshot_preview1 functions. Call `_initialize` once if wasmex
  does not.
- Per transaction (all inside one handle_call):
  ```elixir
  {:ok, ptr} = Wasmex.call_function(store, instance, "gl_alloc", [byte_size(req)])
  Wasmex.Memory.write_binary(store, memory, ptr, req)
  [packed] = Wasmex.call_function(store, instance, "gl_call", [ptr, byte_size(req)])
  out_ptr = packed >>> 32
  out_len = packed &&& 0xFFFFFFFF
  resp = Wasmex.Memory.read_binary(store, memory, out_ptr, out_len)
  Wasmex.call_function(store, instance, "gl_free", [out_ptr, out_len])
  ```
  wrap in try/after; on trap/exit recycle the instance from a cached compiled
  module; digest-pin the .wasm by sha256; fuel + StoreLimits memory_size cap;
  refuse non-UTF-8 before writing to memory.
- Wire: encode request with Jason, decode response with Jason, check `ok`
  flag; refusals map to a typed `{:error, %{kind, engine, dialect, message}}`.
- Vendoring: copy the .wasm (6.66 MB) into
  `priv/ggen/graphlaw/graphlaw_wasm.wasm` with a MANIFEST sha256 pin, mirroring
  `AshA2A.GraphLaw.EngineLoad`.

## 5. Performance / size

- Module 6.66 MB on disk; Wasmtime Cranelift compile of a module this size is
  roughly 100–300 ms one-time, then per-instance instantiation is single-digit
  ms. Per-op `gl_call` is a plain function call plus JSON parse — microseconds
  to low milliseconds.
- Data passes in every request (16 MiB cap, plenty for pack TTLs), so per-query
  prepare means re-sending the pack data string per gate query — 18 gates/pack
  is comfortably viable. Alternative if profiling says so: one `law` op request
  can chain multiple steps per call, or batch all gates into one request round.
- Memory: give the store a cap (e.g. 256 MiB) and a recycle high-water mark
  (linear memory never shrinks); ash_a2a measured a poisoned instance growing
  GBs on the OLD ABI, and the new ABI's own caps (16 MiB request, outstanding
  alloc cap) plus host-side limits close that class.

## 6. Go / no-go

**GO**, conditional on one falsifier: drive the 18 shipped gate .rq files
through the wasm `sparql` op against real pack data and diff row counts
against the current gate runner. If any gate's syntax or semantics diverges,
the typed refusal names the gap (`Unsupported`/`EngineRejected`) and the
fallback is the existing in-BEAM gate path. No new hex deps needed (wasmex
0.15.1 already locked); no native toolchain needed at consumer build time if
the .wasm is vendored prebuilt.

## 7. Risks

1. SPARQL dialect gaps in PurRDF for ORDER BY / OPTIONAL / BIND / UNION —
   bounded by the falsifier above; `parse` op gives a cheap pre-flight.
2. WASI import satisfaction in wasmex — the module imports only
   wasi_snapshot_preview1 (clock/random/stdio); wasmex >= 0.9 has WASI support;
   verify at instantiation, otherwise satisfy manually.
3. Concurrency: one instance = serialized calls; pool N instances if gate
   throughput matters (ash_a2a has a pool pattern).
4. The old `AshA2A.GraphLaw.WasmexHost` is NOT reusable as-is (different ABI:
   wasm-bindgen graph_hash vs new gl_* JSON ABI) — adapt the lifecycle/limits
   pattern, not the call sequence.
5. Artifact provenance: pin by sha256 and record in MANIFEST; release CI ships
   `graphlaw.wasm` + checksum, so pin to the release asset, not a local target/
   copy, for the durable version.
