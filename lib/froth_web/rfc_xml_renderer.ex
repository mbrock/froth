defmodule FrothWeb.RfcXmlRenderer do
  @moduledoc """
  Renders RFC XML documents to HTML.
  The XML carries the semantics; this module is the stylesheet.
  """

  def render(xml_string) do
    case :xmerl_scan.string(String.to_charlist(xml_string), [{:space, :normalize}]) do
      {doc, _rest} -> {:ok, render_rfc(doc)}
      error -> {:error, error}
    end
  end

  defp render_rfc({:xmlElement, :rfc, _, _, _, _, _, attrs, children, _, _, _}) do
    number = get_attr(attrs, :number)
    meta = find_child(children, :meta)
    sections = find_children(children, :section)
    refs = find_child(children, :references)

    title = meta_field(meta, :title) || "Untitled"
    status = meta_field(meta, :status) || "DRAFT"
    author = meta_field(meta, :author) || ""
    date = meta_field(meta, :date) || ""
    supersedes = meta_field(meta, :supersedes)
    related = meta_field(meta, :related)
    classification = meta_field(meta, :classification)
    research = meta_field(meta, :research)

    # Build metadata header
    meta_html = """
    <div class="rfc-meta">
      <dl>
        <dt>Status</dt><dd class="status">#{h(status)}</dd>
        <dt>Author</dt><dd>#{h(author)}</dd>
        <dt>Date</dt><dd>#{h(date)}</dd>
        #{if supersedes, do: "<dt>Supersedes</dt><dd>#{h(supersedes)}</dd>", else: ""}
        #{if related, do: "<dt>Related</dt><dd>#{h(related)}</dd>", else: ""}
        #{if classification, do: "<dt>Classification</dt><dd>#{h(classification)}</dd>", else: ""}
        #{if research, do: "<dt>Research</dt><dd>#{h(research)}</dd>", else: ""}
      </dl>
    </div>
    """

    sections_html = Enum.map(sections, &render_section/1) |> Enum.join("\n")
    refs_html = if refs, do: render_references(refs), else: ""

    %{
      number: to_string(number),
      title: to_string(title),
      body: meta_html <> sections_html <> refs_html
    }
  end
  defp render_rfc(_), do: %{number: "????", title: "Parse Error", body: "<p>Failed to parse RFC XML</p>"}

  defp render_section({:xmlElement, :section, _, _, _, _, _, attrs, children, _, _, _}) do
    title = get_attr(attrs, :title)
    id = get_attr(attrs, :id)
    content = Enum.map(children, &render_block/1) |> Enum.join("\n")
    ~s'<section id="#{h(to_string(id))}">\n<h2>#{h(to_string(title))}</h2>\n#{content}\n</section>'
  end
  defp render_section(_), do: ""

  defp render_block({:xmlElement, :p, _, _, _, _, _, _attrs, children, _, _, _}) do
    "<p>#{render_inline(children)}</p>"
  end
  defp render_block({:xmlElement, :code, _, _, _, _, _, attrs, children, _, _, _}) do
    lang = get_attr(attrs, :lang)
    text = text_content(children)
    lang_class = if lang && lang != '', do: ~s' class="language-#{h(to_string(lang))}"', else: ""
    "<pre><code#{lang_class}>#{h(to_string(text))}</code></pre>"
  end
  defp render_block({:xmlElement, :figure, _, _, _, _, _, attrs, children, _, _, _}) do
    src = get_attr(attrs, :src)
    alt = get_attr(attrs, :alt)
    caption_el = find_child(children, :caption)
    caption = if caption_el, do: render_inline(elem_children(caption_el)), else: to_string(alt)
    """
    <figure>
      <img src="#{h(to_string(src))}" alt="#{h(to_string(alt))}" loading="lazy">
      <figcaption>#{caption}</figcaption>
    </figure>
    """
  end
  defp render_block({:xmlElement, :list, _, _, _, _, _, attrs, children, _, _, _}) do
    type = get_attr(attrs, :type) || 'numbered'
    items = find_children(children, :item)
    tag = case to_string(type) do
      "numbered" -> "ol"
      "lettered" -> ~s'ol type="a"'
      "bullet" -> "ul"
      _ -> "ol"
    end
    close_tag = String.split(to_string(tag), " ") |> hd()
    items_html = Enum.map(items, &render_item/1) |> Enum.join("\n")
    "<#{tag}>\n#{items_html}\n</#{close_tag}>"
  end
  defp render_block({:xmlElement, :section, _, _, _, _, _, _, _, _, _, _} = el) do
    render_section(el)
  end
  defp render_block({:xmlText, _, _, _, text, _}) do
    t = String.trim(to_string(text))
    if t == "", do: "", else: t
  end
  defp render_block(_), do: ""

  defp render_item({:xmlElement, :item, _, _, _, _, _, _attrs, children, _, _, _}) do
    label_el = find_child(children, :label)
    label = if label_el, do: "<strong>#{text_content(elem_children(label_el))}) </strong>", else: ""
    ps = find_children(children, :p)
    inner = Enum.map(ps, fn p -> render_inline(elem_children(p)) end) |> Enum.join(" ")
    "<li>#{label}#{inner}</li>"
  end
  defp render_item(_), do: ""

  defp render_inline(children) do
    Enum.map(children, &render_inline_node/1) |> Enum.join("")
  end

  defp render_inline_node({:xmlText, _, _, _, text, _}), do: to_string(text)
  defp render_inline_node({:xmlElement, :cite, _, _, _, _, _, attrs, _, _, _, _}) do
    ref = get_attr(attrs, :ref)
    ~s'<sup><a href="#ref-#{h(to_string(ref))}">[#{h(to_string(ref))}]</a></sup>'
  end
  defp render_inline_node({:xmlElement, :em, _, _, _, _, _, _, children, _, _, _}) do
    "<em>#{text_content(children)}</em>"
  end
  defp render_inline_node({:xmlElement, :strong, _, _, _, _, _, _, children, _, _, _}) do
    "<strong>#{text_content(children)}</strong>"
  end
  defp render_inline_node({:xmlElement, :c, _, _, _, _, _, _, children, _, _, _}) do
    "<code>#{h(to_string(text_content(children)))}</code>"
  end
  defp render_inline_node({:xmlElement, :link, _, _, _, _, _, attrs, children, _, _, _}) do
    href = get_attr(attrs, :href)
    "<a href=\"#{h(to_string(href))}\">#{text_content(children)}</a>"
  end
  defp render_inline_node({:xmlElement, :"rfc-ref", _, _, _, _, _, attrs, _, _, _, _}) do
    number = get_attr(attrs, :number)
    "<a href=\"/rfc/#{h(to_string(number))}\">RFC-#{h(to_string(number))}</a>"
  end
  defp render_inline_node(_), do: ""

  defp render_references({:xmlElement, :references, _, _, _, _, _, _, children, _, _, _}) do
    refs = find_children(children, :ref)
    if refs == [] do
      ""
    else
      items = Enum.map(refs, fn {:xmlElement, :ref, _, _, _, _, _, attrs, children, _, _, _} ->
        id = get_attr(attrs, :id)
        number = get_attr(attrs, :number)
        title = meta_field_from(children, :title)
        url = meta_field_from(children, :url)
        num_display = if number && number != '', do: "[#{number}]", else: "[#{id}]"
        url_html = if url, do: " <a href=\"#{h(to_string(url))}\">#{h(to_string(url))}</a>", else: ""
        ~s'<li id="ref-#{h(to_string(id))}">#{num_display} #{h(to_string(title || ""))}#{url_html}</li>'
      end) |> Enum.join("\n")
      """
      <section id="references">
        <h2>References</h2>
        <ol class="references">
          #{items}
        </ol>
      </section>
      """
    end
  end
  defp render_references(_), do: ""

  # Helpers

  defp get_attr(attrs, name) do
    case Enum.find(attrs, fn {:xmlAttribute, n, _, _, _, _, _, _, v, _} -> n == name; _ -> false end) do
      {:xmlAttribute, _, _, _, _, _, _, _, value, _} -> value
      _ -> nil
    end
  end

  defp find_child(children, name) do
    Enum.find(children, fn
      {:xmlElement, n, _, _, _, _, _, _, _, _, _, _} -> n == name
      _ -> false
    end)
  end

  defp find_children(children, name) do
    Enum.filter(children, fn
      {:xmlElement, n, _, _, _, _, _, _, _, _, _, _} -> n == name
      _ -> false
    end)
  end

  defp elem_children({:xmlElement, _, _, _, _, _, _, _, children, _, _, _}), do: children
  defp elem_children(_), do: []

  defp text_content(children) do
    Enum.map(children, fn
      {:xmlText, _, _, _, text, _} -> to_string(text)
      {:xmlElement, _, _, _, _, _, _, _, cs, _, _, _} -> text_content(cs)
      _ -> ""
    end) |> Enum.join("")
  end

  defp meta_field(nil, _), do: nil
  defp meta_field({:xmlElement, _, _, _, _, _, _, _, children, _, _, _}, name) do
    case find_child(children, name) do
      nil -> nil
      el -> text_content(elem_children(el))
    end
  end

  defp meta_field_from(children, name) do
    case find_child(children, name) do
      nil -> nil
      el -> text_content(elem_children(el))
    end
  end

  defp h(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
