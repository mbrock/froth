defmodule Froth.Agent do
  @moduledoc """
  Context for agentic cycles: data access and the public `run` entry point.
  """

  import Ecto.Query

  alias LLM

  alias Froth.Agent.{
    Config,
    Cycle,
    CycleItem,
    Message,
    ToolDescription,
    Worker
  }

  alias Froth.{Event, ObjectStore, Repo}

  @payload_blob_threshold 8_000
  @preview_string_limit 320
  @preview_list_limit 8

  @spec run(Message.t() | Cycle.t(), Config.t()) ::
          {Cycle.t(), Enumerable.t()}
  def run(%Message{} = message, %Config{} = config) do
    message
    |> begin_cycle(config)
    |> run(config)
  end

  def run(%Cycle{id: id} = cycle, %Config{} = config) when not is_nil(id) do
    {cycle, cycle_stream(cycle, config)}
  end

  @spec begin_cycle(Message.t(), Config.t()) :: Cycle.t()
  def begin_cycle(%Message{} = message, %Config{} = config) do
    cycle =
      %Cycle{}
      |> Cycle.changeset(cycle_snapshot_attrs(config))
      |> Repo.insert!()

    _message =
      append_message(
        cycle,
        message.role,
        message.content,
        message.metadata,
        0
      )

    cycle
  end

  defp cycle_stream(%Cycle{} = cycle, %Config{} = config) do
    Stream.resource(
      fn ->
        Phoenix.PubSub.subscribe(Froth.PubSub, "cycle:#{cycle.id}")
        {:ok, pid} = Worker.start_link({cycle, config})
        {pid, Process.monitor(pid)}
      end,
      fn {pid, ref} ->
        receive do
          {:stream, event} ->
            {[{:stream, event}], {pid, ref}}

          {:event, event} ->
            {[{:event, event}], {pid, ref}}

          {:message, msg} ->
            {[{:message, msg}], {pid, ref}}

          {:DOWN, ^ref, :process, ^pid, :normal} ->
            {:halt, {pid, ref}}

          {:DOWN, ^ref, :process, ^pid, reason} ->
            exit(reason)
        end
      end,
      fn {_pid, _ref} ->
        Phoenix.PubSub.unsubscribe(Froth.PubSub, "cycle:#{cycle.id}")
      end
    )
  end

  @spec update_cycle(Cycle.t(), map()) :: Cycle.t()
  def update_cycle(%Cycle{} = cycle, attrs) when is_map(attrs) do
    cycle
    |> Cycle.changeset(normalize_cycle_attrs(attrs))
    |> Repo.update!()
  end

  @doc false
  @spec cycle_snapshot_attrs(Config.t()) :: map()
  def cycle_snapshot_attrs(%Config{} = config),
    do: initial_cycle_attrs(config)

  @spec append_event(Cycle.t(), map()) :: Event.t()
  def append_event(%Cycle{} = cycle, attrs) when is_map(attrs) do
    append_event(cycle, attrs, nil)
  end

  @spec append_event(Cycle.t(), map(), integer() | nil) :: Event.t()
  def append_event(%Cycle{id: cycle_id}, attrs, seq)
      when is_map(attrs) and not is_nil(cycle_id) do
    kind = fetch_string(attrs, :kind) || "message.appended"
    data = Map.get(attrs, :data) || Map.get(attrs, "data") || %{}
    {data, blob_ref} = maybe_offload_payload(cycle_id, kind, data)
    seq = normalize_event_seq(seq) || next_event_seq(cycle_id)

    meta =
      data
      |> stringify_map()
      |> Map.merge(%{
        "kind" => kind,
        "cycle_id" => cycle_id,
        "seq" => seq
      })
      |> maybe_put_metadata(
        "message_id",
        Map.get(attrs, :message_id) || Map.get(attrs, "message_id")
      )
      |> maybe_put_metadata(
        "tool_use_id",
        Map.get(attrs, :tool_use_id) || Map.get(attrs, "tool_use_id")
      )
      |> maybe_put_metadata("blob_ref", blob_ref)
      |> maybe_put_metadata(
        "span_id",
        Map.get(attrs, :span_id) || Map.get(attrs, "span_id")
      )

    parent_id =
      Map.get(attrs, :parent_span_id) || Map.get(attrs, "parent_span_id")

    measurements = event_measurements(meta)

    event =
      Span.execute(agent_event_path(kind), parent_id, meta, measurements)

    if CycleItem.semantic_event_kind?(kind) do
      payload =
        meta
        |> Map.drop(["cycle_id", "seq", "kind"])

      %CycleItem{}
      |> CycleItem.event_changeset(
        %Cycle{id: cycle_id},
        seq,
        kind,
        payload,
        meta["span_id"]
      )
      |> Repo.insert!()
    end

    event
  end

  @spec merge_cycle_usage(Cycle.t(), map() | nil) :: Cycle.t()
  def merge_cycle_usage(%Cycle{} = cycle, usage) when is_map(usage) do
    usage = stringify_map(usage)
    aggregate = merge_usage_maps(cycle.usage || %{}, usage)

    cost_usd =
      case estimate_usage_cost_usd(usage, cycle.model) do
        increment when is_number(increment) ->
          (cycle.cost_usd || 0.0) + increment

        nil ->
          nil
      end

    update_cycle(cycle, %{usage: aggregate, cost_usd: cost_usd})
  end

  def merge_cycle_usage(%Cycle{} = cycle, _usage), do: cycle

  @spec describe_cycle_stop(Cycle.t() | String.t()) :: String.t() | nil
  def describe_cycle_stop(%Cycle{id: cycle_id}),
    do: describe_cycle_stop(cycle_id)

  def describe_cycle_stop(cycle_id) when is_binary(cycle_id) do
    cycle = Repo.get(Cycle, cycle_id)

    outcome =
      Repo.one(
        from(i in CycleItem,
          where:
            i.cycle_id == ^cycle_id and
              i.item_kind == "control.outcome",
          order_by: [desc: i.seq],
          limit: 1,
          select: i.payload
        )
      )

    cond do
      is_map(outcome) ->
        describe_control_outcome(outcome)

      cycle && cycle.status == :failed && is_binary(cycle.error) &&
          cycle.error != "" ->
        cycle.error

      cycle && cycle.status == :cancelled ->
        "cycle cancelled"

      true ->
        nil
    end
  end

  @doc "Load a cycle's semantic items in sequence order."
  @spec list_items(Cycle.t() | String.t()) :: [CycleItem.t()]
  def list_items(%Cycle{id: cycle_id}), do: list_items(cycle_id)

  def list_items(cycle_id) when is_binary(cycle_id) do
    Repo.all(
      from(i in CycleItem,
        where: i.cycle_id == ^cycle_id,
        order_by: [asc: i.seq, asc: i.inserted_at]
      ),
      log: false
    )
  end

  @doc "Load a cycle's messages in sequence order."
  @spec list_messages(Cycle.t() | String.t()) :: [Message.t()]
  def list_messages(cycle_or_id) do
    cycle_or_id
    |> list_items()
    |> Enum.filter(&CycleItem.message_kind?(&1.item_kind))
    |> Enum.map(&CycleItem.to_message/1)
  end

  @doc "Get the text of the last agent message in a cycle."
  @spec latest_agent_text(Cycle.t()) :: String.t() | nil
  def latest_agent_text(%Cycle{} = cycle) do
    cycle
    |> list_messages()
    |> Enum.filter(&(&1.role == :agent))
    |> List.last()
    |> case do
      nil -> nil
      message -> Message.extract_text(message)
    end
  end

  @doc """
  Extract a trace of tool calls and results from a cycle's API messages.

  Returns a list of `%{kind: :call, tool: name, input_json: json}` and
  `%{kind: :return, text: text}` entries, filtering out `send_message` calls.
  """
  @spec cycle_trace(String.t()) :: [map()]
  def cycle_trace(cycle_id) when is_binary(cycle_id) do
    cycle_traces([cycle_id])
    |> Map.get(cycle_id, [])
  end

  @doc false
  @spec cycle_traces([String.t()]) :: %{optional(String.t()) => [map()]}
  def cycle_traces(cycle_ids) when is_list(cycle_ids) do
    cycle_traces_from_items(cycle_ids)
  end

  @doc "Build structured per-cycle tool traces from ordered cycle items."
  @spec cycle_traces_from_items([String.t()]) :: %{
          optional(String.t()) => [map()]
        }
  def cycle_traces_from_items(cycle_ids) when is_list(cycle_ids) do
    cycle_ids = normalize_cycle_ids(cycle_ids)

    if cycle_ids == [] do
      %{}
    else
      items =
        Repo.all(
          from(i in CycleItem,
            where: i.cycle_id in ^cycle_ids and i.item_kind == "tool.result",
            order_by: [asc: i.cycle_id, asc: i.seq, asc: i.inserted_at]
          ),
          log: false
        )

      base = Map.new(cycle_ids, &{&1, []})

      items
      |> Enum.reduce(base, fn item, acc ->
        cycle_id = item.cycle_id
        entries = Map.get(acc, cycle_id, [])

        case trace_entries_for_event(item.payload) do
          [] -> acc
          new_entries -> Map.put(acc, cycle_id, entries ++ new_entries)
        end
      end)
    end
  end

  defp trace_entries_for_event(%{"tool_name" => "send_message"}), do: []

  defp trace_entries_for_event(%{"tool_name" => tool_name} = meta)
       when is_binary(tool_name) do
    input = meta["input"] || %{}

    call_entry = %{
      kind: :call,
      tool: tool_name,
      input: input,
      narration: ToolDescription.text_from_input(input)
    }

    [call_entry | return_entries(meta)]
  end

  defp trace_entries_for_event(_), do: []

  defp return_entries(%{"result" => result, "result_type" => result_type}) do
    case decode_event_result(result) do
      {:blocks, blocks} ->
        [%{kind: :return, outcome: {:ok, blocks}}]

      {:error, message} ->
        [%{kind: :return, outcome: {:error, message}}]

      {:await, %{"kind" => "failure_intervention"} = data} ->
        [%{kind: :intervention, data: data}]

      {:await, data} ->
        [%{kind: :return, outcome: {:await, data}}]

      {:yield, reason} ->
        [%{kind: :return, outcome: {:yield, reason}}]

      {:string, text} when is_binary(text) ->
        # Legacy: an `<output …>…</output>` pseudo-XML string, or a
        # failure-report text, or a plain string. Classify interventions
        # by the leading "Failure report" marker; everything else is
        # a return.
        if result_type in ["error", :error] and failure_report?(text) do
          [%{kind: :intervention, text: text}]
        else
          [%{kind: :return, outcome: {:ok, text}}]
        end

      {:other, value} ->
        [%{kind: :return, outcome: {:ok, value}}]
    end
  end

  defp return_entries(_), do: []

  # Legacy: events from before the block refactor stored results as a
  # `%Froth.Context.Frame{}`-shaped map. Convert to a synthetic one-block
  # list so past cycles render through the same Block components.
  defp decode_event_result(%{"shape" => "frame"} = map) do
    {:blocks, [frame_map_to_block(map)]}
  end

  defp decode_event_result(%{"blocks" => block_maps})
       when is_list(block_maps) do
    blocks =
      block_maps
      |> Enum.map(&Froth.Context.Block.from_map/1)
      |> Enum.reject(&is_nil/1)

    {:blocks, blocks}
  end

  defp decode_event_result(%{"error" => message}), do: {:error, message}
  defp decode_event_result(%{"await" => data}), do: {:await, data}
  defp decode_event_result(%{"yield" => reason}), do: {:yield, reason}
  defp decode_event_result(value) when is_binary(value), do: {:string, value}
  defp decode_event_result(value), do: {:other, value}

  defp frame_map_to_block(%{"shape" => "frame"} = map) do
    frame_attrs = Map.get(map, "attrs", %{}) || %{}

    user_attrs =
      Enum.map(frame_attrs, fn {k, v} -> {String.to_atom(to_string(k)), v} end)

    kind = Map.get(map, "kind") || "output"
    size = Map.get(map, "size")
    lines = Map.get(map, "lines")
    blob_id = Map.get(map, "blob_id")
    head = Map.get(map, "head") || []
    tail = Map.get(map, "tail") || []
    omitted = Map.get(map, "omitted") || 0
    inline_body = Map.get(map, "inline_body")

    attrs =
      [kind: kind]
      |> Kernel.++(user_attrs)
      |> maybe_put_attr(:size, size)
      |> maybe_put_attr(:lines, lines)
      |> maybe_put_attr(:blob, blob_id)
      |> maybe_put_attr(:head, head != [] && head)
      |> maybe_put_attr(:tail, tail != [] && tail)
      |> maybe_put_attr(:omitted, omitted > 0 && omitted)

    Froth.Context.Block.new(attrs, inline_body)
  end

  defp maybe_put_attr(attrs, _k, nil), do: attrs
  defp maybe_put_attr(attrs, _k, false), do: attrs
  defp maybe_put_attr(attrs, _k, ""), do: attrs
  defp maybe_put_attr(attrs, _k, []), do: attrs
  defp maybe_put_attr(attrs, k, v), do: Keyword.put(attrs, k, v)

  defp failure_report?(text) when is_binary(text) do
    trimmed = String.trim_leading(text)
    String.starts_with?(trimmed, "Failure report")
  end

  defp failure_report?(_), do: false

  defp normalize_cycle_ids(cycle_ids) do
    cycle_ids
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  @doc false
  @spec next_event_seq(Cycle.t()) :: non_neg_integer()
  def next_event_seq(%Cycle{id: cycle_id}) when is_binary(cycle_id),
    do: next_event_seq(cycle_id)

  @doc false
  @spec next_event_seq(String.t()) :: non_neg_integer()
  def next_event_seq(cycle_id) when is_binary(cycle_id) do
    Repo.one(
      from(e in Event,
        where:
          like(e.event, "froth.agent.%") and
            fragment("?->>'cycle_id' = ?", e.metadata, ^cycle_id),
        select:
          fragment("COALESCE(MAX((?->>'seq')::bigint), -1) + 1", e.metadata)
      )
    )
    |> case do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _ -> 0
    end
  end

  @doc "Append an ordered message item to a cycle and broadcast it."
  @spec append_message(Cycle.t(), :user | :agent, term()) :: Message.t()
  def append_message(%Cycle{} = cycle, role, content) do
    append_message(cycle, role, content, nil, nil)
  end

  @spec append_message(
          Cycle.t(),
          :user | :agent,
          term(),
          map() | nil
        ) ::
          Message.t()
  def append_message(%Cycle{} = cycle, role, content, metadata)
      when is_map(metadata) or is_nil(metadata) do
    append_message(cycle, role, content, metadata, nil)
  end

  @spec append_message(
          Cycle.t(),
          :user | :agent,
          term(),
          map() | nil,
          integer() | nil
        ) ::
          Message.t()
  def append_message(%Cycle{} = cycle, role, content, metadata, seq)
      when (is_map(metadata) or is_nil(metadata)) and
             (is_integer(seq) or is_nil(seq)) do
    seq = seq || next_event_seq(cycle)

    item =
      %CycleItem{}
      |> CycleItem.message_changeset(
        cycle,
        seq,
        role,
        content,
        metadata
      )
      |> Repo.insert!()

    message = CycleItem.to_message(item)

    _event =
      append_event(
        cycle,
        %{
          kind: "message.appended",
          message_id: item.id,
          data: message_event_data(message)
        },
        seq
      )

    Froth.broadcast("cycle:#{cycle.id}", {:message, message})

    message
  end

  defp initial_cycle_attrs(%Config{} = config) do
    {provider, provider_module} = resolve_provider_details(config)
    system_prompt = config.system || ""
    system_prompt_hash = hash_binary(system_prompt)

    system_prompt_ref =
      maybe_store_system_prompt(system_prompt, system_prompt_hash)

    toolset_hash = hash_value(config.tools || [])

    %{
      status: :queued,
      provider: provider,
      model: config.model,
      parent_span_id: config.parent_span_id,
      config: %{
        "provider" => provider,
        "provider_module" => provider_module,
        "model" => config.model,
        "thinking" => stringify_map(config.thinking || %{}),
        "effort" => config.effort,
        "tool_timeout_ms" => config.tool_timeout_ms,
        "tool_count" => length(config.tools || []),
        "tool_specs" => safe_json(config.tools || []),
        "context" => stringify_map(config.context || %{}),
        "system_prompt_hash" => system_prompt_hash,
        "system_prompt_ref" => system_prompt_ref
      },
      system_prompt_hash: system_prompt_hash,
      system_prompt_ref: system_prompt_ref,
      toolset_hash: toolset_hash,
      usage: %{},
      cost_usd: 0.0
    }
  end

  defp normalize_cycle_attrs(attrs) do
    attrs
    |> Enum.reduce(%{}, fn
      {:error, value}, acc ->
        Map.put(acc, :error, error_string(value))

      {"error", value}, acc ->
        Map.put(acc, :error, error_string(value))

      {key, value}, acc when key in [:config, "config"] and is_map(value) ->
        Map.put(acc, :config, stringify_map(value))

      {key, value}, acc when key in [:usage, "usage"] and is_map(value) ->
        Map.put(acc, :usage, stringify_map(value))

      {key, value}, acc when is_binary(key) ->
        Map.put(acc, String.to_existing_atom(key), value)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  rescue
    ArgumentError ->
      attrs
      |> Enum.reduce(%{}, fn
        {"config", value}, acc when is_map(value) ->
          Map.put(acc, :config, stringify_map(value))

        {"usage", value}, acc when is_map(value) ->
          Map.put(acc, :usage, stringify_map(value))

        {"error", value}, acc ->
          Map.put(acc, :error, error_string(value))

        {key, value}, acc when is_atom(key) ->
          Map.put(acc, key, value)

        {_key, _value}, acc ->
          acc
      end)
  end

  defp maybe_offload_payload(_cycle_id, _kind, nil), do: {%{}, nil}

  defp maybe_offload_payload(cycle_id, kind, data) do
    normalized = safe_json(data)
    blob? = contains_blob?(normalized)

    case Jason.encode(normalized) do
      {:ok, encoded}
      when byte_size(encoded) > @payload_blob_threshold or blob? ->
        preview = summarize_payload(normalized)

        case ObjectStore.put_bytes(event_blob_key(cycle_id, kind), encoded,
               content_type: "application/json"
             ) do
          {:ok, stored} -> {preview, stored.key}
          {:error, _reason} -> {preview, nil}
        end

      _ ->
        {normalized, nil}
    end
  end

  defp normalize_event_seq(value) when is_integer(value) and value >= 0,
    do: value

  defp normalize_event_seq(value) when is_float(value) and value >= 0,
    do: trunc(value)

  defp normalize_event_seq(_value), do: nil

  defp maybe_store_system_prompt("", _hash), do: nil

  defp maybe_store_system_prompt(system_prompt, hash)
       when is_binary(system_prompt) and
              byte_size(system_prompt) > @payload_blob_threshold do
    case ObjectStore.put_bytes(
           "agent/system-prompts/#{hash}.txt",
           system_prompt,
           content_type: "text/plain"
         ) do
      {:ok, stored} -> stored.key
      {:error, _reason} -> nil
    end
  end

  defp maybe_store_system_prompt(_system_prompt, _hash), do: nil

  defp message_event_data(%Message{} = message) do
    %{
      "role" => to_string(message.role),
      "content_kind" => message_content_kind(message.content),
      "text_preview" =>
        truncate(Message.extract_text(message), @preview_string_limit),
      "metadata" => summarize_payload(message.metadata || %{})
    }
  end

  defp message_content_kind(content) when is_list(content),
    do: "#{length(content)} blocks"

  defp message_content_kind(content) when is_binary(content), do: "text"
  defp message_content_kind(nil), do: "empty"
  defp message_content_kind(_content), do: "value"

  defp resolve_provider_details(%Config{} = config) do
    provider =
      cond do
        is_atom(config.provider) and
            config.provider in [:anthropic, :openai, :grok, :gemini] ->
          Atom.to_string(config.provider)

        is_binary(config.provider) and String.trim(config.provider) != "" ->
          normalize_provider_name(config.provider)

        true ->
          config.model
          |> LLM.provider_name_for_model()
          |> stringify_atom()
      end

    resolved =
      case LLM.resolve_provider_name(config.provider, config.model) do
        nil -> nil
        name -> Atom.to_string(name)
      end

    {provider || resolved, resolved}
  end

  defp normalize_provider_name(provider) when is_binary(provider) do
    trimmed = String.trim(provider)

    cond do
      trimmed == "" -> nil
      String.downcase(trimmed) in ["claude", "anthropic"] -> "anthropic"
      String.downcase(trimmed) in ["gpt", "openai"] -> "openai"
      String.downcase(trimmed) in ["grok", "xai"] -> "grok"
      String.downcase(trimmed) in ["gemini", "google"] -> "gemini"
      true -> trimmed
    end
  end

  defp safe_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), safe_value(v)} end)
  end

  defp safe_json(list) when is_list(list), do: Enum.map(list, &safe_value/1)
  defp safe_json(nil), do: %{}
  defp safe_json(other), do: %{"value" => safe_value(other)}

  defp safe_value(nil), do: nil

  defp safe_value(v) when is_binary(v) do
    if json_text_safe?(v) do
      v
    else
      %{
        "bytes" => byte_size(v),
        "sha256" => hash_binary(v),
        "encoding" => "binary"
      }
    end
  end

  defp safe_value(v) when is_number(v), do: v
  defp safe_value(v) when is_boolean(v), do: v
  defp safe_value(v) when is_atom(v), do: to_string(v)
  defp safe_value(v) when is_list(v), do: Enum.map(v, &safe_value/1)
  defp safe_value(%{} = v), do: safe_json(v)
  defp safe_value(v), do: inspect(v)

  defp json_text_safe?(value) when is_binary(value) do
    String.valid?(value) and not String.contains?(value, <<0>>)
  end

  defp json_text_safe?(_value), do: false

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)

  defp stringify_value(value) when is_list(value),
    do: Enum.map(value, &stringify_value/1)

  defp stringify_value(nil), do: nil
  defp stringify_value(value) when is_boolean(value), do: value
  defp stringify_value(value) when is_atom(value), do: to_string(value)
  defp stringify_value(value), do: value

  defp summarize_payload(nil), do: %{}

  defp summarize_payload(value) when is_binary(value) do
    truncate(value, @preview_string_limit)
  end

  defp summarize_payload(value) when is_list(value) do
    preview =
      value
      |> Enum.take(@preview_list_limit)
      |> Enum.map(&summarize_payload/1)

    if length(value) > @preview_list_limit do
      preview ++ [%{"truncated_items" => length(value) - @preview_list_limit}]
    else
      preview
    end
  end

  defp summarize_payload(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} ->
      {to_string(key), summarize_entry(key, item)}
    end)
    |> Map.new()
  end

  defp summarize_payload(value), do: safe_value(value)

  defp summarize_entry(key, value)
       when key in ["data", :data] and is_binary(value) and
              byte_size(value) > 128 do
    %{
      "bytes" => byte_size(value),
      "sha256" => hash_binary(value),
      "stored" => true
    }
  end

  defp summarize_entry(_key, value), do: summarize_payload(value)

  defp contains_blob?(value) when is_binary(value),
    do: byte_size(value) > @preview_string_limit * 2

  defp contains_blob?(value) when is_list(value) do
    Enum.any?(value, &contains_blob?/1)
  end

  defp contains_blob?(value) when is_map(value) do
    Enum.any?(value, fn
      {key, inner}
      when key in ["data", :data] and is_binary(inner) and
             byte_size(inner) > 128 ->
        true

      {_key, inner} ->
        contains_blob?(inner)
    end)
  end

  defp contains_blob?(_value), do: false

  defp event_blob_key(cycle_id, kind) do
    safe_kind = String.replace(kind, ".", "-")
    suffix = System.unique_integer([:positive])
    "agent/cycles/#{cycle_id}/events/#{safe_kind}-#{suffix}.json"
  end

  defp truncate(nil, _limit), do: nil
  defp truncate(value, _limit), do: value

  defp stringify_or_nil(nil), do: nil
  defp stringify_or_nil(value), do: to_string(value)

  defp maybe_put_metadata(metadata, _key, nil), do: metadata

  defp maybe_put_metadata(metadata, key, value) when is_map(metadata) do
    Map.put(metadata, key, stringify_or_nil(value))
  end

  defp event_measurements(%{"duration_ms" => duration_ms})
       when is_number(duration_ms) do
    %{"duration_ms" => duration_ms}
  end

  defp event_measurements(_metadata), do: %{}

  defp agent_event_path(kind) when is_binary(kind) do
    [:froth, :agent | String.split(kind, ".") |> Enum.map(&String.to_atom/1)]
  end

  defp stringify_atom(nil), do: nil
  defp stringify_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_atom(value) when is_binary(value), do: value

  defp hash_binary(binary) when is_binary(binary) do
    :sha256
    |> :crypto.hash(binary)
    |> Base.encode16(case: :lower)
  end

  defp hash_value(value) do
    value
    |> canonical_term()
    |> :erlang.term_to_binary()
    |> hash_binary()
  end

  defp canonical_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, inner} ->
      {to_string(key), canonical_term(inner)}
    end)
    |> Enum.sort()
  end

  defp canonical_term(value) when is_list(value),
    do: Enum.map(value, &canonical_term/1)

  defp canonical_term(value), do: value

  defp merge_usage_maps(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      cond do
        is_map(left_value) and is_map(right_value) ->
          merge_usage_maps(left_value, right_value)

        is_integer(left_value) and is_integer(right_value) ->
          left_value + right_value

        true ->
          right_value
      end
    end)
  end

  defp merge_usage_maps(_left, right), do: right

  defp estimate_usage_cost_usd(usage, model)
       when is_map(usage) and is_binary(model) do
    case model_pricing_rates(model, usage) do
      nil ->
        nil

      rates ->
        input_tokens = usage_int(usage["input_tokens"])
        output_tokens = usage_int(usage["output_tokens"])

        cache_creation_tokens =
          usage_int(usage["cache_creation_input_tokens"])

        cache_read_tokens = usage_int(usage["cache_read_input_tokens"])

        (input_tokens * rates.input +
           output_tokens * rates.output +
           cache_creation_tokens * rates.cache_write +
           cache_read_tokens * rates.cache_read) / 1_000_000
    end
  end

  defp estimate_usage_cost_usd(_usage, _model), do: nil

  defp usage_int(value) when is_integer(value) and value >= 0, do: value

  defp usage_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp usage_int(_value), do: 0

  # Source-of-truth rates (USD / MTok):
  # https://claude.com/pricing and https://developers.openai.com/api/docs/pricing
  defp model_pricing_rates(model, usage)
       when is_binary(model) and is_map(usage) do
    downcased = String.downcase(model)

    cond do
      String.contains?(downcased, "gpt-5.6-luna") ->
        total_input_tokens =
          usage_int(usage["input_tokens"]) +
            usage_int(usage["cache_creation_input_tokens"]) +
            usage_int(usage["cache_read_input_tokens"])

        if total_input_tokens > 272_000 do
          %{input: 0.4, output: 1.8, cache_write: 0.5, cache_read: 0.04}
        else
          %{input: 0.2, output: 1.2, cache_write: 0.25, cache_read: 0.02}
        end

      String.contains?(downcased, "opus-4-7") ->
        %{input: 5.0, output: 25.0, cache_write: 6.25, cache_read: 0.5}

      String.contains?(downcased, "opus-4-6") ->
        %{input: 5.0, output: 25.0, cache_write: 6.25, cache_read: 0.5}

      String.contains?(downcased, "sonnet-4-6") ->
        %{input: 3.0, output: 15.0, cache_write: 3.75, cache_read: 0.3}

      String.contains?(downcased, "haiku-4-5") ->
        %{input: 1.0, output: 5.0, cache_write: 1.25, cache_read: 0.1}

      true ->
        nil
    end
  end

  defp model_pricing_rates(_model, _usage), do: nil

  defp describe_control_outcome(%{"outcome" => "yield", "reason" => reason})
       when is_binary(reason) and reason != "" do
    "cycle yielded: #{reason}"
  end

  defp describe_control_outcome(%{
         "outcome" => "assistant_stopped_without_reply",
         "detail" => detail
       })
       when is_binary(detail) and detail != "" do
    detail
  end

  defp describe_control_outcome(%{
         "outcome" => "waiting_on_subscription",
         "reason" => reason
       })
       when is_binary(reason) and reason != "" do
    reason
  end

  defp describe_control_outcome(%{
         "outcome" => "tool_error",
         "error" => error
       })
       when is_binary(error) and error != "" do
    error
  end

  defp describe_control_outcome(%{
         "outcome" => "cycle_error",
         "error" => error
       })
       when is_binary(error) and error != "" do
    error
  end

  defp describe_control_outcome(%{"outcome" => outcome})
       when is_binary(outcome), do: outcome

  defp describe_control_outcome(_outcome), do: nil

  defp error_string(value) when is_binary(value), do: value
  defp error_string(nil), do: nil
  defp error_string(value), do: inspect(value)

  defp fetch_string(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end
end
