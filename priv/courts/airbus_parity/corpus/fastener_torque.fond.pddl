;; Benchmark Domain: Aerospace Fastener Torque Recovery
;; Paradigm: Fully Observable Non-Deterministic (FOND) planning
;; Winning Semantics: Strong-Cyclic (policy guaranteed to reach absorbing goal under fair execution)

(define (domain fastener_torque)
  (:requirements :strips :non-deterministic :typing)

  (:types
    hole fastener - object
  )

  (:predicates
    (hole_ready ?h - hole)
    (fastener_seated ?f - fastener ?h - hole)
    (fastener_torqued ?f - fastener ?h - hole)
    (thread_stripped ?h - hole)
    (hole_re_tapped ?h - hole)
    (fastener_extracted ?f - fastener ?h - hole)
    (fastener_scrapped ?f - fastener)
  )

  ;; Action 1: Insert and thread fastener (deterministic)
  (:action insert_fastener
    :parameters (?f - fastener ?h - hole)
    :precondition (and (hole_ready ?h) (not (fastener_seated ?f ?h)))
    :effect (fastener_seated ?f ?h)
  )

  ;; Action 2: Apply calibrated torque specification (non-deterministic outcome)
  ;; Outcomes:
  ;; 1. Nominal torque achieved (Goal branch)
  ;; 2. Fastener head or hole thread strips (Recovery branch needed)
  (:action apply_torque
    :parameters (?f - fastener ?h - hole)
    :precondition (and (fastener_seated ?f ?h) (not (thread_stripped ?h)))
    :effect (oneof
      (fastener_torqued ?f ?h)
      (and (thread_stripped ?h) (not (fastener_seated ?f ?h)))
    )
  )

  ;; Action 3: Extract damaged fastener from stripped hole
  (:action extract_damaged_fastener
    :parameters (?f - fastener ?h - hole)
    :precondition (thread_stripped ?h)
    :effect (and (fastener_extracted ?f ?h) (fastener_scrapped ?f))
  )

  ;; Action 4: Re-tap hole with oversize helicoil insert
  (:action retap_and_helicoil
    :parameters (?h - hole ?f - fastener)
    :precondition (fastener_extracted ?f ?h)
    :effect (and (not (thread_stripped ?h)) (hole_ready ?h) (hole_re_tapped ?h))
  )
)
