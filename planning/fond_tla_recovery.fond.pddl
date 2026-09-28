(define (domain fond-tla-recovery)
  (:requirements :strips :typing :non-deterministic)
  (:types policy-state)
  (:predicates
    (strong-requested)
    (strong-cyclic-requested)
    (native-admitted)
    (independent-admitted)
    (mismatch)
    (deadlock)
    (liveness)
    (resynthesis-needed)
    (subject-preserved)
    (sealed))

  (:action validate
    :precondition ()
    :effect (oneof
      (native-admitted)
      (deadlock)
      (liveness)))

  (:action cross-check
    :precondition (native-admitted)
    :effect (oneof
      (independent-admitted)
      (mismatch)))

  (:action downgrade-to-strong-cyclic
    :precondition (and (strong-requested) (liveness))
    :effect (and
      (strong-cyclic-requested)
      (subject-preserved)
      (not (strong-requested))))

  (:action resynthesize
    :precondition (or (deadlock) (liveness))
    :effect (and
      (resynthesis-needed)
      (subject-preserved)))

  (:action seal-agreement
    :precondition (and (native-admitted) (independent-admitted))
    :effect (sealed))
)
