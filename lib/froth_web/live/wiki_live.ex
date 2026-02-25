defmodule FrothWeb.WikiLive do
  use FrothWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:entry, nil) |> assign(:entries, Froth.Wiki.entries())}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    entries = Froth.Wiki.entries()

    case Froth.Wiki.get(slug) do
      nil ->
        {:noreply,
         socket
         |> assign(:entries, entries)
         |> push_navigate(to: ~p"/froth/wiki")}

      entry ->
        {:noreply,
         socket
         |> assign(:entry, entry)
         |> assign(:entries, entries)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:entry, nil)
     |> assign(:entries, Froth.Wiki.entries())}
  end

  defp paragraphs(%{body: nil}), do: []
  defp paragraphs(%{body: ""}), do: []

  defp paragraphs(%{body: body}) do
    body
    |> String.split(~r/\n\n+/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp wiki_linker(entries) do
    targets =
      Enum.reduce(entries, %{}, fn entry, targets ->
        targets
        |> put_link_target(entry.title, entry.slug)
        |> put_link_target(entry.slug, entry.slug)
      end)

    regex =
      case Map.keys(targets) do
        [] ->
          nil

        page_names ->
          pattern =
            page_names
            |> Enum.sort_by(&String.length/1, :desc)
            |> Enum.map(&Regex.escape/1)
            |> Enum.join("|")

          Regex.compile!(
            "(?<![\\p{L}\\p{N}])(?:#{pattern})(?![\\p{L}\\p{N}])",
            "iu"
          )
      end

    %{targets: targets, regex: regex}
  end

  defp linked_segments(paragraph, %{regex: nil}), do: [{:text, paragraph}]

  defp linked_segments(paragraph, %{regex: regex, targets: targets}) do
    regex
    |> Regex.split(paragraph, include_captures: true, trim: false)
    |> Enum.reduce([], fn segment, segments ->
      case segment do
        "" ->
          segments

        _ ->
          case Map.get(targets, normalize_page_name(segment)) do
            nil -> [{:text, segment} | segments]
            slug -> [{:link, slug, segment} | segments]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp put_link_target(targets, nil, _slug), do: targets

  defp put_link_target(targets, page_name, slug) do
    case normalize_page_name(page_name) do
      "" -> targets
      normalized_page_name -> Map.put_new(targets, normalized_page_name, slug)
    end
  end

  defp normalize_page_name(page_name) do
    page_name
    |> String.trim()
    |> String.downcase()
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:paras, paragraphs(assigns.entry || %{body: ""}))
      |> assign(:linker, wiki_linker(assigns.entries))

    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <style>
        @import url('https://fonts.googleapis.com/css2?family=EB+Garamond:ital,wght@0,400;0,500;0,600;0,700;1,400;1,500&family=Cormorant+SC:wght@400;500;600;700&display=swap');

        .wiki-root {
          font-family: 'EB Garamond', Georgia, 'Times New Roman', serif;
          max-width: 42em;
          margin: 2em auto;
          padding: 0 1.5em;
          color: #1a1a1a;
          line-height: 1.65;
          font-size: 1.15rem;
          background: #faf8f3;
          min-height: 100vh;
        }

        .wiki-root a { color: #6b3a2a; text-decoration: none; border-bottom: 1px solid #c9b99a; }
        .wiki-root a:hover { color: #3a1a0a; border-bottom-color: #6b3a2a; }

        .wiki-header {
          text-align: center;
          padding: 2em 0 1.5em;
          border-bottom: 2px solid #1a1a1a;
          margin-bottom: 2em;
        }

        .wiki-title {
          font-family: 'Cormorant SC', Georgia, serif;
          font-size: 2.2rem;
          letter-spacing: 0.15em;
          font-weight: 600;
          margin: 0;
          text-transform: uppercase;
        }

        .wiki-subtitle {
          font-style: italic;
          font-size: 0.95rem;
          color: #666;
          margin-top: 0.3em;
        }

        .entry-title {
          font-family: 'Cormorant SC', Georgia, serif;
          font-size: 1.8rem;
          letter-spacing: 0.1em;
          font-weight: 600;
          text-transform: uppercase;
          margin: 0 0 0.5em 0;
          text-align: center;
        }

        .entry-also {
          text-align: center;
          font-style: italic;
          font-size: 0.9rem;
          color: #888;
          margin-bottom: 1.5em;
        }

        .entry-body { text-align: justify; }
        .entry-body p { margin: 0 0 1em 0; text-indent: 1.5em; }
        .entry-body p:first-child { text-indent: 0; }
        .entry-body p:first-child::first-letter {
          font-size: 3.2em;
          float: left;
          line-height: 0.8;
          padding-right: 0.08em;
          font-weight: 700;
          color: #3a1a0a;
        }
        .entry-body .wiki-inline-link {
          font-variant: small-caps;
          letter-spacing: 0.04em;
          font-size: 0.95em;
        }

        .entry-see { margin-top: 2em; font-size: 0.95rem; color: #666; font-style: italic; }
        .entry-see a { font-style: normal; }

        .index-list { list-style: none; padding: 0; columns: 2; column-gap: 2em; }
        .index-list li {
          padding: 0.35em 0;
          break-inside: avoid;
          border-bottom: 1px dotted #ddd;
        }
        .index-list li a { font-family: 'Cormorant SC', Georgia, serif; font-size: 1.05rem; letter-spacing: 0.05em; }

        .wiki-footer {
          margin-top: 3em;
          padding-top: 1em;
          border-top: 1px solid #ccc;
          text-align: center;
          font-size: 0.85rem;
          color: #999;
          font-style: italic;
        }

        .wiki-nav {
          text-align: center;
          margin-bottom: 2em;
          font-size: 0.9rem;
        }

        @media (max-width: 600px) {
          .index-list { columns: 1; }
          .wiki-root { font-size: 1.05rem; }
          .wiki-title { font-size: 1.6rem; }
          .entry-title { font-size: 1.4rem; }
        }
      </style>

      <div class="wiki-root">
        <div class="wiki-header">
          <h1 class="wiki-title">
            <.link navigate={~p"/froth/wiki"} style="border: none;">Encyclopædia Pallica</.link>
          </h1>
          <div class="wiki-subtitle">
            A companion to the theory of the pallus &amp; related concepts
          </div>
        </div>

        <%= if @entry do %>
          <div class="wiki-nav">
            <.link navigate={~p"/froth/wiki"}>← Index</.link>
          </div>
          <h2 class="entry-title">{@entry.title}</h2>
          <%= if @entry.also_known_as && @entry.also_known_as != "" do %>
            <div class="entry-also">{@entry.also_known_as}</div>
          <% end %>
          <div class="entry-body">
            <%= if @paras == [] do %>
              <p><em>This entry awaits its author.</em></p>
            <% else %>
              <%= for para <- @paras do %>
                <p>
                  <%= for segment <- linked_segments(para, @linker) do %>
                    <%= case segment do %>
                      <% {:text, text} -> %>
                        {text}
                      <% {:link, slug, text} -> %>
                        <.link navigate={~p"/froth/wiki/#{slug}"} class="wiki-inline-link">
                          {text}
                        </.link>
                    <% end %>
                  <% end %>
                </p>
              <% end %>
            <% end %>
          </div>
          <%= if @entry.see_also != [] do %>
            <div class="entry-see">
              See also:&ensp;
              <%= for {slug, idx} <- Enum.with_index(@entry.see_also) do %>
                <.link navigate={~p"/froth/wiki/#{slug}"}><%= slug %></.link>{if idx <
                                                                                   length(
                                                                                     @entry.see_also
                                                                                   ) - 1,
                                                                                 do: " · "}
              <% end %>
            </div>
          <% end %>
        <% else %>
          <ul class="index-list">
            <%= for entry <- @entries do %>
              <li><.link navigate={~p"/froth/wiki/#{entry.slug}"}>{entry.title}</.link></li>
            <% end %>
          </ul>
        <% end %>

        <div class="wiki-footer">
          Encyclopædia Pallica · February 2026 · The Lineage
        </div>
      </div>
    </Layouts.app>
    """
  end
end
