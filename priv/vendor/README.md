# Vendored Canonical Ontologies

ash_pplan does NOT maintain a private P-PLAN. The projection ontology
(`ontology.ttl`) imports the canonical upstream vocabularies and this court
(`test/courts/pplan_upstream_court_test.exs`) refuses private terms.

## p-plan 1.3 (`p-plan-1.3/p-plan.owl`)

- Canonical URI: `http://purl.org/net/p-plan#`
- Source: `http://vocab.linkeddata.es/p-plan/p-plan.owl`
- Retrieved via: Internet Archive snapshot
  `https://web.archive.org/web/20201028081520id_/http://vocab.linkeddata.es/p-plan/p-plan.owl`
  (2026-10-04, because the live vocab.linkeddata.es server is currently
  serving a placeholder page and the `dgarijo` GitHub paths return 404)
- Authors: Daniel Garijo, Yolanda Gil. License: CC-BY-4.0. Version 1.3.
- Format: RDF/XML (canonical distribution format — no .ttl was ever served
  at that URL per the archive record).

## prov-o (`prov-o/prov-o.ttl`)

- Canonical URI: `http://www.w3.org/ns/prov#`
- Source: `https://www.w3.org/ns/prov-o.ttl` (fetched live 2026-10-04, 200 OK)

## Court coverage

`test/courts/pplan_upstream_court 5 tests, 0 failures` expected:
- vendored p-plan is version 1.3, authors Garijo/Gil, 17+ declarations incl.
  Plan/Step/Variable/Activity/Entity/Bundle/MultiStep + 7 properties used
- every p-plan: and prov: term used in `ontology.ttl` is declared upstream
- `owl:imports` pins the canonical namespaces
