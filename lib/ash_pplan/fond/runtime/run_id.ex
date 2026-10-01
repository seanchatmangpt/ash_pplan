defmodule AshPPlan.FOND.Runtime.RunId do
  def new(subject \\ "run"),
    do: subject <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
end
