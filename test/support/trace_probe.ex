defmodule AshPPlan.Test.TraceProbe do
  @moduledoc """
  Counts real `AshPPlan.Standing.Chain.digest/1` computations via
  `call_count` tracing on an isolated peer node.

  Why a compiled module on a peer node: (1) message-based call tracing
  (`:erlang.trace/3` + `:erlang.trace_pattern/3` with a tracer) silently
  delivers zero events on this host's Erlang builds, while `call_count`
  works; (2) `call_count` is function-global, so running it in-suite would
  ingest digests from concurrently running tests — a peer node makes the
  count exact; (3) anonymous funs from `mix test` source files cannot be
  applied on a remote node (no loadable beam), so the logic must live in a
  compiled `test/support` module.
  """

  @spec count_digests(map(), keyword()) :: non_neg_integer()
  def count_digests(run, opts) do
    mfa = {AshPPlan.Standing.Chain, :digest, 1}

    # the peer starts with an empty module table: trace_pattern matches 0
    # functions (and trace_info reports :undefined) unless the module is
    # loaded first
    {:module, _} = Code.ensure_loaded(elem(mfa, 0))

    1 = :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      {:ok, _} = AshPPlan.Standing.ladder(run, opts)
      # read the count BEFORE disabling: disabling resets call_count
      {:call_count, count} = :erlang.trace_info(mfa, :call_count)
      count
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end
end
