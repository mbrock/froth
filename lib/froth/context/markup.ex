defmodule Froth.Context.Markup do
  @moduledoc false

  @entity_like_ampersand_regex ~r/&([0-9A-Za-z]+);/
  @part_break <<31>>
  @heex_comment_regex ~r/<!--[\s\S]*?-->/
  @phx_attr_regex ~r/\s+(?:phx-[A-Za-z0-9_:-]+|data-phx-[A-Za-z0-9_:-]+)="[^"]*"/

  def render_markup(rendered, pretty? \\ true) when is_boolean(pretty?) do
    rendered
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> sanitize_markup(pretty?)
  end

  def render_prompt_markup(rendered) do
    rendered
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> strip_heex_debug()
  end

  def sanitize_markup(markup, pretty? \\ true)
      when is_binary(markup) and is_boolean(pretty?) do
    ensure_fast_html_started()

    try do
      case Floki.parse_fragment(markup) do
        {:ok, fragment} ->
          fragment
          |> drop_phx_attrs()
          |> render_nodes(pretty?)
          |> IO.iodata_to_binary()

        {:error, _reason} ->
          markup
      end
    catch
      :exit, _reason ->
        markup
    end
  end

  def strip_heex_debug(markup) when is_binary(markup) do
    markup
    |> String.replace(@heex_comment_regex, "")
    |> String.replace(@phx_attr_regex, "")
  end

  defp drop_phx_attrs(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(&drop_phx_attrs/1)
    |> Enum.reject(&is_nil/1)
  end

  defp drop_phx_attrs({tag, attrs, children}) when is_list(attrs) and is_list(children) do
    clean_attrs =
      Enum.reject(attrs, fn {name, _value} ->
        String.starts_with?(name, "phx-") or String.starts_with?(name, "data-phx-")
      end)

    {tag, clean_attrs, drop_phx_attrs(children)}
  end

  defp drop_phx_attrs({:comment, _text}), do: nil

  defp drop_phx_attrs(text) when is_binary(text) do
    normalized =
      text
      |> normalize_part_break_whitespace()
      |> trim_template_boundary_whitespace()

    trimmed = String.trim(normalized)

    if trimmed == "", do: nil, else: trimmed
  end

  defp drop_phx_attrs(other), do: other

  defp normalize_part_break_whitespace(text) when is_binary(text) do
    part_break = Regex.escape(@part_break)
    Regex.replace(~r/\s*#{part_break}\s*/, text, @part_break)
  end

  defp trim_template_boundary_whitespace(text) when is_binary(text) do
    text
    |> String.replace(~r/\A[ \t\r]*\n[ \t]*/, "")
    |> String.replace(~r/[ \t\r]*\n[ \t]*\z/, "")
    |> String.trim_trailing()
  end

  defp render_nodes(nodes, pretty?) when is_list(nodes) do
    {iodata, _prev} =
      Enum.reduce(nodes, {[], nil}, fn node, {acc, prev} ->
        separator =
          if pretty? and not is_nil(prev), do: ["\n"], else: []

        {[acc, separator, render_node(node, pretty?)], node}
      end)

    iodata
  end

  defp render_node({tag, attrs, children}, pretty?) do
    open = ["<", tag, render_attrs(attrs), ">"]

    cond do
      void_tag?(tag) and children == [] ->
        open

      children == [] ->
        if pretty? do
          [open, "\n", "</", tag, ">"]
        else
          [open, "</", tag, ">"]
        end

      true ->
        leading_newline = if pretty?, do: "\n", else: ""
        trailing_newline = if pretty?, do: "\n", else: ""

        [
          open,
          leading_newline,
          render_nodes(children, pretty?),
          trailing_newline,
          "</",
          tag,
          ">"
        ]
    end
  end

  defp render_node(text, _pretty?) when is_binary(text), do: escape_text(text)
  defp render_node(other, _pretty?), do: to_string(other)

  defp render_attrs(attrs) when is_list(attrs) do
    Enum.map(attrs, fn {name, value} ->
      [" ", name, "=\"", escape_attr(value), "\""]
    end)
  end

  defp escape_text(text) when is_binary(text) do
    text
    |> escape_entity_like_ampersands()
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_attr(value) when is_binary(value) do
    value
    |> escape_entity_like_ampersands()
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape_attr(value), do: value |> to_string() |> escape_attr()

  defp escape_entity_like_ampersands(text) when is_binary(text) do
    Regex.replace(@entity_like_ampersand_regex, text, "&amp;\\1;")
  end

  defp ensure_fast_html_started do
    if Application.get_env(:floki, :html_parser) == Floki.HTMLParser.FastHtml do
      _ = Application.ensure_all_started(:fast_html)
    end

    :ok
  end

  defp void_tag?(tag),
    do:
      tag in [
        "area",
        "base",
        "br",
        "col",
        "embed",
        "hr",
        "img",
        "input",
        "link",
        "meta",
        "param",
        "source",
        "track",
        "wbr"
      ]
end
