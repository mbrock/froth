defmodule Froth.Inference.StepLog do
  @moduledoc """
  Tool-loop step/event persistence and pubsub fan-out for inference sessions.
  """

  alias Froth.Repo
  alias Froth.Inference.InferenceSession
  import Ecto.Query

  def append(inference_session_id, kind, data)
      when is_integer(inference_session_id) and is_binary(kind) and is_map(data) do
    step = %{
      "at" => DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      "kind" => kind,
      "data" => normalize_step_data(data)
    }

    step_json = Jason.encode!([step])

    Repo.update_all(
      from(c in InferenceSession,
        where: c.id == ^inference_session_id,
        update: [
          set: [
            tool_steps:
              fragment(
                "COALESCE(tool_steps, '[]'::jsonb) || ?::jsonb",
                type(^step_json, :string)
              )
          ]
        ]
      ),
      []
    )

    Froth.broadcast("tool_loop:#{inference_session_id}", {:tool_step, step})

    :ok
  end

  def append(inference_session_id, kind, data)
      when is_integer(inference_session_id) and is_binary(kind) and is_list(data) do
    append(inference_session_id, kind, %{"items" => data})
  end

  def append_assistant_content(inference_session_id, content) when is_list(content) do
    Enum.each(content, fn
      %{"type" => "thinking", "thinking" => thinking} when is_binary(thinking) ->
        thinking = String.trim(thinking)

        if thinking != "",
          do: append(inference_session_id, "assistant_thinking", %{"text" => thinking})

      %{"type" => "text", "text" => text} when is_binary(text) ->
        text = String.trim(text)
        if text != "", do: append(inference_session_id, "assistant_text", %{"text" => text})

      _ ->
        :ok
    end)
  end

  def append_assistant_content(_inference_session_id, _content), do: :ok

  def broadcast_loop(inference_session_id) when is_integer(inference_session_id) do
    Froth.broadcast("tool_loop:#{inference_session_id}", {:tool_loop, :updated})
  end

  def broadcast_stream_event(inference_session_id, event)
      when is_integer(inference_session_id) do
    Froth.broadcast("tool_loop:#{inference_session_id}", {:stream_event, event})
  end

  defp normalize_step_data(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      Map.put(acc, to_string(k), normalize_step_value(v))
    end)
  end

  defp normalize_step_value(v) when is_binary(v), do: String.slice(v, 0, 1000)
  defp normalize_step_value(v) when is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp normalize_step_value(v) when is_atom(v), do: Atom.to_string(v)
  defp normalize_step_value(v) when is_map(v), do: normalize_step_data(v)
  defp normalize_step_value(v) when is_list(v), do: Enum.map(v, &normalize_step_value/1)
  defp normalize_step_value(v), do: inspect(v, limit: 100, printable_limit: 1000)
end
