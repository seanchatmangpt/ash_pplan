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
  """

  @schema_version 1

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
  defstruct @enforce_keys

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
          payload_sha256: String.t()
        }

  @doc "Captures a halted Reactor into a versioned continuation envelope."
  @spec capture(String.t(), String.t(), Reactor.t(), module()) :: {:ok, t()} | {:error, map()}
  def capture(plan_iri, run_id, %Reactor{state: :halted} = reactor, codec)
      when is_binary(plan_iri) and is_binary(run_id) and is_atom(codec) do
    with :ok <- validate_codec(codec),
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

      {:ok, %{envelope | id: envelope_digest(envelope)}}
    else
      {:error, reason} when is_map(reason) -> {:error, reason}
      {:error, reason} -> {:error, %{reason: :codec_encode_failed, error: reason}}
    end
  end

  def capture(plan_iri, run_id, %Reactor{} = reactor, _codec) do
    {:error,
     %{
       reason: :reactor_not_halted,
       plan_iri: plan_iri,
       run_id: run_id,
       reactor_state: reactor.state
     }}
  end

  def capture(plan_iri, run_id, reactor, codec) do
    {:error,
     %{
       reason: :invalid_continuation_capture,
       plan_iri: plan_iri,
       run_id: run_id,
       reactor?: is_struct(reactor, Reactor),
       codec: codec
     }}
  end

  @doc "Restores a halted Reactor only when identity, digest and versions still match."
  @spec restore(t(), module()) :: {:ok, Reactor.t()} | {:error, map()}
  def restore(%__MODULE__{} = continuation, codec) when is_atom(codec) do
    with :ok <- validate_codec(codec),
         :ok <- validate_schema(continuation),
         :ok <- validate_versions(continuation),
         :ok <- validate_codec_identity(continuation, codec),
         :ok <- validate_digests(continuation),
         {:ok, reactor} <- codec.decode(continuation.payload),
         :ok <- validate_restored_reactor(reactor, continuation) do
      {:ok, reactor}
    else
      {:error, reason} when is_map(reason) -> {:error, reason}
      {:error, reason} -> {:error, %{reason: :codec_decode_failed, error: reason}}
    end
  end

  def restore(continuation, codec),
    do: {:error, %{reason: :invalid_continuation_restore, continuation: continuation, codec: codec}}

  @doc """
  Restores and resumes a continuation through Reactor.

  This delegates execution to Reactor; it is not an authorization boundary.
  Applications should invoke it from an authorized Ash action. The original
  `run_id` is preserved and `:ash_pplan` context replacement is refused.
  """
  @spec resume(t(), module(), map(), keyword()) :: term()
  def resume(%__MODULE__{} = continuation, codec, context \\ %{}, options \\ [])
      when is_map(context) and is_list(options) do
    with :ok <- validate_resume_context(context),
         {:ok, reactor} <- restore(continuation, codec) do
      context = Map.put(context, :run_id, continuation.run_id)
      options = Keyword.put(options, :run_id, continuation.run_id)
      Reactor.run(reactor, %{}, context, options)
    end
  end

  @doc "Returns storage-ready attributes without choosing a persistence backend."
  @spec to_attributes(t()) :: map()
  def to_attributes(%__MODULE__{} = continuation), do: Map.from_struct(continuation)

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
  defp validate_payload(payload), do: {:error, %{reason: :invalid_continuation_payload, payload: payload}}

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
      digest(continuation.payload) != continuation.payload_sha256 ->
        {:error, %{reason: :continuation_payload_digest_mismatch}}

      envelope_digest(%{continuation | id: ""}) != continuation.id ->
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

  defp envelope_digest(continuation) do
    payload = [
      Integer.to_string(continuation.schema_version),
      continuation.plan_iri,
      continuation.run_id,
      continuation.ash_pplan_version,
      continuation.reactor_version,
      continuation.codec_id,
      continuation.codec_version,
      continuation.payload_sha256
    ]

    "sha256:" <> digest(Enum.join(payload, "\n"))
  end

  defp digest(data) do
    :sha256
    |> :crypto.hash(data)
    |> Base.encode16(case: :lower)
  end
end
