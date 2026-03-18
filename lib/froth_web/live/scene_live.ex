defmodule FrothWeb.SceneLive do
  use FrothWeb, :live_view

  @impl true
  def mount(%{"id" => scene_id}, _session, socket) do
    {:ok, socket |> assign(:scene_id, scene_id) |> assign_new(:current_scope, fn -> nil end)}
  end

  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:scene_id, "default") |> assign_new(:current_scope, fn -> nil end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant={:plain}>
      <div
        id="scene-editor"
        phx-hook="SceneEditor"
        phx-update="ignore"
        data-scene-id={@scene_id}
        data-bg-url="/froth/assets/scene_bg.png"
        class="min-h-screen bg-stone-950"
      >
      </div>
    </Layouts.app>
    """
  end
end
