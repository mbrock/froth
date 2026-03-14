defmodule FrothWeb.SceneLive do
  use FrothWeb, :live_view

  @impl true
  def mount(%{"id" => scene_id}, _session, socket) do
    {:ok, assign(socket, :scene_id, scene_id)}
  end

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :scene_id, "default")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="scene-editor" phx-hook="SceneEditor"
         data-scene-id={@scene_id}
         data-bg-url="/froth/assets/scene_bg.png"
         style="width: 100vw; height: 100vh; overflow: hidden; background: #111;">
    </div>
    """
  end
end
