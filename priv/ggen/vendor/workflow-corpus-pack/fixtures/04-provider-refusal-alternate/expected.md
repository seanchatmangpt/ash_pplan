# Fixture 04 - provider refusal with lawful alternate

Semantic subject: a capability whose PRIMARY realization refuses typed while
an alternate QUALIFIED realization is admitted inside the provider closure.
The workflow must route to the alternate and complete. The trap: an engine
that treats the first provider's typed refusal as workflow-terminal.

## Goal

Deliver a payload over HTTP; when the primary realization refuses typed, the
admitted alternate route (resolve fallback endpoint, then post) must complete
the delivery. Stopping at the first-provider refusal while an alternate is
admitted is forbidden.

## Tasks

| # | task | capability (pinned literals) | informs | expected outcomes |
|---|------|-------------------------------|---------|-------------------|
| 1 | `f04-post-via-primary` | `Http.Post` | 2 | `primary-typed-refusal` |
| 2 | `f04-post-via-alternate` | `Endpoint.Resolve`, `Http.Post` | - | `delivered-via-alternate` OR `both-refused` |

Task 2 is informed by task 1: the alternate runs AFTER the primary's typed
refusal (running the fallback first is also a violation).

## Expected decomposition

`primary-then-typed-refusal-then-alternate`. The shared capability literal
`Http.Post` covers BOTH tasks: the closure admits two realizations of the same
semantic capability, which is exactly what makes the alternate lawful.

## Branch table

| branch | primary | alternate | terminal state |
|--------|---------|-----------|----------------|
| primary refuses, alternate delivers | typed refusal receipt | post receipt (resolved endpoint + digest) | success via alternate |
| both refuse | typed refusal receipt | typed refusal receipt | `both-refused` (lawful ONLY after the attempt) |
| engine stops at primary refusal | typed refusal receipt | NONE -- VIOLATION | engine fails this fixture |

## Required evidence

Primary typed refusal record (endpoint + class); alternate post receipt
(resolved endpoint + delivered digest); both-refused carries BOTH records. A
delivery report citing no endpoint (or the refusing primary endpoint) is not a
goal state.

## Required authority

Named network grant scoped to the destination class, covering primary and
resolved alternate endpoints. Re-granting per attempt is not required;
widening beyond the destination class is forbidden.

## Expected provider closure

| realization | role | citation class |
|-------------|------|----------------|
| `Reactor.Req.Post` | primary binding | hex `reactor_req` -- provider metadata only, no local inspection |
| `Endpoint.Resolve` | alternate-endpoint admission (ncap family resolver) | capability-family resolver |
| `Reactor.Req.Post@alternate-endpoint` | alternate binding of the SAME realization | hex `reactor_req`, resolved alternate endpoint |

## Forbidden realization

`halt-workflow-on-first-provider-refusal` -- reporting workflow failure or
blocking at the primary's typed refusal while an alternate is admitted.

## Falsifier (kills a mishandling engine)

The episode's terminal state is the primary refusal alone (no alternate
attempt receipt) although the alternate was admitted; or the alternate
executed without a primary refusal record preceding it (fallback as a first
move).

## Gate

`gates/f04_alternate_realization_completes.rq` -- fires if fixture 04 declares
a forbidden realization yet no capability is covered by two distinct tasks
with the alternate informed by the primary. Negative witness:
`witnesses/fail/f04_alternate_realization_completes.ttl`.
