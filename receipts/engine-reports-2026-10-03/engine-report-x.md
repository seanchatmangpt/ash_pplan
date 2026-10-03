<!-- Promoted from /Users/sac/ash_pplan/tmp/engine-report-x.md on 2026-10-03; ggen engine-comparison output over ash-pplan packs. -->
## Query: capabilities

# Engine Comparison Report

**Query:**

```sparql
PREFIX ap: <https://w3id.org/ash-pplan#>
SELECT DISTINCT ?id ?family ?target_pack WHERE {
  ?c a ap:Capability ; ap:capabilityId ?id ; ap:family ?family .
  BIND("ash-pplan-workflow-pack" AS ?target_pack)
}
ORDER BY ?id

```

**Generated at:** 2026-10-03T08:36:20.313922Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 31 | 271.27 | - |
| graphlaw | ok | 31 | 774.9 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: providers

# Engine Comparison Report

**Query:**

```sparql
PREFIX ap: <https://w3id.org/ash-pplan#>
SELECT DISTINCT ?provider_id ?module ?cost WHERE {
  ?p a ap:Provider ; ap:providerId ?provider_id ; ap:providerModule ?module ; ap:cost ?cost .
}
ORDER BY ?cost ?provider_id

```

**Generated at:** 2026-10-03T08:36:21.036862Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 11 | 5.47 | - |
| graphlaw | ok | 11 | 722.17 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: provider_caps

# Engine Comparison Report

**Query:**

```sparql
PREFIX ap: <https://w3id.org/ash-pplan#>
SELECT DISTINCT ?provider_id ?capability ?adapter ?operation ?step_options WHERE {
  ?p a ap:Provider ; ap:providerId ?provider_id ; ap:realization ?r .
  ?r a ap:Realization ; ap:realizes ?c ; ap:adapter ?adapter ; ap:operation ?operation ; ap:stepOptions ?step_options .
  ?c ap:capabilityId ?capability .
}
ORDER BY ?provider_id ?capability

```

**Generated at:** 2026-10-03T08:36:21.778028Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 31 | 6.43 | - |
| graphlaw | ok | 31 | 740.26 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: provider_props

# Engine Comparison Report

**Query:**

```sparql
PREFIX ap: <https://w3id.org/ash-pplan#>
SELECT DISTINCT ?provider_id ?property WHERE {
  ?p a ap:Provider ; ap:providerId ?provider_id ; ap:supportsProperty ?property .
}
ORDER BY ?provider_id ?property

```

**Generated at:** 2026-10-03T08:36:22.486185Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 14 | 5.25 | - |
| graphlaw | ok | 14 | 707.41 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: provider_evidence

# Engine Comparison Report

**Query:**

```sparql
PREFIX ap: <https://w3id.org/ash-pplan#>
SELECT DISTINCT ?provider_id ?evidence WHERE {
  ?p a ap:Provider ; ap:providerId ?provider_id ; ap:emitsEvidence ?evidence .
}
ORDER BY ?provider_id ?evidence

```

**Generated at:** 2026-10-03T08:36:23.249279Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 11 | 4.54 | - |
| graphlaw | ok | 11 | 762.2 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: workflows

# Engine Comparison Report

**Query:**

```sparql
PREFIX ap: <https://w3id.org/ash-pplan#>
SELECT DISTINCT ?name ?goal WHERE {
  ?w a ap:Workflow ; ap:workflowName ?name ; ap:goal ?goal .
}
ORDER BY ?name

```

**Generated at:** 2026-10-03T08:36:23.881504Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 0 | 4.75 | - |
| graphlaw | ok | 0 | 631.28 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: tasks

# Engine Comparison Report

**Query:**

```sparql
PREFIX ap: <https://w3id.org/ash-pplan#>
SELECT DISTINCT ?workflow ?task ?capability ?authority ?order WHERE {
  ?w a ap:Workflow ; ap:workflowName ?workflow ; ap:hasTask ?t .
  ?t ap:taskId ?task ; ap:requiresCapability ?c ; ap:authorityCeiling ?authority ; ap:order ?order .
  ?c ap:capabilityId ?capability .
}
ORDER BY ?workflow ?order ?task

```

**Generated at:** 2026-10-03T08:36:24.495073Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 0 | 4.76 | - |
| graphlaw | ok | 0 | 612.77 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: task_deps

# Engine Comparison Report

**Query:**

```sparql
PREFIX ap: <https://w3id.org/ash-pplan#>
SELECT DISTINCT ?workflow ?task ?dep WHERE {
  ?w a ap:Workflow ; ap:workflowName ?workflow ; ap:hasTask ?t .
  ?t ap:taskId ?task ; ap:dependsOn ?d .
  ?d ap:taskId ?dep .
}
ORDER BY ?workflow ?task ?dep

```

**Generated at:** 2026-10-03T08:36:25.117996Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 0 | 4.82 | - |
| graphlaw | ok | 0 | 622.18 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: task_outcomes

# Engine Comparison Report

**Query:**

```sparql
PREFIX ap: <https://w3id.org/ash-pplan#>
SELECT DISTINCT ?workflow ?task ?outcome WHERE {
  ?w a ap:Workflow ; ap:workflowName ?workflow ; ap:hasTask ?t .
  ?t ap:taskId ?task ; ap:outcome ?outcome .
}
ORDER BY ?workflow ?task ?outcome

```

**Generated at:** 2026-10-03T08:36:25.791609Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 0 | 5.13 | - |
| graphlaw | ok | 0 | 672.96 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: task_props

# Engine Comparison Report

**Query:**

```sparql
PREFIX ap: <https://w3id.org/ash-pplan#>
SELECT DISTINCT ?workflow ?task ?property WHERE {
  ?w a ap:Workflow ; ap:workflowName ?workflow ; ap:hasTask ?t .
  ?t ap:taskId ?task ; ap:requiresProperty ?property .
}
ORDER BY ?workflow ?task ?property

```

**Generated at:** 2026-10-03T08:36:26.403886Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 0 | 5.43 | - |
| graphlaw | ok | 0 | 611.55 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: methods

# Engine Comparison Report

**Query:**

```sparql
PREFIX ap: <https://w3id.org/ash-pplan#>
SELECT DISTINCT ?workflow ?method ?decomposes ?subtask ?pos WHERE {
  ?w a ap:Workflow ; ap:workflowName ?workflow ; ap:hasMethod ?m ; ap:hasTask ?st .
  ?m a ap:Method ; ap:methodId ?method ; ap:decomposes ?d ; ap:subtask ?st .
  ?d ap:taskId ?decomposes .
  ?st ap:taskId ?subtask ; ap:order ?pos .
}
ORDER BY ?workflow ?method ?pos

```

**Generated at:** 2026-10-03T08:36:27.111776Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 0 | 5.42 | - |
| graphlaw | ok | 0 | 707.09 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |

