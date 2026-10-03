<!-- Promoted from /Users/sac/ash_pplan/tmp/engine-report-ash-pplan-standing.md on 2026-10-03; ggen engine-comparison output over ash-pplan packs. -->
## Query: fields

# Engine Comparison Report

**Query:**

```sparql
PREFIX sg: <https://w3id.org/ash-pplan/standing#>
SELECT ?name ?order ?missing_term ?key ?target_pack WHERE {
  ?f a sg:ReceiptField ; sg:fieldName ?name ; sg:fieldOrder ?order ;
     sg:missingTerm ?missing_term ; sg:requiredKey ?key .
  BIND("ash-pplan-standing-pack" AS ?target_pack)
}
ORDER BY ?order ?key

```

**Generated at:** 2026-10-03T09:11:46.041740Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 12 | 286.3 | - |
| graphlaw | ok | 12 | 750.24 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: layers

# Engine Comparison Report

**Query:**

```sparql
PREFIX sg: <https://w3id.org/ash-pplan/standing#>
SELECT ?name ?order ?broken_term WHERE {
  ?l a sg:Layer ; sg:layerName ?name ; sg:layerOrder ?order ; sg:brokenTerm ?broken_term .
}
ORDER BY ?order

```

**Generated at:** 2026-10-03T09:11:46.713434Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 3 | 1.87 | - |
| graphlaw | ok | 3 | 671.25 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: standings

# Engine Comparison Report

**Query:**

```sparql
PREFIX sg: <https://w3id.org/ash-pplan/standing#>
SELECT ?name ?neutral WHERE {
  ?s a sg:Standing ; sg:standingName ?name .
  OPTIONAL { ?s sg:neutralStanding ?neutral }
}
ORDER BY ?name

```

**Generated at:** 2026-10-03T09:11:47.354067Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 7 | 1.69 | - |
| graphlaw | ok | 7 | 640.26 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: ceilings

# Engine Comparison Report

**Query:**

```sparql
PREFIX sg: <https://w3id.org/ash-pplan/standing#>
SELECT ?name ?grants_do WHERE {
  ?c a sg:Ceiling ; sg:ceilingName ?name ; sg:grantsDo ?grants_do .
}
ORDER BY ?name

```

**Generated at:** 2026-10-03T09:11:48.039454Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 4 | 1.79 | - |
| graphlaw | ok | 4 | 685.01 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: chain

# Engine Comparison Report

**Query:**

```sparql
PREFIX sg: <https://w3id.org/ash-pplan/standing#>
SELECT ?algorithm ?genesis WHERE {
  ?p a sg:ChainPolicy ; sg:algorithmName ?algorithm ; sg:genesisHash ?genesis .
}
LIMIT 1

```

**Generated at:** 2026-10-03T09:11:48.702374Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 1 | 1.63 | - |
| graphlaw | ok | 1 | 662.52 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: canon

# Engine Comparison Report

**Query:**

```sparql
PREFIX sg: <https://w3id.org/ash-pplan/standing#>
SELECT ?name ?order WHERE {
  ?p a sg:ChainPolicy ; sg:canonField ?f .
  ?f sg:fieldName ?name ; sg:fieldOrder ?order .
}
ORDER BY ?order

```

**Generated at:** 2026-10-03T09:11:49.339477Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 8 | 1.77 | - |
| graphlaw | ok | 8 | 636.7 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: phases

# Engine Comparison Report

**Query:**

```sparql
PREFIX sg: <https://w3id.org/ash-pplan/standing#>
SELECT ?name ?order WHERE { ?p a sg:Phase ; sg:phaseName ?name ; sg:phaseOrder ?order . }
ORDER BY ?order

```

**Generated at:** 2026-10-03T09:11:50.133702Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 2 | 1.75 | - |
| graphlaw | ok | 2 | 793.83 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |

