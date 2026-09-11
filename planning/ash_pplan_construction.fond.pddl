(define (domain ash-pplan-construction-fond)
  (:requirements :strips :negative-preconditions :non-deterministic)

  (:predicates
    (canonical-ontology)
    (manufactured)
    (verified)
    (build-broken)
    (semantic-refusal)
    (repair-known)
    (packaged)
    (package-broken)
    (release-authorized)
    (released)
    (release-refused)
    (receipted))

  (:action manufacture
    :precondition (canonical-ontology)
    :effect (manufactured))

  (:action verify-candidate
    :precondition (manufactured)
    :effect
      (oneof
        (verified)
        (build-broken)
        (semantic-refusal)))

  (:action diagnose-build
    :precondition (build-broken)
    :effect
      (oneof
        (repair-known)
        (semantic-refusal)))

  (:action repair-and-remanufacture
    :precondition (repair-known)
    :effect
      (and
        (manufactured)
        (not (build-broken))
        (not (repair-known))))

  (:action package
    :precondition (verified)
    :effect
      (oneof
        (packaged)
        (package-broken)))

  (:action repair-package
    :precondition (package-broken)
    :effect
      (and
        (manufactured)
        (not (package-broken))
        (not (verified))))

  (:action publish
    :precondition (and (packaged) (release-authorized))
    :effect
      (oneof
        (released)
        (release-refused)))

  (:action receipt-release
    :precondition (released)
    :effect (receipted))
)
