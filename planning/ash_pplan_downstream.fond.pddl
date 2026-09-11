(define (domain ash-pplan-downstream-fond)
  (:requirements :strips :negative-preconditions :non-deterministic)

  (:predicates
    (renewal-pending)
    (payment-authorized)
    (payment-declined)
    (payment-temporarily-unavailable)
    (payment-unknown)
    (renewed)
    (renewal-retryable-failure)
    (renewal-permanent-failure)
    (observation-required))

  (:action authorize-payment
    :precondition (renewal-pending)
    :effect
      (oneof
        (payment-authorized)
        (payment-declined)
        (payment-temporarily-unavailable)
        (payment-unknown)))

  (:action observe-unknown-payment
    :precondition (payment-unknown)
    :effect
      (oneof
        (payment-authorized)
        (payment-declined)
        (payment-temporarily-unavailable)))

  (:action retry-payment
    :precondition (payment-temporarily-unavailable)
    :effect
      (oneof
        (payment-authorized)
        (payment-declined)
        (payment-temporarily-unavailable)))

  (:action renew-subscription
    :precondition (payment-authorized)
    :effect
      (oneof
        (renewed)
        (renewal-retryable-failure)
        (renewal-permanent-failure)))

  (:action retry-renewal
    :precondition (renewal-retryable-failure)
    :effect
      (oneof
        (renewed)
        (renewal-retryable-failure)
        (renewal-permanent-failure)))
)
