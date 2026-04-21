defmodule Froth.Follow.Timeline do
  @moduledoc false

  alias Froth.Follow.Entry

  @llm_providers ~w[anthropic openai grok gemini codex]

  @type tree_info :: %{
          depth: non_neg_integer(),
          prefix: String.t()
        }

  @type cycle_summary :: %{
          cycle_id: String.t(),
          label: String.t(),
          provider: String.t() | nil,
          model: String.t() | nil,
          status: String.t(),
          status_level: :debug | :info | :warn | :error,
          tool_count: non_neg_integer(),
          llm_count: non_neg_integer(),
          elapsed_ms: integer() | nil,
          active?: boolean()
        }

  @spec tree_map([Entry.t()]) :: %{String.t() => tree_info()}
  def tree_map(entries) do
    span_ids =
      entries
      |> Enum.map(& &1.span_id)
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    {nodes, order} =
      Enum.reduce(entries, {%{}, []}, fn entry, {nodes, order} ->
        key = node_key(entry)
        entry_id = entry_id(entry)
        parent_key = parent_key(entry, span_ids)

        case Map.get(nodes, key) do
          nil ->
            node = %{
              key: key,
              parent_key: parent_key,
              entry_ids: [entry_id]
            }

            {Map.put(nodes, key, node), [key | order]}

          node ->
            parent_key = node.parent_key || parent_key

            node = %{
              node
              | parent_key: parent_key,
                entry_ids: node.entry_ids ++ [entry_id]
            }

            {Map.put(nodes, key, node), order}
        end
      end)

    order = Enum.reverse(order)

    children =
      Enum.reduce(order, %{}, fn key, acc ->
        parent_key = nodes[key].parent_key
        Map.update(acc, parent_key, [key], &[key | &1])
      end)
      |> Map.new(fn {key, values} -> {key, Enum.reverse(values)} end)

    node_info =
      Map.new(order, fn key ->
        ancestors = ancestor_keys(key, nodes)

        {key,
         %{
           depth: length(ancestors),
           ancestors: ancestors,
           last_sibling?: last_sibling?(key, nodes[key].parent_key, children)
         }}
      end)

    Enum.reduce(order, %{}, fn key, acc ->
      node = nodes[key]
      info = Map.fetch!(node_info, key)
      ancestor_prefix = ancestor_prefix(info.ancestors, node_info)
      total = length(node.entry_ids)

      Enum.with_index(node.entry_ids)
      |> Enum.reduce(acc, fn {entry_id, index}, tree ->
        Map.put(tree, entry_id, %{
          depth: info.depth,
          prefix:
            ancestor_prefix <>
              node_marker(info.depth, total, index, info.last_sibling?)
        })
      end)
    end)
  end

  @spec cycle_summaries([Entry.t()]) :: %{String.t() => cycle_summary()}
  def cycle_summaries(entries) do
    entries
    |> Enum.reduce(%{}, fn
      %Entry{cycle_id: nil}, acc ->
        acc

      %Entry{cycle_id: cycle_id} = entry, acc ->
        summary =
          acc
          |> Map.get(cycle_id, new_cycle_summary(cycle_id))
          |> update_cycle_summary(entry)

        Map.put(acc, cycle_id, summary)
    end)
    |> Map.new(fn {cycle_id, summary} ->
      {cycle_id,
       %{
         cycle_id: cycle_id,
         label: truncate_id(cycle_id, 12),
         provider: summary.provider,
         model: summary.model,
         status: summary.status || "running",
         status_level: summary.status_level || :info,
         tool_count: MapSet.size(summary.tool_keys),
         llm_count: MapSet.size(summary.llm_keys),
         elapsed_ms:
           summary.duration_ms ||
             elapsed_ms(
               summary.started_at || summary.first_at,
               summary.last_at
             ),
         active?: not summary.completed?
       }}
    end)
  end

  defp new_cycle_summary(cycle_id) do
    %{
      cycle_id: cycle_id,
      provider: nil,
      model: nil,
      status: nil,
      status_level: nil,
      duration_ms: nil,
      completed?: false,
      first_at: nil,
      started_at: nil,
      last_at: nil,
      tool_keys: MapSet.new(),
      llm_keys: MapSet.new()
    }
  end

  defp update_cycle_summary(summary, %Entry{} = entry) do
    {provider, model} = identity_for_entry(entry)

    summary =
      summary
      |> maybe_put(:provider, provider)
      |> maybe_put(:model, model)
      |> put_first_at(entry.at)
      |> put_started_at(entry)
      |> put_last_at(entry.at)
      |> put_counts(entry)

    case {entry.family, entry.kind} do
      {"cycle", kind}
      when kind in ["stop", "completed", "failed", "cancelled"] ->
        %{
          summary
          | status: entry.summary || humanize(kind),
            status_level: entry.level,
            duration_ms: entry.duration_ms || summary.duration_ms,
            completed?: true
        }

      {"cycle", kind} when kind in ["start", "started"] ->
        %{
          summary
          | status: summary.status || "running",
            status_level: summary.status_level || :info
        }

      _ ->
        summary
    end
  end

  defp put_counts(summary, %Entry{family: "tool", kind: kind} = entry)
       when kind in ["started", "completed", "failed", "timed_out"] do
    key = entry.tool_use_id || entry.span_id || "#{entry.scope}:#{entry.id}"
    %{summary | tool_keys: MapSet.put(summary.tool_keys, key)}
  end

  defp put_counts(summary, %Entry{family: "llm", kind: kind} = entry)
       when kind in ["requested", "start", "request_send"] do
    key = entry.span_id || "#{entry.scope}:#{entry.id}"
    %{summary | llm_keys: MapSet.put(summary.llm_keys, key)}
  end

  defp put_counts(summary, _entry), do: summary

  defp identity_for_entry(%Entry{} = entry) do
    provider =
      entry.metadata["provider"] || provider_from_event(entry.event) ||
        provider_from_scope(entry.scope)

    model = entry.metadata["model"] || model_from_scope(entry.scope)
    {provider, model}
  end

  defp provider_from_event(event) when is_binary(event) do
    case String.split(event, ".") do
      ["froth", provider, "request" | _rest]
      when provider in @llm_providers ->
        provider

      ["froth", "codex" | _rest] ->
        "codex"

      _ ->
        nil
    end
  end

  defp provider_from_event(_), do: nil

  defp provider_from_scope(scope) when is_binary(scope) do
    case String.split(scope, ":", parts: 2) do
      [provider, _model] when provider in @llm_providers -> provider
      _ -> nil
    end
  end

  defp provider_from_scope(_), do: nil

  defp model_from_scope(scope) when is_binary(scope) do
    case String.split(scope, ":", parts: 2) do
      [_provider, model] when model != "" -> model
      _ -> nil
    end
  end

  defp model_from_scope(_), do: nil

  defp put_first_at(summary, nil), do: summary

  defp put_first_at(%{first_at: nil} = summary, at),
    do: %{summary | first_at: at}

  defp put_first_at(summary, _at), do: summary

  defp put_started_at(summary, %Entry{family: "cycle", kind: kind, at: at})
       when kind in ["start", "started"] and not is_nil(at),
       do: %{summary | started_at: summary.started_at || at}

  defp put_started_at(summary, _entry), do: summary

  defp put_last_at(summary, nil), do: summary
  defp put_last_at(summary, at), do: %{summary | last_at: at}

  defp maybe_put(summary, _key, nil), do: summary

  defp maybe_put(summary, key, value),
    do: Map.put(summary, key, Map.get(summary, key) || value)

  defp elapsed_ms(nil, _last_at), do: nil
  defp elapsed_ms(_start_at, nil), do: nil

  defp elapsed_ms(start_at, last_at) do
    max(time_ms(last_at) - time_ms(start_at), 0)
  rescue
    _ -> nil
  end

  defp time_ms(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)

  defp time_ms(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp ancestor_prefix(ancestors, node_info) do
    ancestors
    |> Enum.map(fn ancestor ->
      if Map.fetch!(node_info, ancestor).last_sibling?, do: "  ", else: "│ "
    end)
    |> Enum.join()
  end

  defp node_marker(0, _total, _index, _last_sibling?), do: ""
  defp node_marker(_depth, 1, _index, true), do: "└ "
  defp node_marker(_depth, 1, _index, false), do: "├ "
  defp node_marker(_depth, total, 0, _last_sibling?) when total > 1, do: "├ "

  defp node_marker(_depth, total, index, _last_sibling?)
       when index == total - 1, do: "└ "

  defp node_marker(_depth, _total, _index, _last_sibling?), do: "│ "

  defp last_sibling?(key, parent_key, children) do
    case Map.get(children, parent_key, []) do
      [] -> true
      siblings -> List.last(siblings) == key
    end
  end

  defp ancestor_keys(key, nodes), do: ancestor_keys(key, nodes, MapSet.new())

  defp ancestor_keys(key, nodes, seen) do
    case Map.get(nodes, key) do
      nil ->
        []

      %{parent_key: nil} ->
        []

      %{parent_key: parent_key} ->
        if MapSet.member?(seen, parent_key) do
          []
        else
          ancestor_keys(parent_key, nodes, MapSet.put(seen, parent_key)) ++
            [parent_key]
        end
    end
  end

  defp node_key(%Entry{span_id: span_id}) when is_binary(span_id),
    do: {:span, span_id}

  defp node_key(%Entry{} = entry), do: {:entry, entry_id(entry)}

  defp parent_key(%Entry{parent_id: parent_id}, span_ids)
       when is_binary(parent_id) do
    if MapSet.member?(span_ids, parent_id), do: {:span, parent_id}, else: nil
  end

  defp parent_key(_entry, _span_ids), do: nil

  defp entry_id(%Entry{id: id}), do: safe_string(id)

  defp humanize(value) when is_binary(value),
    do: String.replace(value, "_", " ")

  defp humanize(value), do: safe_string(value)

  defp truncate_id(value, max) do
    value
    |> safe_string()
    |> String.slice(0, max)
  end

  defp safe_string(value) when is_binary(value), do: value

  defp safe_string(value) do
    try do
      to_string(value)
    rescue
      Protocol.UndefinedError ->
        inspect(value, limit: 8, printable_limit: 160)

      ArgumentError ->
        inspect(value, limit: 8, printable_limit: 160)
    end
  end
end
