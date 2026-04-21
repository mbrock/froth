defmodule Froth.LLM.Message do
  @moduledoc false

  @type role :: :system | :user | :assistant
  @type content_block :: map()
  @type t :: %__MODULE__{
          role: role(),
          content: [content_block()]
        }

  defstruct [:role, content: []]

  def user(content),
    do: %__MODULE__{role: :user, content: normalize_content(content)}

  def assistant(content),
    do: %__MODULE__{role: :assistant, content: normalize_content(content)}

  def system(content),
    do: %__MODULE__{role: :system, content: normalize_content(content)}

  def normalize(%__MODULE__{} = message) do
    {:ok,
     %{
       message
       | role: normalize_role(message.role),
         content: normalize_content(message.content)
     }}
  end

  def normalize(%{"role" => role, "content" => content}) do
    {:ok,
     %__MODULE__{
       role: normalize_role(role),
       content: normalize_content(content)
     }}
  rescue
    ArgumentError -> :error
  end

  def normalize(%{role: role, content: content}) do
    {:ok,
     %__MODULE__{
       role: normalize_role(role),
       content: normalize_content(content)
     }}
  rescue
    ArgumentError -> :error
  end

  def normalize(_message), do: :error

  def text_content(%__MODULE__{content: content}), do: text_content(content)

  def text_content(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("")
  end

  def text_content(content) when is_binary(content), do: content
  def text_content(_content), do: ""

  def content_blocks(%__MODULE__{content: content}), do: content

  def tool_uses(%__MODULE__{content: content}) do
    Enum.filter(content, &match?(%{"type" => "tool_use"}, &1))
  end

  def tool_results(%__MODULE__{content: content}) do
    Enum.filter(content, &match?(%{"type" => "tool_result"}, &1))
  end

  def normalize_content(content) when is_binary(content),
    do: [%{"type" => "text", "text" => content}]

  def normalize_content(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      part when is_binary(part) ->
        [%{"type" => "text", "text" => part}]

      part when is_map(part) ->
        [normalize_block(part)]

      other ->
        [
          %{
            "type" => "text",
            "text" =>
              inspect(other, limit: :infinity, printable_limit: :infinity)
          }
        ]
    end)
  end

  def normalize_content(content) when is_map(content),
    do: [normalize_block(content)]

  def normalize_content(content) do
    [%{"type" => "text", "text" => to_string(content)}]
  end

  defp normalize_block(block) when is_map(block) do
    block
    |> deep_stringify_keys()
    |> case do
      %{"type" => _type} = normalized ->
        normalized

      %{"text" => _text} = normalized ->
        Map.put_new(normalized, "type", "text")

      normalized ->
        %{
          "type" => "text",
          "text" =>
            inspect(normalized, limit: :infinity, printable_limit: :infinity)
        }
    end
  end

  defp normalize_role(:system), do: :system
  defp normalize_role(:user), do: :user
  defp normalize_role(:assistant), do: :assistant
  defp normalize_role("system"), do: :system
  defp normalize_role("user"), do: :user
  defp normalize_role("assistant"), do: :assistant

  defp normalize_role(other) do
    raise ArgumentError, "unsupported LLM message role: #{inspect(other)}"
  end

  defp deep_stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), deep_stringify_keys(value)}
    end)
  end

  defp deep_stringify_keys(list) when is_list(list),
    do: Enum.map(list, &deep_stringify_keys/1)

  defp deep_stringify_keys(value), do: value
end
