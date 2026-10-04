defmodule AshPPlan.Sim.Marketplace.Vendor.Portal do
  @moduledoc """
  In-process simulation of the vendor signup portal: issues and verifies
  structured JWTs (Base64url(header).Base64url(payload).Base64url(HMAC-SHA256 sig))
  with claims `sub`, `exp`, `aud`.
  """

  use GenServer

  @alg "HS256"

  # -- client API --

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Issue a signup JWT for `sub` with audience `aud`, expiring in `exp_seconds`."
  def issue(portal, attrs) do
    GenServer.call(portal, {:issue, attrs})
  end

  @doc "Verify a token. Returns {:ok, claims} or {:error, :expired | :wrong_aud | :malformed}."
  def verify(portal, token, opts \\ []) do
    GenServer.call(portal, {:verify, token, opts})
  end

  # -- server --

  @impl true
  def init(opts) do
    {:ok, %{secret: Keyword.fetch!(opts, :secret), issued: []}}
  end

  @impl true
  def handle_call({:issue, attrs}, _from, st) do
    attrs = Map.new(attrs)
    now = Map.fetch!(attrs, :now)
    exp_seconds = Map.fetch!(attrs, :exp_seconds)

    claims = %{
      "sub" => Map.fetch!(attrs, :sub),
      "aud" => Map.fetch!(attrs, :aud),
      "exp" => now + exp_seconds,
      "iat" => now
    }

    token = sign(st.secret, claims)
    {:reply, {:ok, token}, %{st | issued: [token | st.issued]}}
  end

  def handle_call({:verify, token, opts}, _from, st) do
    {:reply, do_verify(st.secret, token, opts), st}
  end

  # -- jwt --

  defp sign(secret, claims) do
    header = b64url_encode(Jason.encode!(%{"alg" => @alg, "typ" => "JWT"}))
    payload = b64url_encode(Jason.encode!(claims))
    header <> "." <> payload <> "." <> sig_b64(secret, header <> "." <> payload)
  end

  defp do_verify(secret, token, opts) do
    case String.split(to_string(token), ".", parts: 3) do
      [header, payload, sig] when header != "" and payload != "" and sig != "" ->
        expected = sig_b64(secret, header <> "." <> payload)

        if Plug.Crypto.secure_compare(sig, expected) do
          with {:ok, json} <- Base.url_decode64(payload, padding: false),
               {:ok, claims} <- Jason.decode(json) do
            check_claims(claims, opts)
          else
            _ -> {:error, :malformed}
          end
        else
          {:error, :malformed}
        end

      _ ->
        {:error, :malformed}
    end
  end

  defp check_claims(claims, opts) do
    now = Keyword.get(opts, :now, 0)
    aud = Keyword.get(opts, :aud)

    cond do
      is_integer(claims["exp"]) and claims["exp"] <= now -> {:error, :expired}
      not is_nil(aud) and claims["aud"] != aud -> {:error, :wrong_aud}
      true -> {:ok, claims}
    end
  end

  defp sig_b64(secret, signing_input) do
    :crypto.mac(:hmac, :sha256, secret, signing_input) |> b64url_encode()
  end

  defp b64url_encode(bin), do: Base.url_encode64(bin, padding: false)
end
