<!-- Promoted from /Users/sac/ash_pplan/tmp/engine-report-ash-pplan-workflow.md on 2026-10-03; ggen engine-comparison output over ash-pplan packs. -->
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

**Generated at:** 2026-10-03T09:11:14.908689Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 31 | 185.72 | - |
| graphlaw | ok | 31 | 654.95 | - |

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

**Generated at:** 2026-10-03T09:11:15.581285Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 11 | 4.98 | - |
| graphlaw | ok | 11 | 671.81 | - |

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

**Generated at:** 2026-10-03T09:11:16.144569Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 31 | 5.95 | - |
| graphlaw | ok | 31 | 562.47 | - |

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

**Generated at:** 2026-10-03T09:11:16.780138Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 14 | 5.01 | - |
| graphlaw | ok | 14 | 634.77 | - |

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

**Generated at:** 2026-10-03T09:11:17.404139Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 11 | 5.51 | - |
| graphlaw | ok | 11 | 623.18 | - |

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

**Generated at:** 2026-10-03T09:11:17.993162Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 0 | 5.52 | - |
| graphlaw | ok | 0 | 588.14 | - |

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

**Generated at:** 2026-10-03T09:11:18.626326Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 0 | 4.68 | - |
| graphlaw | ok | 0 | 632.4 | - |

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

**Generated at:** 2026-10-03T09:11:19.255139Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 0 | 5.85 | - |
| graphlaw | ok | 0 | 628.04 | - |

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

**Generated at:** 2026-10-03T09:11:19.878289Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 0 | 5.34 | - |
| graphlaw | ok | 0 | 622.35 | - |

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

**Generated at:** 2026-10-03T09:11:20.504845Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 0 | 4.82 | - |
| graphlaw | ok | 0 | 625.86 | - |

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

**Generated at:** 2026-10-03T09:11:21.255477Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 0 | 6.43 | - |
| graphlaw | ok | 0 | 749.91 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |

