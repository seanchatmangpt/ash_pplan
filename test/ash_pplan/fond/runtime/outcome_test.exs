defmodule AshPPlan.FOND.Runtime.OutcomeTest do
 use ExUnit.Case, async: true
 alias AshPPlan.FOND.Runtime.Outcome
 test "timeout is retryable", do: assert Outcome.classify({:error,:timeout})=={:retryable,:timeout}
 test "unknown errors are terminal", do: assert Outcome.classify({:error,:boom})=={:terminal,:boom}
end