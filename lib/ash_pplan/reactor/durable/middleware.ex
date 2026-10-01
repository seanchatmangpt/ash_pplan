defmodule AshPPlan.Reactor.Durable.Middleware do
  @moduledoc """
  Reactor middleware of a durable run.

  A step failure that nothing can compensate is written to the run's row from here, before the
  rollback it triggers takes anything back, so an attempt that finds a rollback under way
  still has the cause on record (first error wins: the guarded `:unwinding` transition is
  refused once the run is already rolling back).

  Design derived from mbuhot/magma (MIT per its mix.exs).
  """
  use Reactor.Middleware

  alias AshPPlan.Reactor.Durable.Run

  @impl true
  def event({:run_error, error}, step, context) do
    unless Reactor.Step.can?(step, :compensate), do: Run.record_error(context, error)
    :ok
  end

  def event({:compensate_error, error}, _step, context), do: Run.record_error(context, error)
  def event(_event, _step, _context), do: :ok
end
