<!-- Promoted from /Users/sac/ash_pplan/tmp/engine-report-ash-pplan-durable-tla.md on 2026-10-03; ggen engine-comparison output over ash-pplan packs. -->
## Query: statuses

# Engine Comparison Report

**Query:**

```sparql
PREFIX dp: <https://w3id.org/ash-pplan/durable#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT DISTINCT ?status ?terminal ?target_pack WHERE {
  ?s a dp:State ; rdfs:label ?status ; dp:terminal ?terminal .
  BIND("ash-pplan-durable-tla-pack" AS ?target_pack)
}
ORDER BY ?status

```

**Generated at:** 2026-10-03T09:13:32.598921Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 9 | 247.26 | - |
| graphlaw | ok | 9 | 864.33 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: transitions

# Engine Comparison Report

**Query:**

```sparql
PREFIX dp: <https://w3id.org/ash-pplan/durable#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT DISTINCT ?from ?to WHERE {
  ?t a dp:Transition ; dp:from ?f ; dp:to ?g .
  ?f rdfs:label ?from . ?g rdfs:label ?to .
}
ORDER BY ?from ?to

```

**Generated at:** 2026-10-03T09:13:33.311986Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 30 | 3.77 | - |
| graphlaw | ok | 30 | 712.51 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: actions

# Engine Comparison Report

**Query:**

```sparql
PREFIX dp: <https://w3id.org/ash-pplan/durable#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT DISTINCT ?order ?action ?param ?effect WHERE {
  ?a a dp:Action ; rdfs:label ?action ; dp:param ?param ; dp:order ?order ; dp:effect ?effect .
}
ORDER BY ?order

```

**Generated at:** 2026-10-03T09:13:33.994661Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 9 | 3.48 | - |
| graphlaw | ok | 9 | 682.18 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: guards

# Engine Comparison Report

**Query:**

```sparql
PREFIX dp: <https://w3id.org/ash-pplan/durable#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT DISTINCT ?action ?gorder ?gid ?expr WHERE {
  ?g a dp:Guard ; dp:ofAction ?a ; dp:guardId ?gid ; dp:guardOrder ?gorder ; dp:expr ?expr .
  ?a rdfs:label ?action .
}
ORDER BY ?action ?gorder

```

**Generated at:** 2026-10-03T09:13:34.713997Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 23 | 3.46 | - |
| graphlaw | ok | 23 | 718.83 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: properties

# Engine Comparison Report

**Query:**

```sparql
PREFIX dp: <https://w3id.org/ash-pplan/durable#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT DISTINCT ?order ?name ?kind ?expr WHERE {
  ?p a dp:Property ; rdfs:label ?name ; dp:kind ?kind ; dp:order ?order ; dp:expr ?expr .
}
ORDER BY ?order

```

**Generated at:** 2026-10-03T09:13:35.415220Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 6 | 3.32 | - |
| graphlaw | ok | 6 | 700.69 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |

