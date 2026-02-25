defmodule Mix.Tasks.BackfillCharlieToolSteps do
  @shortdoc "Backfill Charlie inference session tool_steps from legacy api_messages/pending_tools"
  use Mix.Task

  alias Froth.Repo
  alias Froth.Inference.InferenceSession
  import Ecto.Query

  @limit_chars 1000
  @max_preview_chars 400

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    inference_sessions =
      Repo.all(
        from(c in InferenceSession,
          where: fragment("COALESCE(jsonb_array_length(?), 0) = 0", c.tool_steps),
          order_by: [asc: c.id]
        ),
        log: false
      )

    Mix.shell().info("Inference sessions to backfill: #{length(inference_sessions)}")

    updated =
      Enum.count(inference_sessions, fn inference_session ->
        steps = build_steps(inference_session)

        inference_session
        |> InferenceSession.changeset(%{tool_steps: steps})
        |> Repo.update!()

        true
      end)

    Mix.shell().info(
      "Backfilled #{updated} inference sessions with #{updated} tool step histories"
    )
  end

  defp build_steps(inference_session) do
    pending_map = pending_tools_map(inference_session.pending_tools || [])

    acc = %{
      steps: [],
      tool_name_by_id: %{},
      tool_result_by_id: %{},
      seen_tool_results: MapSet.new(),
      pending_map: pending_map
    }

    acc =
      Enum.reduce(inference_session.api_messages || [], acc, fn
        %{"role" => "assistant", "content" => content}, inner_acc when is_list(content) ->
          Enum.reduce(content, inner_acc, &assistant_block_to_step/2)

        %{"role" => "user", "content" => content}, inner_acc when is_list(content) ->
          Enum.reduce(content, inner_acc, &user_block_to_step/2)

        _, inner_acc ->
          inner_acc
      end)

    acc =
      if inference_session.status == "awaiting_tools" do
        pending_count =
          Enum.count(inference_session.pending_tools || [], &(&1["status"] == "pending"))

        resolved_count =
          Enum.count(
            inference_session.pending_tools || [],
            &(&1["status"] in ["resolved", "stopped"])
          )

        append_step(
          acc,
          "awaiting_tools",
          %{"pending_count" => pending_count, "resolved_count" => resolved_count}
        )
      else
        append_step(
          acc,
          "status_changed",
          %{"status" => inference_session.status || "unknown"}
        )
      end

    Enum.reduce(acc.pending_map, acc, fn {_ref, entry}, inner ->
      emit_pending_tool_step(inner, entry)
    end)
    |> Map.get(:steps)
    |> maybe_prepend_context_steps(inference_session)
  end

  defp emit_pending_tool_step(acc, %{"tool_use_id" => tool_use_id} = entry) do
    status = Map.get(entry, "status", "resolved")
    name = Map.get(entry, "name", "tool")
    ref = Map.get(entry, "ref")
    data = normalize_map(%{"tool_use_id" => tool_use_id, "name" => name, "ref" => ref})

    acc =
      cond do
        status == "pending" and name == "elixir_eval" ->
          append_step_data(acc, "tool_queued", data)

        status == "executing" ->
          append_step_data(acc, "tool_started", Map.put(data, "status", "executing"))

        status == "resolved" || status == "stopped" ->
          result = Map.get(entry, "result")

          resolved_data =
            data
            |> Map.put("result", normalize_text(result))
            |> Map.put("is_error", Map.get(entry, "is_error", false))
            |> Map.put("status", status)

          append_step_data(acc, "tool_resolved", resolved_data)

        true ->
          acc
      end

    acc
  end

  defp assistant_block_to_step(
         %{"type" => "thinking", "thinking" => thinking},
         %{tool_name_by_id: tool_name_by_id} = acc
       ) do
    text = normalize_text(thinking)

    if text == "" do
      %{acc | tool_name_by_id: tool_name_by_id}
    else
      acc
      |> append_step("assistant_thinking", %{"text" => text})
    end
  end

  defp assistant_block_to_step(%{"type" => "text", "text" => text}, acc) do
    text = normalize_text(text)

    if text == "" do
      acc
    else
      append_step(acc, "assistant_text", %{"text" => text})
    end
  end

  defp assistant_block_to_step(
         %{"type" => "tool_use", "id" => id, "name" => name, "input" => input},
         acc
       )
       when is_binary(id) and is_binary(name) do
    code = if(name == "elixir_eval", do: input["code"], else: nil)
    input_preview = normalize_input_preview(input)

    base_data =
      normalize_map(%{
        "tool_use_id" => id,
        "name" => name,
        "input_preview" => input_preview
      })

    acc = update_in(acc.tool_name_by_id, &Map.put(&1, id, name))

    cond do
      name == "send_message" ->
        text = normalize_text(Map.get(input, "text"))
        append_step(acc, "tool_immediate", Map.put(base_data, "text", text))

      name == "elixir_eval" ->
        append_step(
          acc,
          "tool_queued",
          Map.put(base_data, "code", normalize_text(code))
        )

      true ->
        if Map.has_key?(acc.tool_result_by_id, id) do
          result = Map.get(acc.tool_result_by_id, id)

          append_step(
            acc,
            "tool_resolved",
            Map.merge(base_data, %{
              "result" => normalize_result(result.result),
              "is_error" => result.is_error,
              "status" => "resolved"
            })
          )
        else
          append_step(
            acc,
            "tool_started",
            Map.put(base_data, "status", "executing")
          )
        end
    end
  end

  defp assistant_block_to_step(_, acc), do: acc

  defp user_block_to_step(
         %{"type" => "tool_result", "tool_use_id" => tool_use_id, "content" => content} = block,
         acc
       )
       when is_binary(tool_use_id) do
    is_error = if(Map.get(block, "is_error") == true, do: true, else: false)

    result = normalize_result(content)
    text = normalize_text(result)
    content_map = %{result: text, is_error: is_error}

    acc =
      acc
      |> put_in([:tool_result_by_id, tool_use_id], content_map)
      |> maybe_emit_tool_result_step(tool_use_id, text, is_error, acc.tool_name_by_id)

    if is_error and text != "" do
      maybe_emit_delivery_status(acc, tool_use_id, text, acc.tool_name_by_id)
    else
      acc
    end
  end

  defp user_block_to_step(_, acc), do: acc

  defp maybe_emit_tool_result_step(acc, tool_use_id, text, is_error, tool_names) do
    seen = acc.seen_tool_results

    if MapSet.member?(seen, tool_use_id) do
      acc
    else
      acc = %{acc | seen_tool_results: MapSet.put(seen, tool_use_id)}

      case Map.get(tool_names, tool_use_id) do
        "send_message" ->
          if is_error and text != "" do
            append_step(acc, "delivery_status", %{
              "result" => "send failed: " <> text,
              "is_error" => true
            })
          else
            acc
          end

        nil ->
          append_step(
            acc,
            "tool_resolved",
            %{"tool_use_id" => tool_use_id, "result" => text, "is_error" => is_error}
          )

        name ->
          append_step(
            acc,
            "tool_resolved",
            %{
              "tool_use_id" => tool_use_id,
              "name" => name,
              "result" => text,
              "is_error" => is_error
            }
          )
      end
    end
  end

  defp maybe_emit_delivery_status(acc, _tool_use_id, _text, _tool_names), do: acc

  defp pending_tools_map(pending_tools) when is_list(pending_tools) do
    Enum.reduce(pending_tools, %{}, fn
      %{"ref" => ref} = tool, acc when is_binary(ref) ->
        Map.put(acc, ref, tool)

      %{"tool_use_id" => id} = tool, acc when is_binary(id) ->
        Map.put(acc, "tool-use-" <> id, tool)

      _, acc ->
        acc
    end)
  end

  defp pending_tools_map(_), do: %{}

  defp normalize_result(nil), do: ""
  defp normalize_result(value) when is_binary(value), do: trim_text(value)
  defp normalize_result(value), do: inspect(value, limit: 100, printable_limit: 1200)

  defp normalize_text(value) when is_binary(value), do: trim_text(value)
  defp normalize_text(_), do: ""

  defp trim_text(text), do: text |> String.trim() |> String.slice(0, @limit_chars)

  defp normalize_input_preview(input) when is_map(input) do
    case Jason.encode(input) do
      {:ok, json} -> String.slice(json, 0, @max_preview_chars)
      _ -> inspect(input, limit: 100, printable_limit: 2000)
    end
  end

  defp normalize_input_preview(_), do: nil

  defp append_step(acc, kind, data), do: append_step_data(acc, kind, normalize_map(data))

  defp append_step_data(%{steps: steps} = acc, kind, data)
       when is_binary(kind) and is_map(data) do
    step = %{
      "at" => DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      "kind" => kind,
      "data" => data
    }

    %{acc | steps: steps ++ [step]}
  end

  defp append_step_data(acc, _, _), do: acc

  defp normalize_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, out ->
      Map.put(out, to_string(k), normalize_step_value(v))
    end)
  end

  defp normalize_map(other), do: %{"value" => normalize_step_value(other)}

  defp normalize_step_value(v) when is_binary(v), do: String.slice(v, 0, @limit_chars)
  defp normalize_step_value(v) when is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp normalize_step_value(v) when is_atom(v), do: Atom.to_string(v)
  defp normalize_step_value(v) when is_map(v), do: normalize_map(v)
  defp normalize_step_value(v) when is_list(v), do: Enum.map(v, &normalize_step_value/1)
  defp normalize_step_value(v), do: inspect(v, limit: 100, printable_limit: 1000)

  defp maybe_prepend_context_steps(steps, inference_session) do
    started_steps = [
      %{
        "at" => serialize_datetime(inference_session.inserted_at),
        "kind" => "inference_session_started",
        "data" =>
          normalize_map(%{
            "chat_id" => inference_session.chat_id,
            "reply_to" => inference_session.reply_to,
            "sender_id" =>
              inference_session.api_messages && get_sender_id(inference_session.api_messages)
          })
      },
      %{
        "at" => serialize_datetime(inference_session.inserted_at),
        "kind" => "stream_started",
        "data" =>
          normalize_map(%{"message_count" => length(inference_session.api_messages || [])})
      }
    ]

    started_steps ++ steps
  end

  defp serialize_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(DateTime.truncate(dt, :millisecond))
  end

  defp serialize_datetime(%NaiveDateTime{} = dt) do
    NaiveDateTime.to_iso8601(dt)
  end

  defp serialize_datetime(_),
    do: DateTime.to_iso8601(DateTime.truncate(DateTime.utc_now(), :millisecond))

  defp get_sender_id(api_messages) when is_list(api_messages) do
    case List.first(api_messages) do
      %{"role" => "user", "raw" => %{"sender_id" => sender}} when is_integer(sender) -> sender
      _ -> nil
    end
  end

  defp get_sender_id(_), do: nil
end
