# Fixture 01 - filesystem + network workflow with failure isolation

Semantic subject: a two-step manufacture (persist, then upload) where the
downstream step can fail in a TYPED way without contaminating the upstream
step's already-received outcome.

## Goal

Persist a rendered artifact to the local filesystem, then upload it to a
webhook endpoint; a typed network failure on the upload must leave the
persisted artifact and the file step's outcome exactly as they were before the
attempt.

## Tasks (ordered; ordering also carried by prov:wasInformedBy)

| # | task | capability (pinned literal) | expected outcomes |
|---|------|------------------------------|-------------------|
| 1 | `f01-write-artifact` | `File.Write` | `artifact-persisted` |
| 2 | `f01-post-artifact` (wasInformedBy 1) | `Http.Post` | `artifact-posted` OR `post-typed-network-refusal` |

## Expected decomposition

`write-then-post`: (1) write, (2) post. The post step depends on the write
step; the write step's outcome never depends on the post step.

## Branch table

| branch | write task outcome | post task outcome | workflow report |
|--------|--------------------|-------------------|-----------------|
| post OK | `artifact-persisted` (unchanged) | `artifact-posted` | success, both receipts bound |
| post typed network refusal | `artifact-persisted` (UNCHANGED) | `post-typed-network-refusal` | partial report with typed refusal; write receipt byte-identical |

## Required evidence

Write receipt (path + digest); post receipt (endpoint + uploaded digest) or
typed network refusal record. No outcome without its receipt.

## Required authority

Workspace-scoped filesystem write grant; named network grant scoped to the
webhook endpoint. The typed refusal must not be used to widen either grant.

## Expected provider closure

| realization | capability | citation class |
|-------------|------------|----------------|
| `Reactor.File.WriteFile` | File.Write | hex `reactor_file` -- provider metadata only, no local inspection |
| `Reactor.Req.Post` | Http.Post | hex `reactor_req` -- provider metadata only, no local inspection |

## Forbidden realization

`retry-file-write-after-network-failure` -- compensating a network failure by
re-running the file step.

## Falsifier (kills a mishandling engine)

An engine that, on the typed network failure: marks the write step failed or
unknown, retracts the write receipt, re-executes the write, or reports the
whole workflow ALIVE without the typed refusal record. Killing observation:
the write receipt is byte-identical before and after the network failure while
the post step reports a typed refusal.

## Gate

`gates/f01_file_network_failure_isolation.rq` -- fires if the `File.Write`
task and the `Http.Post` task share an expected-outcome individual (a shared
outcome node is exactly the corruption channel this fixture exists to
prohibit). Negative witness:
`witnesses/fail/f01_file_network_failure_isolation.ttl`.
