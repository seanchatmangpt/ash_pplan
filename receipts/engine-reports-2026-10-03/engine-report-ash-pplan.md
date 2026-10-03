<!-- Promoted from /Users/sac/ash_pplan/tmp/engine-report-ash-pplan.md on 2026-10-03; ggen engine-comparison output over ash-pplan packs. -->
## Query: projections

# Engine Comparison Report

**Query:**

```sparql
PREFIX ap: <https://w3id.org/ash-pplan#>
SELECT DISTINCT ?order ?source ?target ?primitive ?owner ?role ?status ?target_pack WHERE {
  ?projection a ap:Projection ;
      ap:order ?order ;
      ap:sourceTerm ?sourceTerm ;
      ap:targetRuntime ?target ;
      ap:targetPrimitive ?primitive ;
      ap:owner ?owner ;
      ap:role ?role ;
      ap:status ?status .
  BIND(STR(?sourceTerm) AS ?source)
  BIND("ash-pplan-pack" AS ?target_pack)
}
ORDER BY ?order

```

**Generated at:** 2026-10-03T09:10:57.793704Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 13 | 305.91 | - |
| graphlaw | ok | 13 | 1059.09 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: plan_steps

# Engine Comparison Report

**Query:**

```sparql
PREFIX p-plan: <http://purl.org/net/p-plan#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT DISTINCT ?plan ?planLabel ?step ?stepLabel ?predecessor WHERE {
  ?plan a p-plan:Plan .
  OPTIONAL { ?plan rdfs:label ?planLabel }
  ?step a p-plan:Step ;
        p-plan:isStepOfPlan ?plan .
  OPTIONAL { ?step rdfs:label ?stepLabel }
  OPTIONAL { ?step p-plan:isPrecededBy ?predecessor }
}
ORDER BY ?plan ?step ?predecessor

```

**Generated at:** 2026-10-03T09:10:58.511250Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 2 | 6.03 | - |
| graphlaw | ok | 2 | 716.79 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |


---

## Query: plan_variables

# Engine Comparison Report

**Query:**

```sparql
PREFIX p-plan: <http://purl.org/net/p-plan#>
SELECT DISTINCT ?plan ?step ?direction ?variable WHERE {
  ?step a p-plan:Step ;
        p-plan:isStepOfPlan ?plan .
  {
    ?step p-plan:hasInputVar ?variable .
    BIND("input" AS ?direction)
  }
  UNION
  {
    ?step p-plan:hasOutputVar ?variable .
    BIND("output" AS ?direction)
  }
}
ORDER BY ?plan ?step ?direction ?variable

```

**Generated at:** 2026-10-03T09:10:59.351356Z

## Candidates

| Engine | Status | Rows | Elapsed (ms) | Error |
| --- | --- | --- | --- | --- |
| oxigraph | ok | 4 | 5.63 | - |
| graphlaw | ok | 4 | 839.34 | - |

## Pairwise agreement

| Engine A | Engine B | Row-set equal | Row count diff | Order equal |
| --- | --- | --- | --- | --- |
| oxigraph | graphlaw | true | 0 | true |

