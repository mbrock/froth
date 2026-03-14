defmodule FrothWeb.SceneChannel do
  use Phoenix.Channel

  alias Froth.SceneEvents

  @impl true
  def join("scene:" <> scene_id, _params, socket) do
    # Materialize current state and send to client
    state = SceneEvents.materialize(scene_id)
    events = SceneEvents.events(scene_id)
    last_seq = case events do
      [] -> 0
      evts -> List.last(evts).seq
    end

    socket = socket
    |> assign(:scene_id, scene_id)
    |> assign(:last_seq, last_seq)

    {:ok, %{state: SceneEvents.to_client(state), last_seq: last_seq}, socket}
  end

  @impl true
  def handle_in("event", %{"type" => type, "payload" => payload}, socket) do
    scene_id = socket.assigns.scene_id
    author = socket.assigns[:author] || "browser"

    case SceneEvents.append(scene_id, type, payload, author: author) do
      {:ok, event} ->
        # Broadcast to all clients including sender
        broadcast!(socket, "event", %{
          type: event.type,
          payload: event.payload,
          seq: event.seq,
          author: event.author
        })
        {:reply, {:ok, %{seq: event.seq}}, socket}

      {:error, _changeset} ->
        {:reply, {:error, %{reason: "failed to persist"}}, socket}
    end
  end

  @impl true
  def handle_in("catch_up", %{"after_seq" => after_seq}, socket) do
    events = SceneEvents.events_after(socket.assigns.scene_id, after_seq)
    serialized = Enum.map(events, fn e ->
      %{type: e.type, payload: e.payload, seq: e.seq, author: e.author}
    end)
    {:reply, {:ok, %{events: serialized}}, socket}
  end
end
