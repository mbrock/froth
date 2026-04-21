defmodule Froth.Agent.ToolResult do
  use Ecto.Schema

  @type t :: %__MODULE__{
          tool_use_id: String.t(),
          content: term(),
          is_error: boolean(),
          yield?: boolean(),
          control_outcome: String.t() | nil,
          control_data: map()
        }

  @primary_key false
  embedded_schema do
    field(:tool_use_id, :string)
    field(:content, :any, virtual: true)
    field(:is_error, :boolean, default: false)
    field(:yield?, :boolean, default: false)
    field(:control_outcome, :string, virtual: true)
    field(:control_data, :map, virtual: true, default: %{})
  end

  def new(tool_use_id, content, opts \\ []) do
    control_outcome = Keyword.get(opts, :control_outcome)

    %__MODULE__{
      tool_use_id: tool_use_id,
      content: content,
      is_error: Keyword.get(opts, :is_error, false),
      yield?: Keyword.get(opts, :yield?, control_outcome == "yield"),
      control_outcome: control_outcome,
      control_data: Keyword.get(opts, :control_data, %{})
    }
  end

  def to_api(%__MODULE__{} = result) do
    content = normalize_content(result.content)

    map = %{
      "type" => "tool_result",
      "tool_use_id" => result.tool_use_id,
      "content" => content
    }

    if result.is_error, do: Map.put(map, "is_error", true), else: map
  end

  defp normalize_content(content) when is_binary(content), do: content

  # A block list is the canonical tool-output shape. By the time we
  # get here the worker has already materialized big bodies into
  # blobs (see `Worker.tool_result_from_execution/2`).
  #
  # The textual subtree always renders to a single text part via the
  # HEEx component. Binary-shaped blocks (image/PDF/etc.) ride along
  # as separate content parts so multimodal-aware providers
  # (Anthropic, Gemini) actually receive the bytes; their
  # placeholders in the rendered text describe where in the tree
  # they live. Providers that can't accept media in tool_results
  # (OpenAI Responses) still see the placeholder XML and degrade
  # cleanly.
  defp normalize_content([%Froth.Context.Block{} | _] = blocks) do
    text_part = %{
      "type" => "text",
      "text" => Froth.Context.BlockHTML.live_to_string(blocks)
    }

    case collect_media_parts(blocks) do
      [] -> text_part["text"]
      media_parts -> [text_part | media_parts]
    end
  end

  defp normalize_content(content) when is_map(content) do
    Map.new(content, fn {key, value} ->
      {to_string(key), normalize_content(value)}
    end)
  end

  defp normalize_content(content) when is_list(content),
    do: Enum.map(content, &normalize_content/1)

  defp normalize_content(content),
    do: inspect(content, limit: :infinity, printable_limit: :infinity)

  # DFS through the materialized tree. Each binary-shaped block
  # becomes a single content part labeled by its mime kind. Bytes
  # are pulled from the blob (every binary block is blobbed by
  # materialize/1 unless `:no_fold` was set, in which case body is
  # still inline and we use that directly).
  defp collect_media_parts(blocks) when is_list(blocks) do
    Enum.flat_map(blocks, &collect_media_from_block/1)
  end

  defp collect_media_from_block(%Froth.Context.Block{} = block) do
    own =
      if Froth.Context.Blocks.binary_shaped?(block) do
        case media_part_from_block(block) do
          nil -> []
          part -> [part]
        end
      else
        []
      end

    own ++ collect_media_parts(block.children)
  end

  defp collect_media_from_block(_), do: []

  defp media_part_from_block(%Froth.Context.Block{} = block) do
    mime = Froth.Context.Block.attr(block, :mime)

    with {:ok, bytes} <- block_bytes(block),
         {:ok, type} <- media_part_type(mime) do
      %{
        "type" => type,
        "source" => %{
          "type" => "base64",
          "media_type" => mime,
          "data" => Base.encode64(bytes)
        }
      }
    else
      _ -> nil
    end
  end

  defp block_bytes(%Froth.Context.Block{body: body}) when is_binary(body),
    do: {:ok, body}

  defp block_bytes(%Froth.Context.Block{} = block) do
    case Froth.Context.Block.attr(block, :blob) do
      blob_id when is_binary(blob_id) ->
        case Froth.Blobs.get(blob_id) do
          {:ok, blob} -> {:ok, blob.bytes}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp media_part_type("image/" <> _), do: {:ok, "image"}
  defp media_part_type("application/pdf"), do: {:ok, "document"}
  defp media_part_type(_), do: :error
end
