defmodule AshPPlan.ContinuationTest do
  use ExUnit.Case, async: true

  alias AshPPlan.Continuation
  alias AshPPlan.Continuation.ETFCodec

  @plan_iri "https://example.test/plans/renewal"
  @run_id "run-123"

  test "captures and restores an exact halted Reactor identity" do
    reactor = halted_reactor()

    assert {:ok, continuation} =
             Continuation.capture(@plan_iri, @run_id, reactor, ETFCodec)

    assert continuation.id =~ "sha256:"
    assert continuation.plan_iri == @plan_iri
    assert continuation.run_id == @run_id
    assert continuation.codec_id == ETFCodec.id()
    assert continuation.codec_version == ETFCodec.version()

    assert {:ok, restored} = Continuation.restore(continuation, ETFCodec)
    assert restored == reactor
  end

  test "refuses payload tampering before decode" do
    assert {:ok, continuation} =
             Continuation.capture(@plan_iri, @run_id, halted_reactor(), ETFCodec)

    tampered = %{continuation | payload: continuation.payload <> <<0>>}

    assert {:error, %{reason: :continuation_payload_digest_mismatch}} =
             Continuation.restore(tampered, ETFCodec)
  end

  test "refuses a reactor whose plan or run identity disagrees with the envelope" do
    assert {:error, %{reason: :plan_identity_mismatch}} =
             Continuation.capture("other-plan", @run_id, halted_reactor(), ETFCodec)

    wrong_run = %{halted_reactor() | context: %{run_id: "other-run"}}

    assert {:error, %{reason: :run_identity_mismatch}} =
             Continuation.capture(@plan_iri, @run_id, wrong_run, ETFCodec)
  end

  test "ETF codec refuses runtime-only identities instead of claiming durability" do
    reactor = %{halted_reactor() | context: %{run_id: @run_id, ephemeral: make_ref()}}

    assert {:error, %{reason: :codec_encode_failed, error: :non_portable_runtime_term}} =
             Continuation.capture(@plan_iri, @run_id, reactor, ETFCodec)
  end

  test "storage attributes preserve the content-addressed envelope" do
    assert {:ok, continuation} =
             Continuation.capture(@plan_iri, @run_id, halted_reactor(), ETFCodec)

    attributes = Continuation.to_attributes(continuation)
    assert attributes.id == continuation.id
    assert attributes.payload == continuation.payload
    assert attributes.payload_sha256 == continuation.payload_sha256
  end

  describe "a real halted P-PLAN run" do
    @plan "https://w3id.org/ash-pplan#SubscriptionRenewal"
    @authorize "https://w3id.org/ash-pplan#AuthorizePayment"
    @renew "https://w3id.org/ash-pplan#RenewSubscription"

    defp halt_real_plan(run_id) do
      handlers = %{
        @authorize => AshPPlan.Test.Steps.HaltUntilResumed,
        @renew => AshPPlan.Test.Steps.Observe
      }

      assert {{:halted, reactor}, receipt} =
               AshPPlan.execute(@plan, handlers, %{order: 42}, %{}, run_id: run_id)

      assert receipt.status == :halted
      reactor
    end

    test "is captured with the default codec, restored and resumed to completion by Reactor" do
      halted = halt_real_plan("real-run")

      assert {:ok, continuation} = AshPPlan.capture_continuation(@plan, "real-run", halted)
      assert {:ok, restored} = AshPPlan.restore_continuation(continuation)
      assert restored.state == :halted

      assert {:ok, result} =
               AshPPlan.resume_continuation(continuation, ETFCodec, %{resumed_by: "operator"})

      # The successor ran only on resume, saw the halted predecessor's value,
      # the original input and the preserved run identity.
      assert result.predecessors == %{@authorize => :awaiting_authorization}
      assert result.input == %{order: 42}
      assert result.run_id == "real-run"
      assert result.resumed_by == "operator"
    end

    test "carries no runtime-only identity even after a halt" do
      halted = halt_real_plan("portable-run")
      assert ETFCodec.portable?(halted)
    end

    test "a keyed envelope resumes only with the key, which is never forwarded to Reactor" do
      key = :crypto.strong_rand_bytes(32)
      halted = halt_real_plan("keyed-run")

      assert {:ok, continuation} =
               Continuation.capture(@plan, "keyed-run", halted, ETFCodec, integrity_key: key)

      assert {:error, %{reason: :continuation_mac_mismatch}} =
               Continuation.resume(continuation, ETFCodec, %{}, integrity_key: "other key")

      assert {:ok, %{run_id: "keyed-run"}} =
               Continuation.resume(continuation, ETFCodec, %{resumed_by: "operator"},
                 integrity_key: key
               )
    end

    test "a halted value that is a closure is refused instead of claimed durable" do
      handlers = %{@authorize => AshPPlan.Test.Steps.Closure, @renew => AshPPlan.Test.Steps.Emit}

      assert {{:halted, halted}, _receipt} =
               AshPPlan.execute(@plan, handlers, %{}, %{}, run_id: "closure-run")

      assert {:error, %{reason: :codec_encode_failed, error: :non_portable_runtime_term}} =
               AshPPlan.capture_continuation(@plan, "closure-run", halted)
    end
  end

  describe "decode refuses what encode refuses" do
    test "a stored payload carrying a closure, pid or reference is refused on restore" do
      for runtime_only <- [fn -> :closure end, self(), make_ref()] do
        reactor = %{halted_reactor() | context: %{run_id: @run_id, smuggled: [a: {runtime_only}]}}

        assert {:ok, forged} =
                 Continuation.capture(
                   @plan_iri,
                   @run_id,
                   reactor,
                   AshPPlan.Test.UncheckedETFCodec
                 )

        assert {:error, %{reason: :codec_decode_failed, error: :non_portable_runtime_term}} =
                 Continuation.restore(forged, ETFCodec)
      end
    end

    test "external funs naming exported functions are portable; missing ones are not" do
      assert ETFCodec.portable?(%{key: &Enum.map/2})
      refute ETFCodec.portable?(%{key: Function.capture(String, :no_such_function, 9)})
      refute ETFCodec.portable?(%{fn -> :local end => :value})
      refute ETFCodec.portable?([:a | make_ref()])
    end

    test "a payload that is not a Reactor is refused" do
      assert {:error, %{reason: :codec_decode_failed, error: :not_a_reactor}} =
               ETFCodec.decode(:erlang.term_to_binary(%{})) |> wrap_decode()

      assert {:error, :invalid_external_term} = ETFCodec.decode("not etf")
    end
  end

  describe "keyed integrity" do
    @key "application-held secret"

    test "without a key the digest is only content addressing: a recomputed forgery restores" do
      assert {:ok, forged} =
               Continuation.capture(
                 @plan_iri,
                 @run_id,
                 %{halted_reactor() | context: %{run_id: @run_id, forged?: true}},
                 AshPPlan.Test.UncheckedETFCodec
               )

      assert {:ok, %Reactor{context: %{forged?: true}}} = Continuation.restore(forged, ETFCodec)
    end

    test "with a key a missing or wrong mac is refused before decoding" do
      assert {:ok, unkeyed} = Continuation.capture(@plan_iri, @run_id, halted_reactor(), ETFCodec)
      assert unkeyed.mac == nil

      assert {:error, %{reason: :continuation_mac_missing}} =
               Continuation.restore(unkeyed, ETFCodec, integrity_key: @key)

      assert {:ok, keyed} =
               Continuation.capture(@plan_iri, @run_id, halted_reactor(), ETFCodec,
                 integrity_key: @key
               )

      assert keyed.mac =~ ~r/\A[0-9a-f]{64}\z/
      assert {:ok, _reactor} = Continuation.restore(keyed, ETFCodec, integrity_key: @key)

      assert {:error, %{reason: :continuation_mac_mismatch}} =
               Continuation.restore(keyed, ETFCodec, integrity_key: "wrong")

      assert {:error, %{reason: :continuation_mac_mismatch}} =
               Continuation.restore(%{keyed | mac: String.duplicate("0", 64)}, ETFCodec,
                 integrity_key: @key
               )

      assert {:error, %{reason: :continuation_mac_mismatch}} =
               Continuation.restore(%{keyed | mac: "short"}, ETFCodec, integrity_key: @key)
    end

    test "an invalid key is refused rather than silently ignored" do
      for bad <- ["", nil, :atom, 123] do
        assert {:error, %{reason: :invalid_integrity_key}} =
                 Continuation.capture(@plan_iri, @run_id, halted_reactor(), ETFCodec,
                   integrity_key: bad
                 )

        assert {:ok, continuation} =
                 Continuation.capture(@plan_iri, @run_id, halted_reactor(), ETFCodec)

        assert {:error, %{reason: :invalid_integrity_key}} =
                 Continuation.restore(continuation, ETFCodec, integrity_key: bad)
      end
    end
  end

  describe "envelope identity" do
    test "field boundaries are part of the identity" do
      reactor = fn plan_iri, run_id ->
        %Reactor{id: plan_iri, state: :halted, context: %{run_id: run_id}}
      end

      assert {:ok, left} = Continuation.capture("a\nb", "c", reactor.("a\nb", "c"), ETFCodec)
      assert {:ok, right} = Continuation.capture("a", "b\nc", reactor.("a", "b\nc"), ETFCodec)

      assert left.id != right.id
    end

    test "a schema version 1 envelope is refused as unsupported" do
      assert {:ok, continuation} =
               Continuation.capture(@plan_iri, @run_id, halted_reactor(), ETFCodec)

      assert {:error, %{reason: :unsupported_continuation_schema, version: 1}} =
               Continuation.restore(%{continuation | schema_version: 1}, ETFCodec)
    end
  end

  describe "malformed stored envelopes" do
    test "every malformed field is refused with a typed error, never raised" do
      assert {:ok, continuation} =
               Continuation.capture(@plan_iri, @run_id, halted_reactor(), ETFCodec)

      fields = [
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

      for field <- fields, bad <- [nil, %{}, if(field == :schema_version, do: "2", else: 123)] do
        malformed = Map.put(continuation, field, bad)

        assert {:error, %{reason: :invalid_continuation_field, field: ^field}} =
                 Continuation.restore(malformed, ETFCodec)
      end

      assert {:error, %{reason: :invalid_continuation_field, field: :mac}} =
               Continuation.restore(%{continuation | mac: 123}, ETFCodec, integrity_key: "k")
    end

    test "non-envelopes and invalid resume arguments are refused" do
      assert {:error, %{reason: :invalid_continuation_restore}} =
               Continuation.restore(%{id: "sha256:x"}, ETFCodec)

      assert {:ok, continuation} =
               Continuation.capture(@plan_iri, @run_id, halted_reactor(), ETFCodec)

      assert {:error, %{reason: :invalid_continuation_resume}} =
               Continuation.resume(continuation, ETFCodec, nil, [])

      assert {:error, %{reason: :invalid_resume_options}} =
               Continuation.resume(continuation, ETFCodec, %{}, [:not_keyword])

      assert {:error, %{reason: :reserved_context_keys}} =
               Continuation.resume(continuation, ETFCodec, %{ash_pplan: %{}}, [])
    end
  end

  defp wrap_decode({:error, reason}), do: {:error, %{reason: :codec_decode_failed, error: reason}}
  defp wrap_decode(other), do: other

  defp halted_reactor do
    %Reactor{
      id: @plan_iri,
      state: :halted,
      context: %{run_id: @run_id}
    }
  end
end
