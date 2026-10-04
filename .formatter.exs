# Used by "mix format"
spark_locals_without_parens = [
  after: 1,
  authority: 1,
  capability: 1,
  evidence: 1,
  goal: 1,
  method: 1,
  method: 2,
  name: 1,
  outcomes: 1,
  precondition: 1,
  properties: 1,
  subtasks: 1,
  task: 1,
  task: 2,
  version: 1
]

[
  import_deps: [:ash, :ash_state_machine, :ash_oban, :spark, :reactor],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  # vendored phoenix demo-clone bytes; do not reformat upstream files
  excludes: ["test/petal_framework/**"],
  plugins: [Spark.Formatter],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]
