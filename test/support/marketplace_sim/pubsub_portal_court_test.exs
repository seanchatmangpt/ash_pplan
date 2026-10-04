defmodule AshPPlan.Sim.Marketplace.PubsubPortalCourtTest do
  @moduledoc """
  Chicago-style court over the simulated Google Pub/Sub and vendor signup
  portal. Real GenServer processes, no mocks. Includes anti-vacuity probes:
  empty-topic drain and a forged-signature JWT refusal.
  """

  use ExUnit.Case, async: false

  alias AshPPlan.Sim.Marketplace.Google.Pubsub
  alias AshPPlan.Sim.Marketplace.Vendor.Portal

  setup do
    {:ok, pubsub} = Pubsub.start_link(name: nil)
    {:ok, portal} = Portal.start_link(secret: "court-secret", name: nil)

    {:ok, pubsub: pubsub, portal: portal}
  end

  defp collect(_pid, n, timeout \\ 1000) do
    Enum.map(1..n//1, fn _ ->
      assert_receive {:"$gen_cast", {:pubsub_message, _topic, envelope}}, timeout
      envelope
    end)
  end

  describe "pubsub ordered fan-out" do
    test "delivers envelopes in publish order to each of 2 subscribers", %{pubsub: pubsub} do
      sub_a = self()

      sub_b =
        spawn_link(fn ->
          receive_loop()
        end)

      Pubsub.subscribe(pubsub, "orders", sub_a)
      Pubsub.subscribe(pubsub, "orders", sub_b)

      for i <- 1..5 do
        {:ok, id} = Pubsub.publish(pubsub, "orders", %{"n" => i}, "2026-10-03T00:00:0#{i}Z")
        assert id == i
      end

      a = collect(self(), 5)
      assert Enum.map(a, & &1.id) == [1, 2, 3, 4, 5]

      assert Enum.map(a, fn env ->
               {:ok, json} = Base.url_decode64(env.data, padding: false)
               Jason.decode!(json)
             end) == [
               %{"n" => 1},
               %{"n" => 2},
               %{"n" => 3},
               %{"n" => 4},
               %{"n" => 5}
             ]

      send(sub_b, {:drain_req, self()})

      assert_receive {:drained, b}
      assert Enum.map(b, & &1.id) == [1, 2, 3, 4, 5]

      refute_receive {:"$gen_cast", {:pubsub_message, _, _}}
    end

    test "redelivery is counted per {subscriber, id}", %{pubsub: pubsub} do
      Pubsub.subscribe(pubsub, "t", self())
      {:ok, id} = Pubsub.publish(pubsub, "t", %{"x" => 1}, "2026-10-03T00:00:00Z")

      {:ok, 1} = Pubsub.redeliver(pubsub, "t", self())
      assert_received {:"$gen_cast", {:pubsub_message, "t", redelivered}}
      assert redelivered.id == id

      {:ok, 1} = Pubsub.redeliver(pubsub, "t", self())
      assert_received {:"$gen_cast", {:pubsub_message, "t", _}}

      {:ok, redeliveries} = Pubsub.redeliveries(pubsub)
      assert redeliveries == %{{self(), id} => 2}
    end
  end

  describe "portal jwt" do
    test "happy path: issue then verify round-trips claims", %{portal: portal} do
      {:ok, token} =
        Portal.issue(portal, sub: "acct-123", aud: "gcp-marketplace", now: 1000, exp_seconds: 600)

      assert {:ok, %{"sub" => "acct-123", "aud" => "gcp-marketplace", "exp" => 1600}} =
               Portal.verify(portal, token, now: 1000, aud: "gcp-marketplace")
    end

    test "refuses expired token", %{portal: portal} do
      {:ok, token} =
        Portal.issue(portal, sub: "acct-1", aud: "gcp-marketplace", now: 1000, exp_seconds: 600)

      assert {:error, :expired} = Portal.verify(portal, token, now: 1600)
      assert {:error, :expired} = Portal.verify(portal, token, now: 999_999)
    end

    test "refuses wrong audience", %{portal: portal} do
      {:ok, token} =
        Portal.issue(portal, sub: "acct-1", aud: "gcp-marketplace", now: 1000, exp_seconds: 600)

      assert {:error, :wrong_aud} = Portal.verify(portal, token, now: 1100, aud: "other-tenant")
    end

    test "refuses malformed tokens", %{portal: portal} do
      assert {:error, :malformed} = Portal.verify(portal, "not-a-jwt")
      assert {:error, :malformed} = Portal.verify(portal, "a.b")
      assert {:error, :malformed} = Portal.verify(portal, "..")
    end

    # anti-vacuity: a JWT with one flipped signature byte must be refused
    test "refuses forged signature", %{portal: portal} do
      {:ok, token} =
        Portal.issue(portal, sub: "acct-9", aud: "gcp-marketplace", now: 1000, exp_seconds: 600)

      [header, payload, sig] = String.split(token, ".", parts: 3)
      <<first, rest::binary>> = sig
      forged = header <> "." <> payload <> "." <> <<flip(first)>> <> rest

      assert forged != token

      assert {:error, :malformed} =
               Portal.verify(portal, forged, now: 1100, aud: "gcp-marketplace")
    end

    test "signature verifies across portal instances with the same secret" do
      {:ok, p1} = Portal.start_link(secret: "shared", name: nil)
      {:ok, p2} = Portal.start_link(secret: "shared", name: nil)

      {:ok, token} =
        Portal.issue(p1, sub: "acct-2", aud: "gcp-marketplace", now: 1000, exp_seconds: 600)

      assert {:ok, _claims} = Portal.verify(p2, token, now: 1000, aud: "gcp-marketplace")
    end
  end

  defp flip(byte) when is_integer(byte), do: Bitwise.bxor(byte, 0x01)

  defp receive_loop(acc \\ []) do
    receive do
      {:"$gen_cast", {:pubsub_message, _topic, env}} -> receive_loop([env | acc])
      {:drain_req, to} -> send(to, {:drained, Enum.reverse(acc)})
    end
  end
end
