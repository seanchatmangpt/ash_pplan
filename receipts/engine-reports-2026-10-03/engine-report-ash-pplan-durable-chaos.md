<!-- Promoted from /Users/sac/ash_pplan/tmp/engine-report-ash-pplan-durable-chaos.md on 2026-10-03; ggen engine-comparison output over ash-pplan packs. -->
## Query: invariants

# Engine Comparison Report

**Query:**

```sparql
PREFIX dc: <https://w3id.org/ash-pplan/durable-chaos#>
SELECT DISTINCT ?invariantId ?title ?seed ?order ?target_pack WHERE {
  ?i a dc:Invariant ; dc:invariantId ?invariantId ; dc:title ?title ; dc:seed ?seed ; dc:order ?order .
  BIND("ash-pplan-durable-chaos-pack" AS ?target_pack)
}
ORDER BY ?order

```

**Generated at:** 2026-10-03T09:15:39.042510Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 6 | 147.28 | - |
| graphlaw | ok | 6 | 865.06 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: kill_phases

# Engine Comparison Report

**Query:**

```sparql
PREFIX dc: <https://w3id.org/ash-pplan/durable-chaos#>
SELECT DISTINCT ?phaseId ?nth ?seed WHERE {
  ?p a dc:KillPhase ; dc:phaseId ?phaseId ; dc:nth ?nth ; dc:seed ?seed .
}
ORDER BY ?phaseId

```

**Generated at:** 2026-10-03T09:15:39.723222Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 4 | 0.76 | - |
| graphlaw | ok | 4 | 680.27 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |

