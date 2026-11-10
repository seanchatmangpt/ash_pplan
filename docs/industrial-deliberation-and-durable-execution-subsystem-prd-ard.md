# Engineering Requirements: Industrial Deliberation & Durable Execution Subsystem

> **Status banner (P12, 2026-11-07).** This document is a requirements
> specification, NOT a build report: the subsystem it describes is largely
> **NOT BUILT in this release**. What ships today is the slice ash_pplan
> already owns and courts: FOND validation/synthesis and the typed refusal
> surfaces, the durable Reactor ledger (`AshPPlan.Reactor.Durable.*`), the
> receipt/standing evidence layer, and the HTN/HDDL planning projection.
> The digital-twin fleet, deliberation market, cross-platform actuation
> leases, and statutory-envelope machinery described below are target
> requirements (ARD), not delivered capability. Read every "shall" in this
> document as forward-looking; the delivered contract is `README.md` +
> `docs/architecture.md` and their courts.

### Claim census (D7, 2026-11-07)

| Surface (Part 1/Part 2) | Status | Where it lives |
|:---|:---|:---|
| FOND synthesis / validation / counterexample / differential courts | BUILT (known defects being fixed) | in-repo: `fond.ex`, `lib/ash_pplan/fond/` |
| HTN/HDDL planning projection | BUILT (known defects being fixed) | in-repo: `htn.ex` |
| Semantic compiler + admission refusal surfaces | BUILT (known defects being fixed) | in-repo: `compiler.ex`, `lib/ash_pplan/compiler/` |
| SHACL shape engine (closed-world validation; shapes are external TTL data) | BUILT (known defects being fixed) | in-repo: `capability_pack.ex` + TTL shapes |
| Durable replay ledger / engine | BUILT (known defects being fixed) | in-repo: `AshPPlan.Reactor.Durable.*` (24 modules) |
| Receipt / standing / OCEL evidence layer | BUILT | in-repo: `execution_receipt.ex`, `standing.ex`, `ledger_ocel.ex` |
| Financial margin / statutory-envelope gating | ABSENT in-core; SHIPPED as marketplace pack | `ggen-marketplace/packs/financial-margin-envelope` |
| Digital-twin fleet (Physical/Actuator/Human twins, hazard Z-scores) | RELOCATED to ash_a2a (2026-11-07 boundary decision) | ash_a2a |
| Sensory mesh / lossy boundary projection / attention broker | RELOCATED to ash_a2a | ash_a2a |
| Wire protocol / CommandBus / addressed resumption ingress | RELOCATED to ash_a2a | ash_a2a |
| Tactical COP console (dual-track delta, CAD dispatcher, envelope visualizer) | SHIPS SEPARATELY (not in ash_pplan) | separate deliverable |
| Airbus transpiler oracle | CI-ONLY (socket boundary) | in-repo test corpus + external oracle; see `docs/PACKAGE-BOUNDARY.md` |

Boundary law: `docs/PACKAGE-BOUNDARY.md`.

## System Classification
Industrial-grade, fail-closed deliberation and durable execution runtime for high-reliability operations (aerospace assembly and turnaround, space launch staging, commercial fleet dispatch, critical infrastructure management, and multi-enterprise orchestration).

---

# Part 1: Product Requirements Document (PRD) — Platform Capability Surface

## 1. Architectural Mission & Core Value Proposition
Modern distributed workflows suffer from a fundamental architectural flaw: the conflation of **deliberation** (planning, scheduling, constraint optimization) and **actuation** (mutating physical or digital state). When workflows cross dozens of uncoordinated external platforms, physical telemetric sensors, statutory regulatory boundaries, and strict financial floors, treating execution as simple CRUD records or unbounded event loops creates catastrophic failures:
- Unhandled non-deterministic stalls and deadlocks.
- Silent financial leakage and statutory compliance breaches discovered only post-incident.
- Loss of operational state during crashes, causing duplicated real-world side effects or abandoned processes.
- Unverifiable audit trails in multi-stakeholder disputes.

This subsystem establishes an industrial-grade, fail-closed control plane that:
1. **Decouples Deliberation from Actuation**: Planners propose and verify trajectories; only an admitted, transactional, durable runtime actuates state changes.
2. **Enforces Invariant Flight Envelopes**: Mathematical, statutory, and contractual safety envelopes are compile-checked and fail-closed prior to dispatch.
3. **Decouples Operational Time**: Replaces brittle global clocks with communicating, asynchronous Digital Twins tracking local empirical drift and survival hazard curves.
4. **Guarantees Bit-for-Bit Replay Invariance**: An append-only, synchronous persistent ledger guarantees zero state loss and crash recovery without duplicate external effects.
5. **Provides Mathematical Proof of Goal Reachability**: Employs Hierarchical Task Networks (HTN) and Fully Observable Non-Deterministic (FOND) synthesis to pre-solve operational exceptions before committing resources.

---

## 2. Supported Personas & Client Classes

### 2.1 Robotic & Autonomous Actuator (Machine Client)
Interacts over high-throughput, low-latency telemetric channels (CAN bus, gRPC, WebSockets, DDS). Requires millisecond-level step admission, local safety envelope verification, deterministic idempotency keys, and explicit time-bounded execution leases.

### 2.2 Tactical Incident Controller / Flight Director (Human-in-the-Loop)
Operates tactical Common Operating Picture (COP) consoles. Requires real-time visibility into the delta between the formal plan (Incident Action Plan / IAP) and live physical telemetry (COP), keyboard-first command dispatch (CAD short syntax), sliding autonomy levels, and single-action gate overrides.

### 2.3 Regulatory Auditor & Airworthiness Inspector (Verification Client)
Inspects historical traces post-mission or during dispute resolution. Requires unforgeable, content-addressed cryptographic receipts linking sensor readings, algorithmic inputs, human approvals, and actuator outputs to exact software and domain specifications.

### 2.4 External Enterprise Spokes (Peripheral Clients)
Third-party SaaS platforms, ERPs, supply chain portals, and telematics aggregators. Treated by the runtime as unverified, lossy, and non-deterministic sensors and actuators.

---

## 3. Core Functional Capabilities & System Primitives

```text
+-------------------------------------------------------------------------------------------------+
|                               INDUSTRIAL PLATFORM PRIMITIVES                                    |
+------------------------------+----------------------------------+-------------------------------+
|  1. COMPOSABLE DOMAIN TRAITS |  2. TWO-PHASE ADMISSION ENVELOPE |  3. TEMPORAL LEASE BROKER     |
|  • HTN Task Decomposition    |  • Pre-execution invariant check |  • Dynamic Controllability    |
|  • Non-Deterministic (FOND)  |  • Deadlock / Reachability proof |  • Decentralized drift clocks |
|  • Partially Observable (PO) |  • Structural shape validation   |  • Monotonic execution leases |
|  • Concurrent Timed (STNU)   |  • Fail-closed refusal gates     |  • Survival hazard modeling   |
+------------------------------+----------------------------------+-------------------------------+
|  4. DURABLE REPLAY LEDGER    |  5. ATTRIBUTED EVIDENCE ENGINE   |  6. SLIDING AUTONOMY GATES    |
|  • Synchronous crash commits |  • Semantic PROV-O graphs        |  • Level 4: Full Autonomic    |
|  • Idempotency key derivation|  • Content-addressed receipts    |  • Level 3: Consent by Silence|
|  • Replay-safe state hydrate |  • Object-centric event logs     |  • Level 2: Directed Override |
|  • Nearest-first unwinding   |  • Cryptographic verification    |  • Level 1: Hard Fail-Closed  |
+------------------------------+----------------------------------+-------------------------------+
```

### 3.1 Composable Domain Trait System
The platform formalizes every industrial domain through composable mathematical traits:
- **Hierarchical Task Structure (`HTN`)**: Recursive decomposition of compound goals into partially ordered primitive actions governed by domain grammar.
- **Non-Deterministic Branching (`FOND`)**: Formal modeling of uncertain physical action outcomes (e.g., fastener torque nominal vs. stripped) where each action yields a set of possible successor states.
- **Partial Observability (`PO`)**: Representation of unobserved physical state, estimating belief states via fused sensor observations rather than assuming ground truth.
- **Concurrent Timed Fluents (`STNU`)**: Simple Temporal Networks with Uncertainty, modeling contingent real-world durations with bounded intervals and continuous numeric resources.

### 3.2 Two-Phase Pre-Flight Admission Envelope
No operational plan is admitted to the execution runtime until it passes two formal gates:
1. **Structural & Conformance Gate**: Validates the candidate graph against declarative structural shapes (licensing constraints, safety clearance zones, equipment operational limits).
2. **Reachability & Deadlock Gate**: Mathematically proves that every reachable non-deterministic state retains a viable path to the absorbing goal state ($\Diamond \text{Goal}$) under fair execution. If any branch deadlocks or lacks certified resources, the engine issues a typed refusal before actuation.

### 3.3 Dynamic Temporal Coordination & Execution Leases
- **Dynamic Controllability (DC-Checking)**: Prior to dispatch, the system verifies that the temporal network remains controllable regardless of when nature resolves contingent durations.
- **Monotonic Execution Leases**: Actions are assigned via time-bounded leases ($\Phi_{\text{lease}}$). If an agent fails to check in or exceeds latency thresholds, the lease expires automatically, preventing zombie execution and enabling automated reallocation.
- **Decoupled Clocks**: Each participant (Asset, Actuator, Operator) runs an independent local state machine and clock. Time divergence between clocks is tracked using empirical hazard models ($Z$-score latency drift).

### 3.4 Durable State, Crash Resistance, & Safe Replay
- **Synchronous Write Barrier**: Every mutating state transition, checkpoint, lease acquisition, and incoming signal commits synchronously to an append-only persistent store prior to triggering real-world effects.
- **Deterministic Idempotency Key Derivation**: Outbound integrations compute deduplication keys:
  $$\text{Key} = \text{Hash}(\text{RunID} \parallel \text{StepID} \parallel \text{AttemptNumber})$$
- **Replay Invariance**: System recovery, counterfactual analysis, or diagnostic replays read outputs directly from historical checkpoints. Replays suppress all external network calls and physical actuation.
- **Nearest-First Unwinding**: Aborted or cancelled plans execute compensation steps in reverse chronological order (newest-first), returning physical and financial systems to a safe resting state.

### 3.5 Sliding Autonomy Envelopes
Every operational step executes under one of four explicit autonomy tiers:
- **Level 4 (Full Autonomic)**: Nominal execution inside certified envelopes (e.g., Tier-1 certified assets, margin $\ge 22\%$, latency $Z < 1.5\sigma$). Executes machine-to-machine with zero human touch.
- **Level 3 (Consent by Silence)**: Action is staged and dispatched automatically unless an operator intervenes within a sliding temporal window (e.g., 3-minute veto countdown).
- **Level 2 (Directed Override / Machine Proposal)**: The deliberation engine synthesizes the top viable recovery plans and halts execution at a durable waiter gate until a human operator commits an addressed selection.
- **Level 1 (Hard Fail-Closed Lockout)**: Statutory, licensing, or safety invariant violations halt execution completely. Resumption requires an elevated, multi-signature digital authorization receipt.

### 3.6 Attributed Evidence & Forensic Provenance
- **Object-Centric Event Logs (OCEL 2.0)**: Captures multi-entity relationships across assets, work orders, personnel, tools, and invoices without flattening data into artificial single-entity logs.
- **W3C PROV-O & P-PLAN Graph**: Preserves the complete causal graph linking raw sensor inputs, planning steps, software versions, and human approvals.
- **Content-Addressed Execution Receipts**: Issues immutable, cryptographically hashed completion receipts binding inputs, recorded checkpoint sequences, and attestation signatures to exact repository release SHAs.

---

# Part 2: Architecture Requirements Document (ARD) — Subsystem & Interface Design

## 1. Fundamental Architectural Invariants

| Principle | Invariant Law | Architectural Enforcement |
|:---|:---|:---|
| **Separation of Concerns** | Deliberation $\cap$ Actuation $=\emptyset$ | Planning engines hold zero DO authority; only the durable engine actuates. |
| **Fail-Closed by Default** | Missing proof $\implies$ REFUSAL | Absence of explicit compliance or margin proof halts dispatch. |
| **Point-to-Point Resumption** | Addressed signaling only | Public PubSub events never wake runs; resumptions require explicit `RunID` + `StepLabel`. |
| **Append-Only Immutability** | State updates are write-only | State is never overwritten in place; historical checkpoints are immutable. |
| **Independent Clocks** | Time is decentralized | Entities maintain local state machines; drift is measured statistically, not by global lock. |

---

## 2. High-Level Subsystem Topology

```text
+-------------------------------------------------------------------------------------------------+
|                                    CLIENT APPLICATION LAYER                                     |
|  - Tactical Common Operating Picture (COP) UI       - Flight Deck Telemetry / CAD Terminals     |
|  - Industrial SCADA / Factory Sensor Ingestion      - External Enterprise Spokes (ERP/PLM)      |
+-------------------------------------------------------------------------------------------------+
                                      |                             ^
             Addressed Resume Signals |                             | SSE / WebSockets 
             & Telemetric Pings       v                             | Milestone Delta Stream
+-------------------------------------------------------------------------------------------------+
|                                INDUSTRIAL CONTROL PLANE CORE                                    |
|                                                                                                 |
|  +-------------------------------------------------------------------------------------------+  |
|  | 1. SEMANTIC COMPILATION & ADMISSION PIPELINE                                              |  |
|  | • HTN Task Decomposition Engine          • Continuous Resource & Fluent Envelope Check    |  |
|  | • Declarative Structural Shape Checker   • Dynamic Controllability (STNU) Validator       |  |
|  | • Reachability & Deadlock Proof Engine   • Fail-Closed Admission Gatekeeper               |  |
|  +-------------------------------------------------------------------------------------------+  |
|                                              |                                                  |
|                                  Admitted Verified Flight Plan                                  |
|                                              v                                                  |
|  +-------------------------------------------------------------------------------------------+  |
|  | 2. DISTRIBUTED DIGITAL TWIN COORDINATION (Actor Mesh)                                    |  |
|  | • Physical Asset Twin (Operating bounds, sensory telemetry, hard contractual deadlines)  |  |
|  | • Actuator / Partner Twin (Local drift timers, hazard distributions, qualification tape)  |  |
|  | • Human Controller Twin (Cognitive budget, queue load, escalation timers)                |  |
|  +-------------------------------------------------------------------------------------------+  |
|                                              |                                                  |
|                                Synchronized Execution Lease                                     |
|                                              v                                                  |
|  +-------------------------------------------------------------------------------------------+  |
|  | 3. DURABLE REPLAY & EXECUTION ENGINE                                                      |  |
|  | • Saga & DAG Execution Coordinator       • Deterministic Idempotency Key Derivation       |  |
|  | • Synchronous Persistent State Store     • Long-Horizon Parking (Steps.Await, Steps.Poll)  |  |
|  | • Nearest-First Rollback & Compensation  • Replay Invariance Engine (Pure Cache Hydrate) |  |
|  +-------------------------------------------------------------------------------------------+  |
|                                              |                                                  |
|                                         Checkpoint                                              |
|                                              v                                                  |
|  +-------------------------------------------------------------------------------------------+  |
|  | 4. FORENSIC EVIDENCE & PROVENANCE RECORDER                                                |  |
|  | • W3C PROV-O & P-PLAN Causal Graph       • Content-Addressed Execution Receipts           |  |
|  | • Object-Centric Event Logs (OCEL 2.0)   • SHA-256 Release Head Binding                   |  |
|  +-------------------------------------------------------------------------------------------+  |
+-------------------------------------------------------------------------------------------------+
                                              |
                                 Scoped Action Boundary Only
                                              v
+-------------------------------------------------------------------------------------------------+
|                             TRANSACTIONAL & PERIPHERAL BOUNDARY                                 |
|  - Peripheral SaaS Connectors (32 Spoke Mesh)       - Hardware PLC / SCADA Bus / DDS            |
|  - Cryptographic Identity & Hardware HSMs           - Background Job Schedulers                 |
+-------------------------------------------------------------------------------------------------+
```

---

## 3. Subsystem Detailed Specifications

### 3.1 Subsystem 1: Semantic Compilation & Formal Deliberation Core
- **Responsibility**: Ingests operational goals, validates domain grammar, tests safety constraints, synthesizes contingency policies, and emits admitted execution graphs.
- **Decomposition**:
  - `HTN Parser & Matcher`: Resolves compound operational tasks into candidate primitive action graphs based on contextual parameters (equipment type, site access rules, trade class).
  - `Structural Shape Validator`: Evaluates candidate topologies against declarative closed-world shapes. Non-conforming assignments (e.g., missing trade license, uncertified crane hoist) fail compilation immediately.
  - `FOND Synthesizer`: Solves the reachable non-deterministic state space $\pi : S \to A$. Ensures all non-deterministic branches terminate in an absorbing goal state ($\Diamond \text{Goal}$).
  - `Temporal STNU Validator`: Constructs a distance graph of all contingent and controllable links; computes Fast Dynamic Controllability (FDC). Refuses plans with temporal deadlocks.
  - `Deliberation IPC Bridge`: Connects to external high-dimensional mathematical solvers (such as PDDL4J, Lilotane, or PRP) via local domain sockets; enforces an adversarial re-verification court before admitting returned policies.

### 3.2 Subsystem 2: Distributed Digital Twin Coordination (Actor Mesh)
- **Responsibility**: Houses stateful, concurrent representations of real-world participants to eliminate single-clock failure modes.
- **Components**:
  - `Physical Asset Twin`: Tracks operational metrics, physical environmental sensor feeds, access windows, and absolute contractual deadlines.
  - `Actuator / Partner Twin`: Tracks availability, current geofence coordinates, credential expiration dates, and empirical latency distributions ($\tilde{\mu}, \text{MAD}$). Calculates real-time hazard Z-scores:
    $$Z = \frac{t_{\text{elapsed}} - \tilde{\mu}}{\text{MAD}}$$
  - `Human Controller Twin`: Tracks operator cognitive load, active queue depth, and response velocities. Dynamically load-balances exception trays across controllers.
  - `Rendezvous & Lease Broker`: Negotiates time-bounded execution leases between twins. If an actuator twin's drift clock breaches $2.5\sigma$, the broker revokes the lease and triggers an autonomic detour.

### 3.3 Subsystem 3: Durable Replay & Execution Engine
- **Responsibility**: Manages the reliable actuation of admitted plans with zero state loss and guaranteed idempotency.
- **Components**:
  - `Execution Coordinator`: Navigates the admitted DAG or saga, unblocking downstream nodes as predecessor checkpoints commit.
  - `Synchronous Persistent Store`: Writes run state, step checkpoints, leases, and waiter records to disk synchronously before external effects fire.
  - `Idempotency Derivation Engine`: Generates collision-free, deterministic deduplication tokens passed to all external effect handlers.
  - `Long-Horizon Parking Engine`: Parks workflows awaiting asynchronous signals without holding thread pools or memory locks (`Steps.Await`, `Steps.Poll`).
  - `Nearest-First Rollback Engine`: Traverses completed step checkpoints in reverse chronological order to actuate compensating actions when an unrecoverable failure occurs.

### 3.4 Subsystem 4: Sensory Mesh & Lossy Boundary Projection
- **Responsibility**: Bridges the control plane to unreliable external software portals and physical telemetry networks.
- **Components**:
  - `Virtual Sensor Adapter`: Normalizes diverse webhook payloads and telemetry feeds into standardized semantic observations.
  - `Probabilistic Observation Fusion`: Merges noisy status updates with physical GPS, hardware telemetry, and sensor feeds to compute belief states ($b$).
  - `Attestation Gatekeeper`: Validates cryptographic sensor signatures, geofence polygon entries, and digital multi-signature approvals before advancing dependent steps.

### 3.5 Subsystem 5: Forensic Proof & Audit Recorder
- **Responsibility**: Generates immutable, legally defensible, content-addressed records of all operational lifecycles.
- **Components**:
  - `PROV-O Graph Builder`: Constructs causal relationships between activities, entities, and agents (`wasAssociatedWith`, `used`, `wasGeneratedBy`).
  - `OCEL 2.0 Streamer`: Exports lifecycle events with object-to-object bindings for process mining and conformance checking.
  - `Receipt Authority`: Issues cryptographic receipts binding input parameters, checkpoint tapes, software commit SHAs, and sensor attestations into an immutable SHA-256 digest.

### 3.6 Subsystem 6: Tactical Common Operating Picture & Interaction Bus
- **Responsibility**: Delivers real-time operational status to tactical controllers and routes addressed operator signals back to the durable engine.
- **Components**:
  - `Dual-Track Plan Delta Streamer`: Pushes millisecond-level comparisons between the planned baseline (IAP) and live physical telemetry (COP).
  - `CAD Command Dispatcher`: Parses keyboard-first commands (short syntax / 10-codes) and routes them as addressed engine resumptions.
  - `Dynamic Invariant Envelope Visualizer`: Computes real-time client-side margin and compliance curves as parameter sliders move, locking out unadmitted actions before submission.

---

## 4. Primitive Interface Contracts & Protocols

### 4.1 Plan Execution Lease Envelope
```json
{
  "$schema": "https://w3id.org/industrial-pplan/lease.schema.json",
  "lease_id": "lease_01JBCDEF89XYZ",
  "run_id": "run_aog_turnaround_8921",
  "step_id": "step_inspect_fan_blade_c4",
  "grantee_id": "agent_technician_4402",
  "authority_ceiling": "CONSTRUCT",
  "valid_from": "2026-11-07T14:00:00.000Z",
  "valid_until": "2026-11-07T14:45:00.000Z",
  "monotonic_epoch": 10482,
  "hazard_bounds": {
    "median_latency_seconds": 1800,
    "mad_seconds": 240,
    "max_admissible_z": 2.5
  },
  "constraints": {
    "max_cost_amount": 1200.00,
    "cost_currency": "USD",
    "required_qualifications": ["EASA-PART-66-B1", "NDT-LEVEL-2"]
  },
  "sha256_spec_digest": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
```

### 4.2 Typed Resumption Signal Protocol
```json
{
  "$schema": "https://w3id.org/industrial-pplan/signal.schema.json",
  "signal_id": "sig_01JBCDEF99ABC",
  "run_id": "run_aog_turnaround_8921",
  "target_waiter_label": "gate_manager_override",
  "idempotency_key": "c2b64a78-2d85-4841-a162-81765c7f8a91",
  "issuer": {
    "agent_id": "usr_controller_102",
    "role": "TacticalFlightDirector",
    "digital_signature": "MEQCIA..."
  },
  "payload": {
    "action": "authorize_contingency_detour",
    "selected_branch": "branch_secondary_subcontractor",
    "approved_nte_ceiling": 1450.00,
    "justification_code": "PRIMARY_VENDOR_DRIFT_EXCEEDED"
  },
  "client_timestamp": "2026-11-07T14:22:15.102Z"
}
```

### 4.3 Structured Admission Refusal Payload
```json
{
  "$schema": "https://w3id.org/industrial-pplan/refusal.schema.json",
  "status": "REFUSED",
  "refusal_type": "STATUTORY_SHAPE_VIOLATION",
  "broken_term": "admission_vacuous",
  "falsifying_invariant": "MunicipalCode_CSLB_Section7048",
  "context": {
    "site_jurisdiction": "US-CA-SanJose",
    "proposed_cost": 1250.00,
    "statutory_unlicensed_ceiling": 500.00,
    "assigned_vendor": "vendor_handyman_express",
    "verified_licenses": []
  },
  "remediation": {
    "action_required": "RESTRICT_ROUTING_TO_LICENSED_TRADES",
    "required_license_type": "CA-C10-Electrical",
    "fond_detour_available": true,
    "contingency_plan_id": "plan_detour_licensed_c10"
  }
}
```

---

## 5. Non-Functional Invariants & Operational Guarantees

| Metric / Invariant | Requirement Specification | Verification Method |
|:---|:---|:---|
| **Crash Durability** | Synchronous atomic disk commit before external side effect. Zero lost state on arbitrary SIGKILL. | Continuous fault injection: store killed mid-step; restart validates zero uncheckpointed progress. |
| **Idempotency Guarantee** | Exactly-once external side effects under at-least-once network delivery. | Network partition tests injecting duplicate resumptions; verifies single outbound effect. |
| **Admission Determinism** | 100% of admitted non-deterministic plans terminate in $\Diamond \text{Goal}$. Deadlocks refused pre-flight. | Exhaustive model checking via TLA+ reader and TLC across all candidate operational domains. |
| **Temporal Independence** | Zero CPU threads, memory locks, or socket connections consumed by parked workflows. | Scale benchmark: 100,000 workflows parked on disk; verifies flat idle memory and zero CPU utilization. |
| **Signal Latency** | Addressed resume signal commits to disk and unblocks execution in $<10\text{ms}$ on local node. | Automated latency regression harness measuring end-to-end signal-to-checkpoint duration. |
| **Cryptographic Replay** | Bit-for-bit identical state reconstruction from historical tape; zero re-execution of effects. | Replay differential court comparing historical checkpoint state against isolated replay execution. |

---

## 6. Failure Taxonomy & Self-Healing Matrix

```text
+---------------------------------------------------------------------------------------------------+
|                                     MAPE-K FAILURE & HEALING MATRIX                               |
+----------------------+--------------------+--------------------------------+----------------------+
| Failure Class        | Detection (M & A)  | Deliberation / Plan (P)        | Actuation (E)        |
+----------------------+--------------------+--------------------------------+----------------------+
| Actor Flake / Stalling| SubcontractorTwin  | FOND synthesizer prunes failed | Lease revoked;       |
|                      | Z-score >= 2.5σ    | branch; selects verified Tier-2| secondary provider   |
|                      |                    | contingency route.             | dispatched.          |
+----------------------+--------------------+--------------------------------+----------------------+
| Statutory Breach     | Intake SHACL shape | Refuses candidate topology;    | Pre-dispatch refusal |
|                      | conformance failure| splices mandatory municipal    | issued; workflow     |
|                      |                    | permitting sub-plan.           | halted on permit gate|
+----------------------+--------------------+--------------------------------+----------------------+
| Financial Margin     | Invariant governor | Identifies margin collapse;    | Disbursement valve   |
| Collapse             | computes < 22%     | computes minimum viable client | locked; promoted to  |
|                      | gross margin floor | NTE adjustment.                | executive sign-off.  |
+----------------------+--------------------+--------------------------------+----------------------+
| Process Node Crash   | Heartbeat monitor  | Replay engine reads tape; skips| Resumes uncommitted  |
|                      | detects abnormal   | committed steps; re-establishes| step using original  |
|                      | process exit       | execution lease.               | idempotency key.     |
+----------------------+--------------------+--------------------------------+----------------------+
| Unrecoverable Goal   | FOND winning region| Synthesizes nearest-first safe | Actuates compensating|
| Deadlock             | becomes empty      | unwinding trajectory           | rollbacks in reverse |
|                      | (S_0 not in Solv)  | ($\text{Compensate}(S_i)$).    | chronological order. |
+----------------------+--------------------+--------------------------------+----------------------+
```

---

## 7. Implementation Roadmap & Phased Delivery

### Phase 1: Formal Compilation & Fail-Closed Admission Core
- Declarative HTN task decomposition parser.
- SHACL structural shape validation engine for statutory, physical, and trade bounds.
- Reachability and deadlock verifier for non-deterministic outcome spaces.
- Fail-closed admission gateway emitting structured refusal payloads.

### Phase 2: Durable Replay Ledger & Digital Twin Mesh
- Synchronous append-only persistent store with lease claims and waiter registrations.
- Deterministic idempotency key derivation for all external integrations.
- Concurrent Digital Twin actors (Asset, Actuator, Operator) with statistical hazard timers ($Z$-score curves).
- Nearest-first compensation unwinder for aborted workflows.

### Phase 3: Tactical Common Operating Picture & Hybrid Console
- Real-time dual-track plan delta engine (IAP baseline vs. COP physical reality).
- Interactive causal DAG visualization canvas with custom status nodes.
- High-velocity keyboard-first CAD command prompt for single-action triage.
- Constraint-bounded parameter sliders with real-time dynamic margin envelopes.

### Phase 4: Attributed Provenance & Forensic Replay Court
- Object-Centric Event Log (OCEL 2.0) streaming pipeline.
- W3C PROV-O semantic execution graph builder.
- Content-addressed execution receipt issuer bound to repository release SHAs.
- Forensic time-travel scrubber supporting frame-by-frame state inspection.
