import Config

# Ash 3.33 requires the string-length counting model to be explicit.
# Codepoints match SQL data-layer semantics and keep validation consistent
# between in-memory and persisted resources.
config :ash, default_string_length_count: :codepoints
