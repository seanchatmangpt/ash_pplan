defmodule AshPPlan.Test.TokyoDepeg.Canonical do
  @moduledoc """
  W3 stage 1 (identity): JCS (RFC 8785) canonical-JSON serialization and an
  effect-identity hash over it, as a pure Elixir helper — no mocks, no stubs.

  Identity stand-in, documented: the production identity is BLAKE3 computed by
  the affidavit wasm kernel (`affidavit commit` via `AshAffidavit.Host/Pool`).
  ash_affidavit is not a mix dep of ash_pplan (see mix.exs), so this court uses
  `:crypto.hash(:blake2b, canonical)` as an explicitly-marked stand-in. The
  affidavit commit is exercised ONLY if `AshAffidavit` happens to be loadable in
  this node; otherwise the test records `UNSUPPORTED(no-dep)` rather than faking
  a commit. See `AshPPlan.Test.TokyoDepeg.Affidavit.commit/2`.

  Scope of the canonicalizer (honest bounds):
    * objects: keys sorted as UTF-8 binaries (byte order == UTF-16 code-unit
      order for the BMP/ASCII payloads this scenario uses; astral-plane key
      ordering is UNSUPPORTED(canonicalizer-scope) and rejected by design).
    * arrays: element order preserved (JCS).
    * strings: JSON-escaped (control chars, quote, backslash); non-ASCII
      passthrough as UTF-8.
    * numbers: ES6 `Number::toString` selection rule — fixed notation when
      1e-6 <= |n| < 1e21, shortest round-trip digits otherwise, no trailing
      ".0", exponent without "+" and without leading zeros.
  """

  @doc "Canonical JCS form of a JSON-shaped term, as an iodata."
  @spec canonicalize(term()) :: iodata()
  def canonicalize(term), do: value(term)

  @doc "Canonical form as a flat binary."
  @spec canonical_string(term()) :: String.t()
  def canonical_string(term), do: IO.iodata_to_binary(value(term))

  @doc """
  Effect identity: BLAKE2b-512 over the JCS canonical form. Explicit stand-in
  for the affidavit kernel's BLAKE3 (see module doc).
  """
  @spec identity(term()) :: String.t()
  def identity(term) do
    term
    |> canonical_string()
    |> then(&:crypto.hash(:blake2b, &1))
    |> Base.encode16(case: :lower)
  end

  # -- values ------------------------------------------------------------------

  defp value(nil), do: "null"
  defp value(true), do: "true"
  defp value(false), do: "false"
  defp value(n) when is_integer(n), do: Integer.to_string(n)
  defp value(n) when is_float(n), do: number(n)

  defp value(s) when is_binary(s) do
    if String.valid?(s) do
      string(s)
    else
      raise ArgumentError,
            "JCS canonicalization requires valid UTF-8 binaries; got invalid binary " <>
              inspect(s)
    end
  end

  defp value(list) when is_list(list) do
    ["[", Enum.map_intersperse(list, ",", &value/1), "]"]
  end

  defp value(%{__struct__: _} = other) do
    raise ArgumentError,
          "JCS canonicalization of structs is UNSUPPORTED(canonicalizer-scope): " <>
            inspect(other)
  end

  defp value(map) when is_map(map) do
    entries =
      map
      |> Enum.map(fn
        {k, v} when is_binary(k) ->
          {k, v}

        {k, v} when is_atom(k) ->
          {Atom.to_string(k), v}

        {k, v} when is_integer(k) ->
          {Integer.to_string(k), v}

        {k, _v} ->
          raise ArgumentError,
                "JCS canonicalization requires binary, atom, or integer map keys; " <>
                  "got key #{inspect(k)}"
      end)
      |> Enum.sort_by(fn {k, _v} -> k end)

    # Distinct map keys (e.g. :a and "a") canonicalize to the same JSON key;
    # emitting both would mint one identity for two different payloads.
    case entries do
      [{k, _}, {k, _} | _] = _colliding when is_binary(k) ->
        raise ArgumentError,
              "JCS canonicalization key collision: distinct map keys canonicalize " <>
                "to the same JSON key #{inspect(k)}"

      _ ->
        :ok
    end

    [
      "{",
      Enum.map_intersperse(entries, ",", fn {k, v} -> [string(k), ?:, value(v)] end),
      "}"
    ]
  end

  defp value(other),
    do: raise(ArgumentError, "not JSON-shaped, cannot canonicalize: " <> inspect(other))

  defp string(s) do
    [
      ?",
      s
      |> String.codepoints()
      |> Enum.map(fn
        "\"" <> _ -> "\\\""
        "\\" <> _ -> "\\\\"
        <<c::utf8>> when c <= 0x1F -> escape_control(c)
        cp -> cp
      end)
      |> Enum.intersperse([])
      |> IO.iodata_to_binary(),
      ?"
    ]
  end

  defp escape_control(0x08), do: "\\b"
  defp escape_control(0x09), do: "\\t"
  defp escape_control(0x0A), do: "\\n"
  defp escape_control(0x0C), do: "\\f"
  defp escape_control(0x0D), do: "\\r"
  defp escape_control(c), do: "\\u" <> (c |> Integer.to_string(16) |> String.pad_leading(4, "0"))

  # -- ES6 number formatting -----------------------------------------------------

  defp number(f) when f == 0.0, do: "0"

  defp number(f) do
    {mantissa_digits, exponent10} = shortest_digits(f)
    es6_from_digits(mantissa_digits, exponent10)
  end

  # Shortest round-trip decimal digits via OTP's :erlang.float_to_binary/2 short
  # format, decomposed into (digits, decimal exponent) with digits "d.ddd" ->
  # "dddd".
  defp shortest_digits(f) do
    case :erlang.float_to_binary(f, [:short]) do
      "Infinity" ->
        raise(ArgumentError, "JCS cannot canonicalize infinity")

      "-Infinity" ->
        raise(ArgumentError, "JCS cannot canonicalize infinity")

      "NaN" ->
        raise(ArgumentError, "JCS cannot canonicalize NaN")

      sci ->
        {mantissa, exp} =
          case String.split(sci, ~r/[eE]/) do
            [m] -> {m, 0}
            [m, e] -> {m, String.to_integer(e)}
          end

        {int_part, frac_part} =
          case String.split(mantissa, ".") do
            [i] -> {i, ""}
            [i, fr] -> {i, fr}
          end

        digits = int_part <> frac_part
        # value = digits * 10^exp, where leading digit position: "d.ddd" e=k
        # means digits * 10^(exp - length(frac)).
        {digits, exp - String.length(frac_part)}
    end
  end

  # ES6 Number::toString selection: fixed notation when 1e-6 <= |n| < 1e21
  # (i.e. -5 <= k <= 21 where value = 0.body * 10^k), scientific otherwise.
  defp es6_from_digits(digits, exp10) do
    neg = String.starts_with?(digits, "-")
    body = if neg, do: String.slice(digits, 1..-1//1), else: digits

    # decimal point position k from the UNTRIMMED digits:
    # value = 0.body * 10^(exp10 + len); then trim trailing zeros (ES6 "1.0"
    # renders as "1") — trimming preserves the value, so k is unchanged.
    k = exp10 + String.length(body)
    body = String.trim_trailing(body, "0")
    len = String.length(body)

    text =
      cond do
        # fixed window is 1e-6 <= |n| < 1e21, i.e. -5 <= k <= 21
        k <= -6 ->
          scientific(body, k)

        k >= 22 ->
          scientific(body, k)

        k > 0 ->
          if k >= len do
            # pad right of the digits (e.g. 1e3 -> 1000)
            body <> String.duplicate("0", k - len)
          else
            String.slice(body, 0, k) <> "." <> String.slice(body, k..-1//1)
          end

        true ->
          "0." <> String.duplicate("0", -k) <> body
      end

    if neg, do: "-" <> text, else: text
  end

  defp scientific(body, k) do
    mantissa =
      String.at(body, 0) <>
        if String.length(body) > 1, do: "." <> String.slice(body, 1..-1//1), else: ""

    "#{mantissa}e#{k - 1}"
  end
end
