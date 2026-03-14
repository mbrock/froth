defmodule FrothWeb.JboLive do
  use FrothWeb, :live_view

  @examples ["coi", "UI1", "bau", "bangu", "a'a", "lojbo", "BAI", "zdani"]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "jbo")
     |> assign(:query, "")
     |> assign(:selected_param, "")
     |> assign(:form, to_form(%{"q" => ""}, as: :jbo))
     |> assign(:lookup, blank_lookup())
     |> assign(:lookup_error, nil)
     |> assign(:stats, nil)
     |> assign(:stats_error, nil)
     |> assign(:results_count, 0)
     |> assign(:results_empty?, true)
     |> stream_configure(:results, dom_id: &"jbo-result-#{dom_safe(&1.word)}")
     |> stream(:results, [], reset: true)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected_param = sanitize_query(params["entry"])

    query =
      params["q"]
      |> sanitize_query()
      |> blank_to(selected_param)

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:selected_param, selected_param)
     |> assign(:form, to_form(%{"q" => query}, as: :jbo))
     |> load_page_data(query, selected_param)}
  end

  @impl true
  def handle_event("search", %{"jbo" => %{"q" => query}}, socket) do
    query = sanitize_query(query)
    params = if query == "", do: [], else: [q: query]

    {:noreply, push_patch(socket, to: ~p"/jbo?#{params}", replace: true)}
  end

  def handle_event("retry-dictionary", _params, socket) do
    :ok = Froth.Jbo.Dictionary.reset()

    {:noreply, load_page_data(socket, socket.assigns.query, socket.assigns.selected_param)}
  end

  @impl true
  def render(assigns) do
    lookup_data = assigns.lookup || blank_lookup()

    assigns =
      assigns
      |> assign(:lookup_data, lookup_data)
      |> assign(:selected_entry, lookup_data.selected)
      |> assign(:stats_data, assigns.stats)
      |> assign(:example_queries, @examples)

    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div class="min-h-screen bg-[linear-gradient(180deg,#f8f5ee_0%,#efe8dc_46%,#faf7f1_100%)] text-stone-900">
        <section class="safe-top safe-bottom mx-auto flex w-full max-w-6xl flex-col gap-4 px-4 pb-10 pt-4 sm:px-6 lg:px-8">
          <div class="overflow-hidden rounded-md border border-stone-300 bg-[linear-gradient(135deg,rgba(255,255,255,0.96)_0%,rgba(247,239,226,0.98)_54%,rgba(236,231,223,0.94)_100%)] shadow-sm">
            <div class="grid gap-6 p-4 sm:p-6 lg:grid-cols-[minmax(0,1.18fr)_minmax(18rem,0.82fr)]">
              <div class="space-y-5">
                <div class="space-y-3">
                  <div class="text-[0.7rem] font-semibold uppercase tracking-[0.28em] text-stone-500">
                    Lojban lookup
                  </div>
                  <h1 class="max-w-3xl text-3xl font-semibold tracking-tight text-stone-950 sm:text-4xl">
                    Search valsi, rafsi, selma'o, glosses, and the links between entries.
                  </h1>
                  <p class="max-w-2xl text-sm leading-6 text-stone-600 sm:text-base">
                    The full dictionary is bundled locally and loaded ahead of time, so `/jbo`
                    behaves like a fast reference tool instead of a page that wakes up after you open it.
                  </p>
                </div>

                <.form for={@form} id="jbo-search-form" phx-change="search" class="space-y-3">
                  <label
                    for="jbo-q"
                    class="text-[0.7rem] font-semibold uppercase tracking-[0.24em] text-stone-500"
                  >
                    Search
                  </label>
                  <div class="flex items-center gap-3 rounded-md border border-stone-900 bg-stone-950 px-3 py-3 shadow-sm transition phx-change-loading:opacity-90">
                    <span class="flex h-9 w-9 shrink-0 items-center justify-center border border-white/10 bg-white/5 text-stone-100">
                      <.icon name="hero-magnifying-glass" class="size-5" />
                    </span>
                    <.input
                      field={@form[:q]}
                      id="jbo-q"
                      type="search"
                      variant="bare"
                      autocomplete="off"
                      autocorrect="off"
                      autocapitalize="none"
                      spellcheck="false"
                      phx-debounce="120"
                      placeholder="a'a, coi, bangu, UI1, language..."
                      class="min-w-0 flex-1 border-0 bg-transparent px-0 py-0 text-base text-white placeholder:text-stone-400 focus:outline-none sm:text-lg"
                    />
                    <.link
                      :if={@query != ""}
                      patch={~p"/jbo"}
                      id="jbo-clear-search"
                      class="shrink-0 border border-white/10 px-3 py-2 text-xs font-semibold uppercase tracking-[0.18em] text-stone-200 transition hover:border-white/30 hover:bg-white/10 hover:text-white"
                    >
                      Clear
                    </.link>
                  </div>
                </.form>

                <%= if @query == "" do %>
                  <div class="grid grid-cols-2 gap-2 sm:flex sm:flex-wrap">
                    <%= for example <- @example_queries do %>
                      <.link
                        patch={jbo_path(example, example)}
                        class="border border-stone-300 bg-stone-50 px-3 py-2 text-sm font-medium text-stone-700 transition hover:border-stone-500 hover:bg-white hover:text-stone-950"
                      >
                        {example}
                      </.link>
                    <% end %>
                  </div>
                <% else %>
                  <div class="flex flex-wrap items-center gap-2 text-sm text-stone-600">
                    <span class="border border-stone-300 bg-white px-3 py-1.5 font-medium text-stone-800">
                      query {@query}
                    </span>
                    <span
                      :if={@selected_entry}
                      class="border border-amber-300 bg-amber-50 px-3 py-1.5 text-stone-800"
                    >
                      selected {@selected_entry.word}
                    </span>
                  </div>
                <% end %>
              </div>

              <div class="grid grid-cols-2 gap-px overflow-hidden rounded-md border border-stone-300 bg-stone-300">
                <div class="bg-white px-4 py-3">
                  <div class="text-[0.68rem] font-semibold uppercase tracking-[0.22em] text-stone-500">
                    valsi
                  </div>
                  <div class="mt-2 text-2xl font-semibold tracking-tight text-stone-950">
                    {(@stats_data && format_count(@stats_data.entry_count)) || "—"}
                  </div>
                </div>
                <div class="bg-white px-4 py-3">
                  <div class="text-[0.68rem] font-semibold uppercase tracking-[0.22em] text-stone-500">
                    selma'o
                  </div>
                  <div class="mt-2 text-2xl font-semibold tracking-tight text-stone-950">
                    {(@stats_data && format_count(@stats_data.selmaho_count)) || "—"}
                  </div>
                </div>
                <div class="bg-white px-4 py-3">
                  <div class="text-[0.68rem] font-semibold uppercase tracking-[0.22em] text-stone-500">
                    rafsi
                  </div>
                  <div class="mt-2 text-2xl font-semibold tracking-tight text-stone-950">
                    {(@stats_data && format_count(@stats_data.rafsi_count)) || "—"}
                  </div>
                </div>
                <div class="bg-white px-4 py-3">
                  <div class="text-[0.68rem] font-semibold uppercase tracking-[0.22em] text-stone-500">
                    source
                  </div>
                  <div class="mt-2 text-sm font-medium leading-5 text-stone-700">
                    {(@stats_data && @stats_data.source_label) || "unavailable"}
                  </div>
                </div>
              </div>
            </div>

            <div
              :if={@stats_data && @stats_data.top_types != []}
              class="border-t border-stone-300 bg-stone-950/[0.03] px-4 py-3 sm:px-6"
            >
              <div class="flex flex-wrap gap-2">
                <%= for {type, count} <- @stats_data.top_types do %>
                  <span class="border border-stone-300 bg-white px-2.5 py-1 text-xs font-medium text-stone-700">
                    {type} · {format_count(count)}
                  </span>
                <% end %>
              </div>
            </div>
          </div>

          <%= if @stats_error do %>
            <div class="rounded-md border border-rose-300 bg-rose-50 px-4 py-4 shadow-sm">
              <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <h2 class="text-lg font-semibold text-rose-950">Dictionary load failed</h2>
                  <p class="mt-1 text-sm leading-6 text-rose-800">{inspect(@stats_error)}</p>
                </div>
                <button
                  id="jbo-retry-dictionary"
                  type="button"
                  phx-click="retry-dictionary"
                  class="border border-rose-900 bg-rose-950 px-4 py-2 text-sm font-medium text-white transition hover:bg-rose-900"
                >
                  Retry
                </button>
              </div>
            </div>
          <% end %>

          <div class="grid gap-4 lg:grid-cols-[minmax(0,1.14fr)_minmax(20rem,0.86fr)]">
            <section id="jbo-detail-panel" class="flex flex-col gap-4">
              <%= cond do %>
                <% @lookup_error -> %>
                  <div class="rounded-md border border-rose-300 bg-white px-5 py-5 shadow-sm">
                    <div class="flex items-start gap-3">
                      <div class="flex h-10 w-10 shrink-0 items-center justify-center bg-rose-100 text-rose-700">
                        <.icon name="hero-exclamation-triangle" class="size-5" />
                      </div>
                      <div>
                        <h2 class="text-xl font-semibold text-stone-950">Lookup failed</h2>
                        <p class="mt-2 text-sm leading-6 text-stone-600">
                          {inspect(@lookup_error)}
                        </p>
                      </div>
                    </div>
                  </div>
                <% @query == "" -> %>
                  <div class="overflow-hidden rounded-md border border-stone-300 bg-white shadow-sm">
                    <div class="border-b border-stone-300 px-5 py-4">
                      <div class="text-[0.7rem] font-semibold uppercase tracking-[0.24em] text-stone-500">
                        How it works
                      </div>
                      <h2 class="mt-2 text-2xl font-semibold tracking-tight text-stone-950">
                        Search from whatever fragment you already have.
                      </h2>
                    </div>
                    <div class="grid gap-px bg-stone-300 sm:grid-cols-3">
                      <div class="bg-white px-4 py-4">
                        <div class="mb-3 inline-flex h-9 w-9 items-center justify-center bg-emerald-100 text-emerald-700">
                          <.icon name="hero-language" class="size-5" />
                        </div>
                        <h3 class="font-semibold text-stone-950">Exact valsi</h3>
                        <p class="mt-2 text-sm leading-6 text-stone-600">
                          Jump straight into a word entry and keep rafsi, glosses, and notes together.
                        </p>
                      </div>
                      <div class="bg-white px-4 py-4">
                        <div class="mb-3 inline-flex h-9 w-9 items-center justify-center bg-sky-100 text-sky-700">
                          <.icon name="hero-squares-2x2" class="size-5" />
                        </div>
                        <h3 class="font-semibold text-stone-950">Selma'o and rafsi</h3>
                        <p class="mt-2 text-sm leading-6 text-stone-600">
                          Queries like `UI1` and `bau` surface categories and affixes, not just exact spellings.
                        </p>
                      </div>
                      <div class="bg-white px-4 py-4">
                        <div class="mb-3 inline-flex h-9 w-9 items-center justify-center bg-amber-100 text-amber-700">
                          <.icon name="hero-book-open" class="size-5" />
                        </div>
                        <h3 class="font-semibold text-stone-950">Gloss and note search</h3>
                        <p class="mt-2 text-sm leading-6 text-stone-600">
                          English glosses, place keywords, definitions, and note cross-links all feed the ranking.
                        </p>
                      </div>
                    </div>
                  </div>
                <% @selected_entry -> %>
                  <div class="overflow-hidden rounded-md border border-stone-300 bg-white shadow-sm">
                    <div class="flex flex-col gap-5 p-5 sm:p-6">
                      <div class="flex flex-wrap items-center gap-2">
                        <span class="border border-stone-900 bg-stone-950 px-2.5 py-1 text-[0.68rem] font-semibold uppercase tracking-[0.18em] text-white">
                          {@selected_entry.type}
                        </span>
                        <span
                          :if={@selected_entry.selmaho}
                          class="border border-sky-300 bg-sky-50 px-2.5 py-1 text-[0.68rem] font-semibold uppercase tracking-[0.18em] text-sky-950"
                        >
                          {@selected_entry.selmaho}
                        </span>
                        <span
                          :if={@selected_entry.unofficial}
                          class="border border-amber-300 bg-amber-50 px-2.5 py-1 text-[0.68rem] font-semibold uppercase tracking-[0.18em] text-amber-950"
                        >
                          unofficial
                        </span>
                        <span
                          :if={@selected_entry.experimental}
                          class="border border-fuchsia-300 bg-fuchsia-50 px-2.5 py-1 text-[0.68rem] font-semibold uppercase tracking-[0.18em] text-fuchsia-950"
                        >
                          experimental
                        </span>
                        <span
                          :if={@selected_entry.obsolete}
                          class="border border-rose-300 bg-rose-50 px-2.5 py-1 text-[0.68rem] font-semibold uppercase tracking-[0.18em] text-rose-950"
                        >
                          obsolete
                        </span>
                      </div>

                      <div class="flex flex-col gap-4">
                        <div>
                          <div class="text-[0.7rem] font-semibold uppercase tracking-[0.24em] text-stone-500">
                            {lookup_heading(@lookup_data, @query)}
                          </div>
                          <h2
                            id="jbo-selected-word"
                            class="mt-2 font-serif text-4xl font-semibold tracking-tight text-stone-950 sm:text-5xl"
                          >
                            {@selected_entry.word}
                          </h2>
                          <p
                            :if={@selected_entry.gloss_preview}
                            class="mt-3 text-base leading-7 text-stone-600 sm:text-lg"
                          >
                            {@selected_entry.gloss_preview}
                          </p>
                        </div>

                        <div class="flex flex-wrap gap-2">
                          <%= for rafsi <- @selected_entry.rafsi do %>
                            <span class="border border-stone-300 bg-stone-50 px-3 py-1 text-sm font-medium text-stone-700">
                              -{rafsi}-
                            </span>
                          <% end %>
                          <.link
                            href={"https://jbovlaste.lojban.org/dict/#{URI.encode(@selected_entry.word)}"}
                            id="jbo-external-link"
                            class="border border-stone-300 bg-white px-3 py-1 text-sm font-medium text-stone-700 transition hover:border-stone-500 hover:text-stone-950"
                          >
                            jbovlaste
                          </.link>
                        </div>
                      </div>

                      <div class="border-l-2 border-amber-600 bg-stone-50 px-4 py-4">
                        <div class="text-[0.7rem] font-semibold uppercase tracking-[0.24em] text-stone-500">
                          Definition
                        </div>
                        <p id="jbo-definition" class="mt-3 text-base leading-8 text-stone-800">
                          <%= for segment <- rich_segments(@selected_entry.definition) do %>
                            <%= case segment do %>
                              <% {:text, text} -> %>
                                {text}
                              <% {:xref, word} -> %>
                                <.link
                                  patch={jbo_path(word, word)}
                                  class="border-b border-teal-700/30 text-teal-800 transition hover:border-teal-900 hover:text-teal-950"
                                >
                                  {word}
                                </.link>
                              <% {:place, variable, index} -> %>
                                <span class="bg-stone-950 px-1.5 py-0.5 font-medium text-stone-50">
                                  {variable}
                                  <%= if index do %>
                                    <sub>{index}</sub>
                                  <% end %>
                                </span>
                            <% end %>
                          <% end %>
                        </p>
                      </div>

                      <div
                        :if={@selected_entry.keywords != []}
                        class="border border-stone-300 bg-stone-50 px-4 py-4"
                      >
                        <div class="text-[0.7rem] font-semibold uppercase tracking-[0.24em] text-stone-500">
                          Place keywords
                        </div>
                        <div class="mt-3 flex flex-wrap gap-2">
                          <%= for keyword <- @selected_entry.keywords do %>
                            <span class="border border-stone-300 bg-white px-3 py-1 text-sm text-stone-700">
                              <span :if={keyword.place} class="font-semibold text-stone-950">
                                x<sub>{keyword.place}</sub>
                              </span>
                              {(keyword.place && " ") || ""}
                              {keyword.word}
                              <span :if={keyword.sense} class="text-stone-500">
                                ({keyword.sense})
                              </span>
                            </span>
                          <% end %>
                        </div>
                      </div>

                      <div
                        :if={@selected_entry.notes}
                        class="border border-stone-300 bg-stone-50 px-4 py-4"
                      >
                        <div class="text-[0.7rem] font-semibold uppercase tracking-[0.24em] text-stone-500">
                          Notes
                        </div>
                        <p id="jbo-notes" class="mt-3 text-sm leading-7 text-stone-700 sm:text-base">
                          <%= for segment <- rich_segments(@selected_entry.notes) do %>
                            <%= case segment do %>
                              <% {:text, text} -> %>
                                {text}
                              <% {:xref, word} -> %>
                                <.link
                                  patch={jbo_path(word, word)}
                                  class="border-b border-teal-700/30 text-teal-800 transition hover:border-teal-900 hover:text-teal-950"
                                >
                                  {word}
                                </.link>
                              <% {:place, variable, index} -> %>
                                <span class="bg-stone-950 px-1.5 py-0.5 font-medium text-stone-50">
                                  {variable}
                                  <%= if index do %>
                                    <sub>{index}</sub>
                                  <% end %>
                                </span>
                            <% end %>
                          <% end %>
                        </p>
                      </div>

                      <div class="flex flex-wrap items-center gap-x-4 gap-y-2 text-sm text-stone-500">
                        <span :if={@selected_entry.author_username}>
                          by {@selected_entry.author_username}
                        </span>
                        <span :if={@selected_entry.definition_id}>
                          definition {@selected_entry.definition_id}
                        </span>
                      </div>
                    </div>
                  </div>

                  <div
                    :if={@lookup_data.selmaho_matches != [] or @lookup_data.rafsi_matches != []}
                    class="grid gap-4 sm:grid-cols-2"
                  >
                    <div
                      :if={@lookup_data.selmaho_matches != []}
                      class="rounded-md border border-stone-300 bg-white px-4 py-4 shadow-sm"
                    >
                      <div class="text-[0.7rem] font-semibold uppercase tracking-[0.24em] text-stone-500">
                        More in this selma'o
                      </div>
                      <div class="mt-3 flex flex-wrap gap-2">
                        <%= for entry <- @lookup_data.selmaho_matches do %>
                          <.link
                            patch={jbo_path(entry.word, entry.word)}
                            class="border border-stone-300 bg-stone-50 px-3 py-1.5 text-sm font-medium text-stone-700 transition hover:border-sky-500 hover:bg-white hover:text-stone-950"
                          >
                            {entry.word}
                          </.link>
                        <% end %>
                      </div>
                    </div>

                    <div
                      :if={@lookup_data.rafsi_matches != []}
                      class="rounded-md border border-stone-300 bg-white px-4 py-4 shadow-sm"
                    >
                      <div class="text-[0.7rem] font-semibold uppercase tracking-[0.24em] text-stone-500">
                        Shares this rafsi
                      </div>
                      <div class="mt-3 flex flex-wrap gap-2">
                        <%= for entry <- @lookup_data.rafsi_matches do %>
                          <.link
                            patch={jbo_path(entry.word, entry.word)}
                            class="border border-stone-300 bg-stone-50 px-3 py-1.5 text-sm font-medium text-stone-700 transition hover:border-emerald-500 hover:bg-white hover:text-stone-950"
                          >
                            {entry.word}
                          </.link>
                        <% end %>
                      </div>
                    </div>
                  </div>
                <% @query != "" -> %>
                  <div class="rounded-md border border-stone-300 bg-white px-5 py-5 shadow-sm">
                    <div class="flex items-start gap-3">
                      <div class="flex h-10 w-10 shrink-0 items-center justify-center bg-stone-950 text-white">
                        <.icon name="hero-magnifying-glass" class="size-5" />
                      </div>
                      <div>
                        <h2 class="text-xl font-semibold text-stone-950">No direct match yet</h2>
                        <p class="mt-2 text-sm leading-6 text-stone-600">
                          Try a plain valsi, a rafsi like `bau`, or a selma'o like `UI1`. English gloss search also works.
                        </p>
                      </div>
                    </div>
                  </div>
              <% end %>
            </section>

            <aside class="flex flex-col gap-4">
              <div class="overflow-hidden rounded-md border border-stone-300 bg-white shadow-sm">
                <div class="border-b border-stone-300 px-5 py-4">
                  <div class="text-[0.7rem] font-semibold uppercase tracking-[0.24em] text-stone-500">
                    Matches
                  </div>
                  <div class="mt-1 text-lg font-semibold tracking-tight text-stone-950">
                    <%= if @query == "" do %>
                      Start with a word or gloss
                    <% else %>
                      {results_label(@results_count)}
                    <% end %>
                  </div>
                  <div
                    :if={@query != ""}
                    class="mt-2 inline-flex border border-stone-300 bg-stone-50 px-3 py-1 text-sm text-stone-600"
                  >
                    {@query}
                  </div>
                </div>

                <div id="jbo-results" phx-update="stream" class="flex flex-col">
                  <div
                    :if={@query == ""}
                    id="jbo-results-empty-hint"
                    class="px-5 py-5 text-sm leading-6 text-stone-600"
                  >
                    Search results land here immediately, with the strongest match promoted into the reference panel.
                  </div>

                  <div
                    :if={@query != "" and @results_empty?}
                    id="jbo-results-empty"
                    class="px-5 py-5 text-sm leading-6 text-stone-500"
                  >
                    No secondary results to show.
                  </div>

                  <div
                    :for={{dom_id, result} <- @streams.results}
                    id={dom_id}
                    class={[
                      "border-t border-stone-300 first:border-t-0",
                      @selected_entry && result.word == @selected_entry.word && "bg-amber-50"
                    ]}
                  >
                    <.link
                      patch={jbo_path(@query, result.word)}
                      class="block px-5 py-4 transition hover:bg-stone-50"
                    >
                      <div class="flex items-start justify-between gap-3">
                        <div class="min-w-0">
                          <div class="flex flex-wrap items-center gap-2">
                            <h3 class="font-serif text-xl font-semibold tracking-tight text-stone-950">
                              {result.word}
                            </h3>
                            <span class="border border-stone-300 bg-white px-2 py-1 text-[0.68rem] font-semibold uppercase tracking-[0.18em] text-stone-500">
                              {result.type}
                            </span>
                            <span
                              :if={result.selmaho}
                              class="border border-sky-300 bg-sky-50 px-2 py-1 text-[0.68rem] font-semibold uppercase tracking-[0.18em] text-sky-950"
                            >
                              {result.selmaho}
                            </span>
                          </div>

                          <p :if={result.gloss} class="mt-2 text-sm font-medium text-stone-700">
                            {result.gloss}
                          </p>
                          <p :if={result.preview} class="mt-2 text-sm leading-6 text-stone-600">
                            {result.preview}
                          </p>
                        </div>

                        <div class="flex shrink-0 items-center text-stone-400">
                          <.icon name="hero-arrow-up-right" class="size-5" />
                        </div>
                      </div>

                      <div class="mt-3 flex flex-wrap gap-2">
                        <%= for reason <- result.reasons do %>
                          <span class="border border-stone-300 bg-stone-50 px-2.5 py-1 text-[0.72rem] font-medium text-stone-600">
                            {reason}
                          </span>
                        <% end %>
                      </div>
                    </.link>
                  </div>
                </div>
              </div>

              <div
                :if={@stats_data}
                class="rounded-md border border-stone-300 bg-white px-5 py-4 text-sm leading-6 text-stone-600 shadow-sm"
              >
                <div class="text-[0.7rem] font-semibold uppercase tracking-[0.24em] text-stone-500">
                  Source note
                </div>
                <p class="mt-3">
                  <%= if @stats_data.source_url do %>
                    Data comes from <a
                      href={@stats_data.source_url}
                      class="border-b border-teal-700/30 text-teal-800 transition hover:border-teal-900 hover:text-teal-950"
                    >
                      {@stats_data.source_label}
                    </a>.
                  <% else %>
                    Local source: {@stats_data.source_label}.
                  <% end %>
                  <span :if={@stats_data.source_last_modified}>
                    Last updated {@stats_data.source_last_modified}.
                  </span>
                  <span :if={@stats_data.source_path}>
                    Source file: {Path.relative_to_cwd(@stats_data.source_path)}.
                  </span>
                </p>
              </div>
            </aside>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp load_page_data(socket, query, selected_param) do
    {stats, stats_error} =
      case Froth.Jbo.Dictionary.summary() do
        {:ok, summary} -> {summary, nil}
        {:error, reason} -> {nil, reason}
      end

    {lookup, lookup_error} =
      case query do
        "" ->
          {blank_lookup(), nil}

        _query ->
          case Froth.Jbo.Dictionary.lookup(query, selected_param) do
            {:ok, result} -> {result, nil}
            {:error, reason} -> {blank_lookup() |> Map.put(:query, query), reason}
          end
      end

    socket
    |> assign(:stats, stats)
    |> assign(:stats_error, stats_error)
    |> assign(:lookup, lookup)
    |> assign(:lookup_error, lookup_error)
    |> assign(:results_count, length(lookup.results))
    |> assign(:results_empty?, lookup.results == [])
    |> stream(:results, lookup.results, reset: true)
  end

  defp blank_lookup do
    %{
      query: "",
      normalized_query: "",
      exact: nil,
      selected: nil,
      selected_word: nil,
      results: [],
      selmaho_matches: [],
      rafsi_matches: [],
      summary: nil
    }
  end

  defp sanitize_query(nil), do: ""

  defp sanitize_query(query) do
    query
    |> to_string()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp blank_to("", fallback), do: fallback
  defp blank_to(value, _fallback), do: value

  defp results_label(1), do: "1 strong match"
  defp results_label(count), do: "#{format_count(count)} strong matches"

  defp lookup_heading(%{exact: exact}, _query) when not is_nil(exact), do: "Exact entry"

  defp lookup_heading(%{query: query}, _current_query) when is_binary(query) and query != "" do
    "Best match"
  end

  defp lookup_heading(_lookup, _query), do: "Reference"

  defp rich_segments(nil), do: []

  defp rich_segments(text) do
    Regex.split(~r/(\{[^}]+\}|\$[a-z]+(?:_\d+)?\$)/u, text, include_captures: true, trim: true)
    |> Enum.map(fn segment ->
      cond do
        Regex.match?(~r/^\{[^}]+\}$/u, segment) ->
          word =
            segment
            |> String.trim_leading("{")
            |> String.trim_trailing("}")
            |> String.trim()

          {:xref, word}

        Regex.match?(~r/^\$([a-z]+)(?:_(\d+))?\$$/u, segment) ->
          [_, variable, index] = Regex.run(~r/^\$([a-z]+)(?:_(\d+))?\$$/u, segment)
          {:place, variable, index}

        true ->
          {:text, segment}
      end
    end)
  end

  defp jbo_path(query, entry) do
    []
    |> maybe_param(:q, query)
    |> maybe_param(:entry, entry)
    |> then(&~p"/jbo?#{&1}")
  end

  defp maybe_param(params, _key, nil), do: params
  defp maybe_param(params, _key, ""), do: params
  defp maybe_param(params, key, value), do: Keyword.put(params, key, value)

  defp dom_safe(word) do
    word
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp format_count(number) when is_integer(number) and number < 1000,
    do: Integer.to_string(number)

  defp format_count(number) when is_integer(number) do
    format_count(div(number, 1000)) <>
      "," <> String.pad_leading(Integer.to_string(rem(number, 1000)), 3, "0")
  end
end
