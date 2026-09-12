import Config

# Ash 3.33 requires an explicit string-length counting policy for resources
# that use string constraints. Codepoints match SQL data-layer semantics and
# keep validation consistent between the Ash control-plane model and storage.
config :ash, default_string_length_count: :codepoints
