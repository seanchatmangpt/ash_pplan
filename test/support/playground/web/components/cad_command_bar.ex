defmodule AshPPlan.Playground.CadCommandBar do
  @moduledoc """
  Stateful LiveComponent providing a keyboard-first Computer-Aided Dispatch (CAD)
  command bar for the Tactical Common Operating Picture (COP).

  Commands supported:
  - `DISPATCH <wo_id> <vendor_id>`
  - `NTE <wo_id> <amount>`
  - `DETOUR <wo_id>`
  - `RESET`
  - `CRASH`
  """

  use Phoenix.LiveComponent

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :error, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="bg-zinc-950 border border-zinc-800 p-2 rounded-lg font-mono">
      <form phx-submit="execute_command" phx-target={@myself} class="flex items-center gap-2">
        <span class="text-emerald-500 font-bold text-sm select-none">CAD&gt;</span>
        <input
          id="cad-input"
          type="text"
          name="cmd"
          autocomplete="off"
          placeholder="DISPATCH <wo> <vendor> | NTE <wo> <amt> | DETOUR <wo> | CRASH"
          class="flex-1 bg-transparent border-none text-zinc-100 text-xs focus:ring-0 focus:outline-none placeholder-zinc-650"
        />
        <kbd class="text-[10px] bg-zinc-900 text-zinc-400 px-1.5 py-0.5 rounded border border-zinc-750">
          Enter ↵
        </kbd>
      </form>

      <%= if @error do %>
        <div id="cad-error-msg" class="text-[10px] text-rose-400 mt-1">
          {@error}
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("execute_command", %{"cmd" => command_text}, socket) do
    case parse_command(command_text) do
      {:ok, {action, target_id, payload}} ->
        send(self(), {:cad_action, action, target_id, payload})
        {:noreply, assign(socket, :error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, reason)}
    end
  end

  defp parse_command(cmd) when is_binary(cmd) do
    parts =
      cmd
      |> String.trim()
      |> String.split(~r/\s+/, trim: true)

    case parts do
      ["DISPATCH", wo_id, vendor_id] ->
        {:ok, {:dispatch, wo_id, %{vendor: vendor_id}}}

      ["NTE", wo_id, amount_str] ->
        case Integer.parse(amount_str) do
          {amount, ""} -> {:ok, {:bump_nte, wo_id, %{nte: amount}}}
          _ -> {:error, "Invalid NTE amount: #{amount_str}"}
        end

      ["DETOUR", wo_id] ->
        {:ok, {:detour, wo_id, %{}}}

      ["RESET"] ->
        {:ok, {:reset, "all", %{}}}

      ["CRASH"] ->
        {:ok, {:crash, "store", %{}}}

      [] ->
        {:error, "Empty CAD command"}

      _ ->
        {:error,
         "Syntax error. Usage: DISPATCH <wo> <vendor> | NTE <wo> <amt> | DETOUR <wo> | RESET"}
    end
  end
end
