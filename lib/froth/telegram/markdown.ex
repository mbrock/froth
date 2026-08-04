defmodule Froth.Telegram.Markdown do
  @moduledoc """
  Converts ordinary Markdown into the small HTML subset TDLib accepts.

  Agent replies use CommonMark conventions such as `*italic*` and
  `**bold**`, which do not match Telegram's MarkdownV2 delimiters. Parsing
  with Earmark first lets TDLib receive unambiguous HTML and produce the
  correct UTF-16 text entities.
  """

  @spec to_telegram_html(String.t()) :: {:ok, String.t()} | {:error, term()}
  def to_telegram_html(markdown) when is_binary(markdown) do
    case Earmark.Parser.as_ast(markdown) do
      {:ok, ast, _messages} ->
        html =
          ast
          |> render_blocks()
          |> IO.iodata_to_binary()
          |> String.trim_trailing()

        {:ok, html}

      {:error, _ast, messages} ->
        {:error, {:invalid_markdown, messages}}
    end
  end

  defp render_blocks(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(&render_block/1)
    |> Enum.intersperse("\n\n")
  end

  defp render_block({"ul", _attrs, children, _meta}) do
    children
    |> Enum.map_join("\n", fn {"li", _, content, _} ->
      IO.iodata_to_binary(["• ", render_inline(content)])
    end)
  end

  defp render_block({"ol", _attrs, children, _meta}) do
    children
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {{"li", _, content, _}, index} ->
      IO.iodata_to_binary([
        Integer.to_string(index),
        ". ",
        render_inline(content)
      ])
    end)
  end

  defp render_block({"blockquote", _attrs, children, _meta}),
    do: ["<blockquote>", render_blocks(children), "</blockquote>"]

  defp render_block({"pre", _attrs, children, _meta}),
    do: ["<pre>", render_code_children(children), "</pre>"]

  defp render_block({tag, _attrs, children, _meta})
       when tag in ["h1", "h2", "h3", "h4", "h5", "h6"],
       do: ["<b>", render_inline(children), "</b>"]

  defp render_block({"hr", _attrs, _children, _meta}), do: "———"

  defp render_block({"p", _attrs, children, _meta}),
    do: render_inline(children)

  defp render_block(node), do: render_inline([node])

  defp render_inline(nodes) when is_list(nodes),
    do: Enum.map(nodes, &render_inline_node/1)

  defp render_inline_node(text) when is_binary(text), do: escape(text)

  defp render_inline_node({"em", _attrs, children, _meta}),
    do: ["<i>", render_inline(children), "</i>"]

  defp render_inline_node({"strong", _attrs, children, _meta}),
    do: ["<b>", render_inline(children), "</b>"]

  defp render_inline_node({"del", _attrs, children, _meta}),
    do: ["<s>", render_inline(children), "</s>"]

  defp render_inline_node({"code", _attrs, children, _meta}),
    do: ["<code>", render_code_children(children), "</code>"]

  defp render_inline_node({"a", attrs, children, _meta}) do
    case List.keyfind(attrs, "href", 0) do
      {"href", href} ->
        ["<a href=\"", escape(href), "\">", render_inline(children), "</a>"]

      nil ->
        render_inline(children)
    end
  end

  defp render_inline_node({"br", _attrs, _children, _meta}), do: "\n"

  defp render_inline_node({"img", attrs, _children, _meta}) do
    attrs
    |> List.keyfind("alt", 0, {"alt", ""})
    |> elem(1)
    |> escape()
  end

  defp render_inline_node({"p", _attrs, children, _meta}),
    do: render_inline(children)

  defp render_inline_node({tag, attrs, children, meta}),
    do: render_block({tag, attrs, children, meta})

  defp render_code_children(children) when is_list(children) do
    Enum.map(children, fn
      text when is_binary(text) -> escape(text)
      {_tag, _attrs, nested, _meta} -> render_code_children(nested)
    end)
  end

  defp escape(text) when is_binary(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
