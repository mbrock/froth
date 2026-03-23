defmodule Froth.Agent.ToolResult do
  use Ecto.Schema

  @type t :: %__MODULE__{tool_use_id: String.t(), content: term(), is_error: boolean()}

  @primary_key false
  embedded_schema do
    field(:tool_use_id, :string)
    field(:content, :any, virtual: true)
    field(:is_error, :boolean, default: false)
    field(:yield?, :boolean, default: false)
  end

  def new(tool_use_id, content, opts \\ []) do
    %__MODULE__{
      tool_use_id: tool_use_id,
      content: content,
      is_error: Keyword.get(opts, :is_error, false),
      yield?: Keyword.get(opts, :yield?, false)
    }
  end

  def to_api(%__MODULE__{} = result) do
    content = normalize_content(result.content)
    map = %{"type" => "tool_result", "tool_use_id" => result.tool_use_id, "content" => content}
    if result.is_error, do: Map.put(map, "is_error", true), else: map
  end

  defp normalize_content(content) when is_binary(content), do: content

  defp normalize_content(content) when is_map(content) do
    Map.new(content, fn {key, value} ->
      {to_string(key), normalize_content(value)}
    end)
  end

  defp normalize_content(content) when is_list(content),
    do: Enum.map(content, &normalize_content/1)

  defp normalize_content(content),
    do: inspect(content, limit: :infinity, printable_limit: :infinity)
end
