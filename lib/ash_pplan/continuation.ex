defmodule AshPPlan.Continuation do
  @moduledoc """
  Versioned, content-addressed persistence envelope for a halted Reactor.

  Reactor owns halting and resumption. `AshPPlan.Continuation` adds the durable
  boundary Reactor intentionally does not own: explicit serialization,
  compatibility identity, tamper detection and replay admission.

  Storage remains application-owned. Persist this envelope through an
  authorized Ash resource/action or another admitted store. Restoring an
  envelope does not grant authority to resume it; `resume/4` should be called
  from the application's authorized action boundary.

  ## Integrity

  `id` and `payload_sha256` are unkeyed SHA-256 content addresses. They detect
  accidental corruption and identity drift only: anyone able to write to the
  store can recompute them for a forged payload. They are **not** adversarial
  tamper protection.

  For adversarial integrity pass `integrity_key: key` (a non-empty binary
  secret held by the application, never by the store) to `capture/5`. The
  envelope then carries `mac`, an HMAC-SHA256 over its content address. When
  the same option is given to `restore/3` or `resume/4`, an envelope whose
  `mac` is missing or does not verify (constant-time comparison) is refused
  before its payload is decoded.

  ## Schema

  Schema version 2 content-addresses the envelope over length-prefixed fields.
  Version 1 envelopes, whose identity used an ambiguous separator, are refused
  as `:unsupported_continuation_schema`.
  """

  @schema_version 2
  @mac_domain "ash_pplan.continuation.mac.v1"

  @binary_fields [
    :id,
    :plan_iri,
    :run_id,
    :ash_pplan_version,
    :reactor_version,
    :codec_id,
    :codec_version,
    :payload,
    :payload_sha256
  ]

  @enforce_keys [
    :id,
    :schema_version,
    :plan_iri,
    :run_id,
    :ash_pplan_version,
    :reactor_version,
    :codec_id,
    :codec_version,
    :payload,
    :payload_sha256
  ]
  defstruct @enforce_keys ++ [mac: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          schema_version: pos_integer(),
          plan_iri: String.t(),
          run_id: String.t(),
          ash_pplan_version: String.t(),
          reactor_version: String.t(),
          codec_id: String.t(),
          codec_version: String.t(),
          payload: binary(),
          payload_sha256: String.t(),
          mac: String.t() | nil
        }

  @typedoc "Options accepted by `capture/5`, `restore/3` and `resume/4`."
  @type option :: {:integrity_key, binary()}

  @doc """
  Captures a halted Reactor into a versioned continuation envelope.

  Options:

    * `:integrity_key` - a non-empty binary secret. When given, the envelope
      carries an HMAC-SHA256 `mac` that `restore/3` can verify.
  """
  @spec capture(String.t(), String.t(), Reactor.t(), module(), [option()]) ::
          {:ok, t()} | {:error, map()}
  def capture(plan_iri, run_id, reactor, codec, opts \\ [])

  def capture(plan_iri, run_id, %Reactor{state: :halted} = reactor, codec, opts)
      when is_binary(plan_iri) and is_binary(run_id) and is_atom(codec) and is_list(opts) do
    with {:ok, key} <- integrity_key(opts),
         :ok <- validate_codec(codec),
         :ok <- validate_reactor_identity(reactor, plan_iri, run_id),
         {:ok, payload} <- codec.encode(reactor),
         :ok <- validate_payload(payload) do
      envelope = %__MODULE__{
        id: "",
        schema_version: @schema_version,
        plan_iri: plan_iri,
        run_id: run_id,
        ash_pplan_version: AshPPlan.version(),
        reactor_version: reactor_version(),
        codec_id: codec.id(),
        codec_version: codec.version(),
        payload: payload,
        payload_sha256: digest(payload)
      }

      envelope = %{envelope | id: envelope_digest(envelope)}
      {:ok, %{envelope | mac: mac(key, envelope)}}
    else
      {:error, reason} when is_map(reason) -> {:error, reason}
      {:error, reason} -> {:error, %{reason: :codec_encode_failed, error: reason}}
    end
  end

  def capture(plan_iri, run_id, %Reactor{state: state}, _codec, _opts) when state != :halted do
    {:error,
     %{
       reason: :reactor_not_halted,
       plan_iri: plan_iri,
       run_id: run_id,
       reactor_state: state
     }}
  end

  def capture(plan_iri, run_id, reactor, codec, _opts) do
    {:error,
     %{
       reason: :invalid_continuation_capture,
       plan_iri: plan_iri,
       run_id: run_id,
       reactor?: is_struct(reactor, Reactor),
       codec: codec
     }}
  end

  @doc """
  Restores a halted Reactor only when identity, digest and versions still match.

  Malformed envelopes are refused with a typed error; this function does not
  raise on stored data. With `integrity_key:`, a missing or mismatched `mac`
  is refused before the payload is decoded.
  """
  @spec restore(t(), module(), [option()]) :: {:ok, Reactor.t()} | {:error, map()}
  def restore(continuation, codec, opts \\ [])

  def restore(%__MODULE__{} = continuation, codec, opts) when is_atom(codec) and is_list(opts) do
    with {:ok, key} <- integrity_key(opts),
         :ok <- validate_fields(continuation),
         :ok <- validate_codec(codec),
         :ok <- validate_schema(continuation),
         :ok <- validate_versions(continuation),
         :ok <- validate_codec_identity(continuation, codec),
         :ok <- validate_digests(continuation),
         :ok <- validate_mac(key, continuation),
         {:ok, reactor} <- decode(codec, continuation.payload),
         :ok <- validate_restored_reactor(reactor, continuation) do
      {:ok, reactor}
    else
      {:error, reason} when is_map(reason) -> {:error, reason}
      {:error, reason} -> {:error, %{reason: :codec_decode_failed, error: reason}}
    end
  end

  def restore(continuation, codec, _opts),
    do:
      {:error,
       %{
         reason: :invalid_continuation_restore,
         continuation?: is_struct(continuation, __MODULE__),
         codec: codec
       }}

  @doc """
  Restores and resumes a continuation through Reactor.

  This delegates execution to Reactor; it is not an authorization boundary.
  Applications should invoke it from an authorized Ash action. The original
  `run_id` and the original Reactor inputs are preserved, and `:ash_pplan`
  context replacement is refused.

  `options` are Reactor run options plus `:integrity_key`, which is consumed
  here (see `restore/3`) and never forwarded to Reactor.
  """
  @spec resume(t(), module(), map(), keyword()) :: term()
  def resume(continuation, codec, context \\ %{}, options \\ [])

  def resume(%__MODULE__{} = continuation, codec, context, options)
      when is_map(context) and is_list(options) do
    with :ok <- validate_resume_options(options),
         :ok <- validate_resume_context(context),
         {key_opts, reactor_options} = Keyword.split(options, [:integrity_key]),
         {:ok, reactor} <- restore(continuation, codec, key_opts) do
      context = Map.put(context, :run_id, continuation.run_id)
      reactor_options = Keyword.put(reactor_options, :run_id, continuation.run_id)
      Reactor.run(reactor, original_inputs(reactor), context, reactor_options)
    end
  end

  def resume(continuation, codec, context, options) do
    {:error,
     %{
       reason: :invalid_continuation_resume,
       continuation?: is_struct(continuation, __MODULE__),
       codec: codec,
       context?: is_map(context),
       options?: is_list(options) and Keyword.keyword?(options)
     }}
  end

  @doc "Returns storage-ready attributes without choosing a persistence backend."
  @spec to_attributes(t()) :: map()
  def to_attributes(%__MODULE__{} = continuation), do: Map.from_struct(continuation)

  # Reactor re-validates declared inputs even when resuming a halted run, and
  # keeps the inputs it was first given under `context.private.inputs`.
  defp original_inputs(%Reactor{context: context}) do
    case context do
      %{private: %{inputs: inputs}} when is_map(inputs) -> inputs
      _ -> %{}
    end
  end

  defp validate_resume_options(options) do
    if Keyword.keyword?(options) do
      :ok
    else
      {:error, %{reason: :invalid_resume_options}}
    end
  end

  defp integrity_key(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.fetch(opts, :integrity_key) do
        :error -> {:ok, nil}
        {:ok, key} when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
        {:ok, _key} -> {:error, %{reason: :invalid_integrity_key}}
      end
    else
      {:error, %{reason: :invalid_continuation_options}}
    end
  end

  defp mac(nil, _envelope), do: nil

  defp mac(key, envelope) do
    :hmac
    |> :crypto.mac(:sha256, key, [@mac_domain, 0, envelope.id])
    |> Base.encode16(case: :lower)
  end

  defp validate_mac(nil, _continuation), do: :ok

  defp validate_mac(_key, %__MODULE__{mac: nil}),
    do: {:error, %{reason: :continuation_mac_missing}}

  defp validate_mac(key, %__MODULE__{mac: mac} = continuation) when is_binary(mac) do
    if secure_equal?(mac(key, continuation), mac) do
      :ok
    else
      {:error, %{reason: :continuation_mac_mismatch}}
    end
  end

  defp validate_mac(_key, _continuation),
    do: {:error, %{reason: :invalid_continuation_field, field: :mac}}

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false

  defp validate_fields(continuation) do
    invalid =
      Enum.reject(@binary_fields, fn field -> is_binary(Map.fetch!(continuation, field)) end)

    invalid =
      if is_integer(continuation.schema_version),
        do: invalid,
        else: [:schema_version | invalid]

    invalid =
      if is_nil(continuation.mac) or is_binary(continuation.mac),
        do: invalid,
        else: invalid ++ [:mac]

    case invalid do
      [] -> :ok
      [field | _] -> {:error, %{reason: :invalid_continuation_field, field: field}}
    end
  end

  defp decode(codec, payload) do
    codec.decode(payload)
  rescue
    error -> {:error, {:codec_raised, error.__struct__}}
  end

  defp validate_codec(codec) do
    required = [{:id, 0}, {:version, 0}, {:encode, 1}, {:decode, 1}]

    missing =
      if Code.ensure_loaded?(codec) do
        Enum.reject(required, fn {name, arity} -> function_exported?(codec, name, arity) end)
      else
        required
      end

    cond do
      missing != [] ->
        {:error, %{reason: :invalid_continuation_codec, codec: codec, missing: missing}}

      not is_binary(codec.id()) or not is_binary(codec.version()) ->
        {:error, %{reason: :invalid_continuation_codec_identity, codec: codec}}

      true ->
        :ok
    end
  end

  defp validate_reactor_identity(%Reactor{id: id, context: context}, plan_iri, run_id) do
    cond do
      id != plan_iri ->
        {:error, %{reason: :plan_identity_mismatch, expected: plan_iri, actual: id}}

      Map.get(context, :run_id) != run_id ->
        {:error,
         %{
           reason: :run_identity_mismatch,
           expected: run_id,
           actual: Map.get(context, :run_id)
         }}

      true ->
        :ok
    end
  end

  defp validate_payload(payload) when is_binary(payload), do: :ok

  defp validate_payload(payload),
    do: {:error, %{reason: :invalid_continuation_payload, payload: payload}}

  defp validate_schema(%__MODULE__{schema_version: @schema_version}), do: :ok

  defp validate_schema(%__MODULE__{schema_version: version}),
    do: {:error, %{reason: :unsupported_continuation_schema, version: version}}

  defp validate_versions(continuation) do
    cond do
      continuation.ash_pplan_version != AshPPlan.version() ->
        {:error,
         %{
           reason: :ash_pplan_version_mismatch,
           expected: AshPPlan.version(),
           actual: continuation.ash_pplan_version
         }}

      continuation.reactor_version != reactor_version() ->
        {:error,
         %{
           reason: :reactor_version_mismatch,
           expected: reactor_version(),
           actual: continuation.reactor_version
         }}

      true ->
        :ok
    end
  end

  defp validate_codec_identity(continuation, codec) do
    if continuation.codec_id == codec.id() and continuation.codec_version == codec.version() do
      :ok
    else
      {:error,
       %{
         reason: :continuation_codec_mismatch,
         expected: {continuation.codec_id, continuation.codec_version},
         actual: {codec.id(), codec.version()}
       }}
    end
  end

  defp validate_digests(continuation) do
    cond do
      not secure_equal?(digest(continuation.payload), continuation.payload_sha256) ->
        {:error, %{reason: :continuation_payload_digest_mismatch}}

      not secure_equal?(envelope_digest(continuation), continuation.id) ->
        {:error, %{reason: :continuation_identity_mismatch}}

      true ->
        :ok
    end
  end

  defp validate_restored_reactor(%Reactor{state: :halted} = reactor, continuation) do
    validate_reactor_identity(reactor, continuation.plan_iri, continuation.run_id)
  end

  defp validate_restored_reactor(%Reactor{} = reactor, _continuation),
    do: {:error, %{reason: :restored_reactor_not_halted, state: reactor.state}}

  defp validate_restored_reactor(other, _continuation),
    do: {:error, %{reason: :restored_value_not_reactor, value: other}}

  defp validate_resume_context(context) do
    if Map.has_key?(context, :ash_pplan) do
      {:error, %{reason: :reserved_context_keys, keys: [:ash_pplan]}}
    else
      :ok
    end
  end

  defp reactor_version do
    case Application.spec(:reactor, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  # Every admitted field is length-prefixed, so no two distinct envelopes can
  # share an encoding (and therefore an identity) whatever bytes they carry.
  defp envelope_digest(continuation) do
    fields = [
      Integer.to_string(continuation.schema_version),
      continuation.plan_iri,
      continuation.run_id,
      continuation.ash_pplan_version,
      continuation.reactor_version,
      continuation.codec_id,
      continuation.codec_version,
      continuation.payload_sha256
    ]

    encoded = Enum.map(fields, fn field -> [Integer.to_string(byte_size(field)), ":", field] end)

    "sha256:" <> digest(["ash_pplan.continuation.v2\n" | encoded])
  end

  defp digest(data) do
    :sha256
    |> :crypto.hash(data)
    |> Base.encode16(case: :lower)
  end
end
