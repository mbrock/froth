defmodule FrothWeb.TelemetryLive do
  use FrothWeb, :live_view

  @impl true
  def mount(params, _session, socket) do
    {:ok, push_navigate(socket, to: follow_path(params))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div class="min-h-screen bg-zinc-950"></div>
    </Layouts.app>
    """
  end

  defp follow_path(params) do
    params =
      params
      |> Map.take(["cycle", "span", "q", "mode"])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    ~p"/froth/follow?#{params}"
  end
end
