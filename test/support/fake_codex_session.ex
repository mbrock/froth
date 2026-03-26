defmodule Froth.TestSupport.FakeCodexSession do
  use GenServer

  @registry Froth.Codex.SessionRegistry
  @pubsub Froth.PubSub
  @reasoning_efforts ~w(low medium high xhigh)

  def child_spec(opts) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    snapshot = Keyword.get(opts, :snapshot, default_snapshot(session_id))

    GenServer.start_link(
      __MODULE__,
      %{session_id: session_id, snapshot: normalize_snapshot(session_id, snapshot)},
      name: via(session_id)
    )
  end

  def ensure_started(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    case whereis(session_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        start_link(Keyword.put(opts, :session_id, session_id))
    end
  end

  def subscribe(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(session_id))
  end

  def snapshot(session_id) when is_binary(session_id) do
    case GenServer.call(via(session_id), :snapshot) do
      snapshot when is_map(snapshot) -> {:ok, snapshot}
      other -> other
    end
  end

  def whereis(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def send_prompt(session_id, prompt, opts \\ [])
      when is_binary(session_id) and is_binary(prompt) and is_list(opts) do
    GenServer.call(via(session_id), {:send_prompt, prompt, opts})
  end

  def set_snapshot(session_id, snapshot) when is_binary(session_id) and is_map(snapshot) do
    GenServer.call(via(session_id), {:set_snapshot, snapshot})
  end

  def set_model(session_id, model)
      when is_binary(session_id) and is_binary(model) do
    GenServer.call(via(session_id), {:set_model, model})
  end

  def refresh_available_models(session_id) when is_binary(session_id) do
    GenServer.call(via(session_id), :refresh_available_models)
  end

  def crash(session_id, reason \\ :boom) when is_binary(session_id) do
    case whereis(session_id) do
      pid when is_pid(pid) ->
        Process.exit(pid, reason)
        :ok

      _ ->
        {:error, :not_found}
    end
  end

  def topic(session_id) when is_binary(session_id), do: "codex:session:#{session_id}"

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state.snapshot, state}
  end

  def handle_call({:send_prompt, prompt, opts}, _from, state) do
    turn_id = "turn-#{System.unique_integer([:positive])}"
    prompt = String.trim(prompt)
    images = normalize_images(Keyword.get(opts, :images, []))

    snapshot =
      state.snapshot
      |> maybe_append_user_entry(prompt, images)
      |> Map.put(:active_turn_id, turn_id)

    broadcast_update(state.session_id)
    {:reply, :ok, %{state | snapshot: snapshot}}
  end

  def handle_call({:set_snapshot, snapshot}, _from, state) do
    normalized =
      state.session_id
      |> normalize_snapshot(snapshot)
      |> carry_forward_entries(state.snapshot)
      |> annotate_transition(state.snapshot)

    broadcast_update(state.session_id)
    {:reply, :ok, %{state | snapshot: normalized}}
  end

  def handle_call({:set_reasoning_effort, effort}, _from, state) do
    case normalize_reasoning_effort(effort) do
      nil ->
        {:reply, {:error, :invalid_reasoning_effort}, state}

      normalized ->
        runtime =
          state.snapshot
          |> Map.get(:runtime, %{})
          |> case do
            value when is_map(value) -> value
            _ -> %{}
          end

        snapshot =
          Map.put(state.snapshot, :runtime, Map.put(runtime, :reasoning_effort, normalized))

        broadcast_update(state.session_id)
        {:reply, :ok, %{state | snapshot: snapshot}}
    end
  end

  def handle_call({:set_model, model}, _from, state) do
    case normalize_model_value(model) do
      nil ->
        {:reply, {:error, :invalid_model}, state}

      normalized ->
        runtime =
          state.snapshot
          |> Map.get(:runtime, %{})
          |> case do
            value when is_map(value) -> value
            _ -> %{}
          end

        snapshot =
          Map.put(state.snapshot, :runtime, Map.put(runtime, :model, normalized))

        broadcast_update(state.session_id)
        {:reply, :ok, %{state | snapshot: snapshot}}
    end
  end

  def handle_call(:refresh_available_models, _from, state) do
    snapshot =
      if Map.get(state.snapshot, :available_models, []) == [] do
        Map.put(state.snapshot, :available_models, default_available_models())
      else
        state.snapshot
      end

    broadcast_update(state.session_id)
    {:reply, :ok, %{state | snapshot: snapshot}}
  end

  defp via(session_id), do: {:via, Registry, {@registry, session_id}}

  defp broadcast_update(session_id) do
    Froth.broadcast(topic(session_id), {:codex_session_updated, session_id})
  end

  defp default_snapshot(session_id) do
    %{
      session_id: session_id,
      status: :ready,
      thread_id: "thread-#{session_id}",
      active_turn_id: nil,
      entries: [],
      token_usage: nil,
      rate_limits: nil,
      auth: nil,
      runtime: %{},
      available_models: default_available_models()
    }
  end

  defp normalize_snapshot(session_id, snapshot) when is_map(snapshot) do
    default_snapshot(session_id)
    |> Map.merge(snapshot)
    |> Map.put(:session_id, session_id)
  end

  defp annotate_transition(next_snapshot, previous_snapshot)
       when is_map(next_snapshot) and is_map(previous_snapshot) do
    previous_turn_id = previous_snapshot[:active_turn_id]
    next_turn_id = next_snapshot[:active_turn_id]

    cond do
      is_binary(previous_turn_id) and is_nil(next_turn_id) and next_snapshot[:status] != :error ->
        append_entry(next_snapshot, :status, "turn completed")

      true ->
        next_snapshot
    end
  end

  defp carry_forward_entries(next_snapshot, previous_snapshot)
       when is_map(next_snapshot) and is_map(previous_snapshot) do
    previous_entries = Map.get(previous_snapshot, :entries, [])
    next_entries = Map.get(next_snapshot, :entries, [])

    merged_entries =
      (previous_entries ++ next_entries)
      |> Enum.uniq_by(fn entry ->
        entry[:id] || entry["id"] || entry[:sequence] || entry["sequence"]
      end)

    Map.put(next_snapshot, :entries, merged_entries)
  end

  defp append_entry(snapshot, kind, body)
       when is_map(snapshot) and is_atom(kind) and is_binary(body) do
    append_entry_map(snapshot, %{kind: kind, body: body})
  end

  defp append_entry_map(snapshot, entry) when is_map(snapshot) and is_map(entry) do
    sequence =
      snapshot
      |> Map.get(:entries, [])
      |> Enum.map(&(&1[:sequence] || 0))
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    entry = Map.merge(entry, %{id: "e-#{sequence}", sequence: sequence})
    Map.update(snapshot, :entries, [entry], &(&1 ++ [entry]))
  end

  defp maybe_append_user_entry(snapshot, prompt, images)
       when is_binary(prompt) and is_list(images) do
    if prompt == "" and images == [] do
      snapshot
    else
      entry =
        %{
          kind: :user,
          body: prompt
        }
        |> maybe_put_images(images)

      append_entry_map(snapshot, entry)
    end
  end

  defp maybe_put_images(entry, []), do: entry
  defp maybe_put_images(entry, images), do: Map.put(entry, :images, images)

  defp normalize_images(images) when is_list(images) do
    Enum.flat_map(images, fn
      %{path: path} = image when is_binary(path) and path != "" ->
        [
          %{
            path: path,
            url: Map.get(image, :url) || Map.get(image, "url"),
            alt: Map.get(image, :alt) || Map.get(image, "alt") || "Pasted image"
          }
        ]

      image when is_map(image) ->
        path = Map.get(image, :path) || Map.get(image, "path")

        if is_binary(path) and path != "" do
          [
            %{
              path: path,
              url: Map.get(image, :url) || Map.get(image, "url"),
              alt: Map.get(image, :alt) || Map.get(image, "alt") || "Pasted image"
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp normalize_images(_), do: []

  defp normalize_reasoning_effort(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed in @reasoning_efforts, do: trimmed
  end

  defp normalize_reasoning_effort(_), do: nil

  defp normalize_model_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed != "", do: trimmed
  end

  defp normalize_model_value(_), do: nil

  defp default_available_models do
    [
      %{
        "displayName" => "gpt-5.4",
        "hidden" => false,
        "id" => "gpt-5.4",
        "isDefault" => true,
        "model" => "gpt-5.4"
      },
      %{
        "displayName" => "GPT-5.4-Mini",
        "hidden" => false,
        "id" => "gpt-5.4-mini",
        "isDefault" => false,
        "model" => "gpt-5.4-mini"
      }
    ]
  end
end
