;; Benchmark Domain: Avionics Bay Sensor Fault Isolation
;; Paradigm: Partially Observable (PO) with sensor observations

(define (domain avionics_bay)
  (:requirements :strips :typing :equality)

  (:types
    bay bus sensor lru - object
  )

  (:predicates
    (lru_powered ?l - lru)
    (lru_faulty ?l - lru)
    (bus_healthy ?b - bus)
    (sensor_valid ?s - sensor)
    (isolated ?l - lru)
    (redundant_active ?l - lru)
  )

  ;; Built-in test (BIT) provides observation of suspected LRU
  (:action run_built_in_test
    :parameters (?l - lru ?s - sensor)
    :precondition (and (lru_powered ?l) (sensor_valid ?s))
    :effect (and (isolated ?l))
  )

  ;; Switch over to secondary redundant avionics channel
  (:action engage_redundant_channel
    :parameters (?primary - lru ?backup - lru)
    :precondition (isolated ?primary)
    :effect (and (not (lru_powered ?primary)) (redundant_active ?backup))
  )
)
