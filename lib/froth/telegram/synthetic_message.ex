defmodule Froth.Telegram.SyntheticMessage do
  @moduledoc false

  @spec build(integer(), String.t(), keyword()) :: map()
  def build(chat_id, text, opts \\ [])
      when is_integer(chat_id) and is_binary(text) and is_list(opts) do
    %{
      "chat_id" => chat_id,
      "id" => normalize_id(Keyword.get(opts, :id)),
      "sender_id" => 0,
      "date" => normalize_date(Keyword.get(opts, :date)),
      "content" => %{
        "text" => %{
          "text" => String.trim(text)
        }
      }
    }
    |> maybe_put("reply_to_override", normalize_optional_integer(Keyword.get(opts, :reply_to)))
  end

  defp normalize_id(id) when is_integer(id) and id > 0, do: id
  defp normalize_id(_id), do: System.unique_integer([:positive, :monotonic])

  defp normalize_date(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp normalize_date(date) when is_integer(date) and date > 0, do: date
  defp normalize_date(_date), do: DateTime.utc_now() |> DateTime.to_unix()

  defp normalize_optional_integer(value) when is_integer(value) and value > 0, do: value
  defp normalize_optional_integer(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
