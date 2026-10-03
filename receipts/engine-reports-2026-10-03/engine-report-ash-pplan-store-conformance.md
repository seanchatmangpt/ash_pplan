<!-- Promoted from /Users/sac/ash_pplan/tmp/engine-report-ash-pplan-store-conformance.md on 2026-10-03; ggen engine-comparison output over ash-pplan packs. -->
## Query: callbacks

# Engine Comparison Report

**Query:**

```sparql
PREFIX sc: <https://w3id.org/ash-pplan/store-conformance#>
SELECT DISTINCT ?name ?arity ?target_pack WHERE {
  ?c a sc:Callback ; sc:callbackName ?name ; sc:arity ?arity .
  BIND("ash-pplan-store-conformance-pack" AS ?target_pack)
}
ORDER BY ?name

```

**Generated at:** 2026-10-03T09:12:37.973179Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 20 | 351.65 | - |
| graphlaw | ok | 20 | 1324.5 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: laws

# Engine Comparison Report

**Query:**

```sparql
PREFIX sc: <https://w3id.org/ash-pplan/store-conformance#>
SELECT DISTINCT ?id ?order ?statement ?body WHERE {
  ?l a sc:Law ; sc:lawId ?id ; sc:order ?order ; sc:statement ?statement ; sc:body ?body .
}
ORDER BY ?order ?id

```

**Generated at:** 2026-10-03T09:12:39.404939Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 14 | 2.55 | - |
| graphlaw | ok | 14 | 1431.13 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: covers

# Engine Comparison Report

**Query:**

```sparql
PREFIX sc: <https://w3id.org/ash-pplan/store-conformance#>
SELECT DISTINCT ?id ?callback WHERE {
  ?l a sc:Law ; sc:lawId ?id ; sc:covers ?c .
  ?c sc:callbackName ?callback .
}
ORDER BY ?id ?callback

```

**Generated at:** 2026-10-03T09:12:40.440378Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 36 | 1.8 | - |
| graphlaw | ok | 36 | 1034.92 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |

