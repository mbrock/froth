defmodule Froth.Agent do
  @moduledoc """
  Context for agentic cycles: data access and the public `run` entry point.
  """

  import Ecto.Query

  alias Froth.Agent.{Config, Cycle, Message, ToolDescription, Worker}
  alias Froth.{Event, LLM, ObjectStore, Repo}

  @payload_blob_threshold 8_000
  @preview_string_limit 320
  @preview_list_limit 8

  @spec run(Message.t() | Cycle.t(), Config.t()) :: {Cycle.t(), Enumerable.t()}
  def run(%Message{id: id} = message, %Config{} = config) when not is_nil(id) do
    message
    |> begin_cycle(config)
    |> run(config)
  end

  def run(%Cycle{id: id} = cycle, %Config{} = config) when not is_nil(id) do
    {cycle, cycle_stream(cycle, config)}
  end

  @spec begin_cycle(Message.t(), Config.t()) :: Cycle.t()
  def begin_cycle(%Message{id: id} = message, %Config{} = config) when not is_nil(id) do
    cycle =
      %Cycle{}
      |> Cycle.changeset(cycle_snapshot_attrs(config))
      |> Repo.insert!()

    _event =
      append_event(
        cycle,
        %{
          kind: "message.appended",
          head_id: message.id,
          message_id: message.id,
          data: message_event_data(message)
        },
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

          {:event, event, msg} ->
            {[{:event, event, msg}], {pid, ref}}

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
  def cycle_snapshot_attrs(%Config{} = config), do: initial_cycle_attrs(config)

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

    metadata =
      data
      |> stringify_map()
      |> Map.merge(%{
        "kind" => kind,
        "cycle_id" => cycle_id,
        "seq" => seq
      })
      |> maybe_put_metadata("head_id", Map.get(attrs, :head_id) || Map.get(attrs, "head_id"))
      |> maybe_put_metadata(
        "message_id",
        Map.get(attrs, :message_id) || Map.get(attrs, "message_id")
      )
      |> maybe_put_metadata(
        "tool_use_id",
        Map.get(attrs, :tool_use_id) || Map.get(attrs, "tool_use_id")
      )
      |> maybe_put_metadata("blob_ref", blob_ref)

    %Event{}
    |> Event.changeset(%{
      event: agent_event_name(kind),
      span_id: stringify_or_nil(Map.get(attrs, :span_id) || Map.get(attrs, "span_id")),
      parent_id:
        stringify_or_nil(Map.get(attrs, :parent_span_id) || Map.get(attrs, "parent_span_id")),
      measurements: event_measurements(metadata),
      metadata: metadata
    })
    |> Repo.insert!()
  end

  @spec merge_cycle_usage(Cycle.t(), map() | nil) :: Cycle.t()
  def merge_cycle_usage(%Cycle{} = cycle, usage) when is_map(usage) do
    aggregate = merge_usage_maps(cycle.usage || %{}, stringify_map(usage))
    cost_usd = estimate_usage_cost_usd(aggregate, cycle.model)
    update_cycle(cycle, %{usage: aggregate, cost_usd: cost_usd})
  end

  def merge_cycle_usage(%Cycle{} = cycle, _usage), do: cycle

  @spec describe_cycle_stop(Cycle.t() | String.t()) :: String.t() | nil
  def describe_cycle_stop(%Cycle{id: cycle_id}), do: describe_cycle_stop(cycle_id)

  def describe_cycle_stop(cycle_id) when is_binary(cycle_id) do
    cycle = Repo.get(Cycle, cycle_id)

    outcome =
      Repo.one(
        from(e in Event,
          where:
            e.event == "froth.agent.control.outcome" and
              fragment("?->>'cycle_id' = ?", e.metadata, ^cycle_id),
          order_by: [desc: fragment("COALESCE((?->>'seq')::bigint, 0)", e.metadata)],
          limit: 1,
          select: e.metadata
        )
      )

    cond do
      is_map(outcome) ->
        describe_control_outcome(outcome)

      cycle && cycle.status == :failed && is_binary(cycle.error) && cycle.error != "" ->
        cycle.error

      cycle && cycle.status == :cancelled ->
        "cycle cancelled"

      true ->
        nil
    end
  end

  @doc "Return the current head message ID for a cycle."
  @spec latest_head_id(Cycle.t()) :: String.t() | nil
  def latest_head_id(%Cycle{id: cycle_id}) do
    latest_head_ids([cycle_id])
    |> Map.get(cycle_id)
  end

  @doc "Return the current head message IDs for cycles."
  @spec latest_head_ids([String.t()]) :: %{optional(String.t()) => String.t()}
  def latest_head_ids(cycle_ids) when is_list(cycle_ids) do
    cycle_ids
    |> normalize_cycle_ids()
    |> case do
      [] ->
        %{}

      cycle_ids ->
        Repo.all(
          from(e in Event,
            where:
              e.event == "froth.agent.message.appended" and
                fragment(
                  "?->>'cycle_id' = ANY(?)",
                  e.metadata,
                  type(^cycle_ids, {:array, :string})
                ) and
                not is_nil(fragment("?->>'head_id'", e.metadata)),
            distinct: fragment("?->>'cycle_id'", e.metadata),
            order_by: [
              asc: fragment("?->>'cycle_id'", e.metadata),
              desc: fragment("COALESCE((?->>'seq')::bigint, 0)", e.metadata)
            ],
            select: %{
              cycle_id: fragment("?->>'cycle_id'", e.metadata),
              head_id: fragment("?->>'head_id'", e.metadata)
            }
          )
        )
        |> Map.new(fn %{cycle_id: cycle_id, head_id: head_id} -> {cycle_id, head_id} end)
    end
  end

  @doc "Load the full message chain ending at `head_id`, oldest first."
  @spec load_messages(String.t() | nil) :: [Message.t()]
  def load_messages(nil), do: []

  def load_messages(head_id) do
    seed = Message |> where([m], m.id == ^head_id)
    recurse = Message |> join(:inner, [m], c in "chain", on: m.id == c.parent_id)
    chain = seed |> union_all(^recurse)

    {"chain", Message}
    |> recursive_ctes(true)
    |> with_cte("chain", as: ^chain)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc "Get the text of the last agent message in a cycle."
  @spec latest_agent_text(Cycle.t()) :: String.t() | nil
  def latest_agent_text(%Cycle{} = cycle) do
    case latest_head_id(cycle) do
      nil ->
        nil

      head_id ->
        head_id
        |> load_messages()
        |> Enum.filter(&(&1.role == :agent))
        |> List.last()
        |> case do
          nil -> nil
          message -> Message.extract_text(message)
        end
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
    latest_head_ids(cycle_ids)
    |> Map.new(fn {cycle_id, head_id} ->
      entries =
        head_id
        |> load_messages()
        |> Enum.map(&Message.to_api/1)
        |> extract_trace_entries()

      {cycle_id, entries}
    end)
  end

  @doc false
  def extract_trace_entries(api_messages) when is_list(api_messages) do
    Enum.flat_map(api_messages, fn
      %{"role" => "assistant", "content" => content} when is_list(content) ->
        Enum.flat_map(content, fn
          %{"type" => "tool_use", "name" => "send_message"} ->
            []

          %{"type" => type, "input" => input} = block
          when type in ["tool_use", "mcp_tool_use"] ->
            narration = ToolDescription.text_from_input(input)
            tool = format_trace_tool_name(block)

            [
              %{
                kind: :call,
                tool: tool,
                input: input,
                input_json: encode_tool_input(input),
                narration: narration
              }
            ]

          _ ->
            []
        end)

      %{"role" => "user", "content" => content} when is_list(content) ->
        Enum.flat_map(content, fn
          %{"type" => type, "content" => result_content, "tool_use_id" => _id} = block
          when type in ["tool_result", "mcp_tool_result"] ->
            text = tool_result_text(result_content)
            is_error? = block["is_error"] == true

            cond do
              String.trim(text) == "sent" ->
                []

              # A failure-intervention resumption looks like an errored
              # tool_result whose content starts with the human-readable
              # failure report. Classify it as its own kind so the trace
              # doesn't conflate "tool returned X" with "intervention
              # replaced the tool's output with X".
              is_error? and failure_report?(text) ->
                [%{kind: :intervention, text: text}]

              true ->
                # Text is passed verbatim; BotContextHTML.cycle_return
                # folds it through Froth.Blobs.Render.trace_return so
                # output-frame tool returns pass through unchanged and
                # legacy long strings get head/tail with an explicit note.
                [%{kind: :return, text: text}]
            end

          _ ->
            []
        end)

      _ ->
        []
    end)
  end

  def extract_trace_entries(_), do: []

  defp failure_report?(text) when is_binary(text) do
    trimmed = String.trim_leading(text)
    String.starts_with?(trimmed, "Failure report")
  end

  defp failure_report?(_), do: false

  defp format_trace_tool_name(%{"server_name" => server_name, "name" => name})
       when is_binary(server_name) and server_name != "" and is_binary(name) do
    "#{server_name}/#{name}"
  end

  defp format_trace_tool_name(%{"name" => name}) when is_binary(name), do: name

  defp normalize_cycle_ids(cycle_ids) do
    cycle_ids
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  @doc false
  @spec next_event_seq(Cycle.t()) :: non_neg_integer()
  def next_event_seq(%Cycle{id: cycle_id}) when is_binary(cycle_id), do: next_event_seq(cycle_id)

  @doc false
  @spec next_event_seq(String.t()) :: non_neg_integer()
  def next_event_seq(cycle_id) when is_binary(cycle_id) do
    Repo.one(
      from(e in Event,
        where:
          like(e.event, "froth.agent.%") and
            fragment("?->>'cycle_id' = ?", e.metadata, ^cycle_id),
        select: fragment("COALESCE(MAX((?->>'seq')::bigint), -1) + 1", e.metadata)
      )
    )
    |> case do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _ -> 0
    end
  end

  @doc "Append a message to the cycle, record an event, broadcast, return {message, updated_head_id}."
  @spec append_message(Cycle.t(), String.t() | nil, :user | :agent, term()) ::
          {Message.t(), String.t()}
  def append_message(%Cycle{} = cycle, head_id, role, content) do
    append_message(cycle, head_id, role, content, nil, nil)
  end

  @spec append_message(Cycle.t(), String.t() | nil, :user | :agent, term(), map() | nil) ::
          {Message.t(), String.t()}
  def append_message(%Cycle{} = cycle, head_id, role, content, metadata)
      when is_map(metadata) or is_nil(metadata) do
    append_message(cycle, head_id, role, content, metadata, nil)
  end

  @spec append_message(
          Cycle.t(),
          String.t() | nil,
          :user | :agent,
          term(),
          map() | nil,
          integer() | nil
        ) ::
          {Message.t(), String.t()}
  def append_message(%Cycle{} = cycle, head_id, role, content, metadata, seq)
      when (is_map(metadata) or is_nil(metadata)) and (is_integer(seq) or is_nil(seq)) do
    saved =
      Repo.insert!(%Message{
        role: role,
        content: Message.wrap(content),
        metadata: metadata,
        parent_id: head_id
      })

    event =
      append_event(
        cycle,
        %{
          kind: "message.appended",
          head_id: saved.id,
          message_id: saved.id,
          data: message_event_data(saved)
        },
        seq
      )

    Froth.broadcast("cycle:#{cycle.id}", {:event, event, saved})

    {saved, saved.id}
  end

  defp initial_cycle_attrs(%Config{} = config) do
    {provider, provider_module} = resolve_provider_details(config)
    system_prompt = config.system || ""
    system_prompt_hash = hash_binary(system_prompt)
    system_prompt_ref = maybe_store_system_prompt(system_prompt, system_prompt_hash)
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
        {"config", value}, acc when is_map(value) -> Map.put(acc, :config, stringify_map(value))
        {"usage", value}, acc when is_map(value) -> Map.put(acc, :usage, stringify_map(value))
        {"error", value}, acc -> Map.put(acc, :error, error_string(value))
        {key, value}, acc when is_atom(key) -> Map.put(acc, key, value)
        {_key, _value}, acc -> acc
      end)
  end

  defp maybe_offload_payload(_cycle_id, _kind, nil), do: {%{}, nil}

  defp maybe_offload_payload(cycle_id, kind, data) do
    normalized = safe_json(data)
    blob? = contains_blob?(normalized)

    case Jason.encode(normalized) do
      {:ok, encoded} when byte_size(encoded) > @payload_blob_threshold or blob? ->
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

  defp normalize_event_seq(value) when is_integer(value) and value >= 0, do: value
  defp normalize_event_seq(value) when is_float(value) and value >= 0, do: trunc(value)
  defp normalize_event_seq(_value), do: nil

  defp maybe_store_system_prompt("", _hash), do: nil

  defp maybe_store_system_prompt(system_prompt, hash)
       when is_binary(system_prompt) and byte_size(system_prompt) > @payload_blob_threshold do
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
      "text_preview" => truncate(Message.extract_text(message), @preview_string_limit),
      "metadata" => summarize_payload(message.metadata || %{})
    }
  end

  defp message_content_kind(content) when is_list(content), do: "#{length(content)} blocks"
  defp message_content_kind(content) when is_binary(content), do: "text"
  defp message_content_kind(nil), do: "empty"
  defp message_content_kind(_content), do: "value"

  defp resolve_provider_details(%Config{} = config) do
    provider =
      cond do
        is_atom(config.provider) and config.provider in [:anthropic, :openai, :grok, :gemini] ->
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

  defp encode_tool_input(input) do
    case Jason.encode(input) do
      {:ok, json} -> json
      _ -> inspect(input, limit: 50, printable_limit: 600)
    end
  end

  defp tool_result_text(content) when is_binary(content), do: content

  defp tool_result_text(content) when is_list(content) do
    Enum.map_join(content, "\n", &tool_result_block_text/1)
  end

  defp tool_result_text(content),
    do: inspect(content, limit: 50, printable_limit: 2000)

  defp tool_result_block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp tool_result_block_text(%{"text" => text}) when is_binary(text), do: text
  defp tool_result_block_text(%{"type" => type}) when is_binary(type), do: "[#{type}]"
  defp tool_result_block_text(other), do: inspect(other, limit: 20, printable_limit: 300)

  defp safe_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), safe_value(v)} end)
  end

  defp safe_json(list) when is_list(list), do: Enum.map(list, &safe_value/1)
  defp safe_json(nil), do: %{}
  defp safe_json(other), do: %{"value" => safe_value(other)}

  defp safe_value(v) when is_binary(v), do: v
  defp safe_value(v) when is_number(v), do: v
  defp safe_value(v) when is_boolean(v), do: v
  defp safe_value(v) when is_atom(v), do: to_string(v)
  defp safe_value(v) when is_list(v), do: Enum.map(v, &safe_value/1)
  defp safe_value(%{} = v), do: safe_json(v)
  defp safe_value(v), do: inspect(v)

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_boolean(value), do: value
  defp stringify_value(value) when is_atom(value), do: to_string(value)
  defp stringify_value(value), do: value

  defp summarize_payload(nil), do: %{}

  defp summarize_payload(value) when is_binary(value) do
    truncate(value, @preview_string_limit)
  end

  defp summarize_payload(value) when is_list(value) do
    preview = value |> Enum.take(@preview_list_limit) |> Enum.map(&summarize_payload/1)

    if length(value) > @preview_list_limit do
      preview ++ [%{"truncated_items" => length(value) - @preview_list_limit}]
    else
      preview
    end
  end

  defp summarize_payload(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), summarize_entry(key, item)} end)
    |> Map.new()
  end

  defp summarize_payload(value), do: safe_value(value)

  defp summarize_entry(key, value)
       when key in ["data", :data] and is_binary(value) and byte_size(value) > 128 do
    %{"bytes" => byte_size(value), "sha256" => hash_binary(value), "stored" => true}
  end

  defp summarize_entry(_key, value), do: summarize_payload(value)

  defp contains_blob?(value) when is_binary(value),
    do: byte_size(value) > @preview_string_limit * 2

  defp contains_blob?(value) when is_list(value) do
    Enum.any?(value, &contains_blob?/1)
  end

  defp contains_blob?(value) when is_map(value) do
    Enum.any?(value, fn
      {key, inner} when key in ["data", :data] and is_binary(inner) and byte_size(inner) > 128 ->
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

  defp event_measurements(%{"duration_ms" => duration_ms}) when is_number(duration_ms) do
    %{"duration_ms" => duration_ms}
  end

  defp event_measurements(_metadata), do: %{}

  defp agent_event_name(kind) when is_binary(kind), do: "froth.agent.#{kind}"

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
    |> Enum.map(fn {key, inner} -> {to_string(key), canonical_term(inner)} end)
    |> Enum.sort()
  end

  defp canonical_term(value) when is_list(value), do: Enum.map(value, &canonical_term/1)
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

  defp estimate_usage_cost_usd(usage, model) when is_map(usage) and is_binary(model) do
    case model_pricing_rates(model) do
      nil ->
        nil

      rates ->
        input_tokens = usage_int(usage["input_tokens"])
        output_tokens = usage_int(usage["output_tokens"])
        cache_creation_tokens = usage_int(usage["cache_creation_input_tokens"])
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

  # Source-of-truth rates (USD / MTok) from https://claude.com/pricing.
  # Flat pricing — the 200K-token tier has been retired.
  defp model_pricing_rates(model) when is_binary(model) do
    downcased = String.downcase(model)

    cond do
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

  defp model_pricing_rates(_model), do: nil

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

  defp describe_control_outcome(%{"outcome" => "waiting_on_subscription", "reason" => reason})
       when is_binary(reason) and reason != "" do
    reason
  end

  defp describe_control_outcome(%{"outcome" => "tool_error", "error" => error})
       when is_binary(error) and error != "" do
    error
  end

  defp describe_control_outcome(%{"outcome" => "cycle_error", "error" => error})
       when is_binary(error) and error != "" do
    error
  end

  defp describe_control_outcome(%{"outcome" => outcome}) when is_binary(outcome), do: outcome
  defp describe_control_outcome(_outcome), do: nil

  defp error_string(value) when is_binary(value), do: value
  defp error_string(nil), do: nil
  defp error_string(value), do: inspect(value)

  defp fetch_string(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end
end
