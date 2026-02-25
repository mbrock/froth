defmodule FrothWeb.InferenceSessionsLive do
  use FrothWeb, :live_view

  import Ecto.Query

  alias Froth.Inference.InferenceSession
  alias Froth.Repo

  @default_limit 120
  @max_limit 500
  @max_json_chars 200_000

  @status_values ~w(all pending streaming awaiting_tools done error stopped)

  @status_options [
    {"all", "all"},
    {"pending", "pending"},
    {"streaming", "streaming"},
    {"awaiting_tools", "awaiting_tools"},
    {"done", "done"},
    {"error", "error"},
    {"stopped", "stopped"}
  ]

  @sections [
    %{key: :pending_tools, title: "Pending Tools"},
    %{key: :queued_messages, title: "Queued Messages"},
    %{key: :tool_steps, title: "Tool Steps"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    filters = default_filters()

    {:ok,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_query, %{})
     |> assign(:max_limit, @max_limit)
     |> assign(:max_json_chars, @max_json_chars)
     |> assign(:filter_form, to_form(filter_form_values(filters), as: :filters))
     |> assign(:session_summaries, [])
     |> assign(:matching_count, 0)
     |> assign(:selected_session, nil)
     |> assign(:selected_session_id, nil)
     |> assign(:selected_sections, empty_sections())
     |> assign(:status_options, @status_options)
     |> assign(:sections, @sections)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = normalize_filters(params)
    requested_session_id = parse_optional_integer(params["id"])

    {:noreply, load_page(socket, filters, requested_session_id)}
  end

  @impl true
  def handle_event("apply_filters", %{"filters" => params}, socket) do
    filters = normalize_filters(params)
    {:noreply, push_patch(socket, to: sessions_path(nil, filter_query_params(filters)))}
  end

  def handle_event("clear_filters", _params, socket) do
    filters = default_filters()
    {:noreply, push_patch(socket, to: sessions_path(nil, filter_query_params(filters)))}
  end

  def handle_event("refresh", _params, socket) do
    filters = socket.assigns.filters
    selected_session_id = socket.assigns.selected_session_id
    {:noreply, load_page(socket, filters, selected_session_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div id="inference-sessions-page" class="min-h-screen bg-black text-zinc-100 text-[13px]">
        <header class="sticky top-0 z-30 border-b border-white/10 bg-black/95 backdrop-blur">
          <div class="mx-auto flex max-w-[1500px] items-center justify-between gap-3 px-3 py-2">
            <div class="min-w-0">
              <h1 class="text-[14px] font-semibold text-white">Inference Sessions</h1>
              <p class="text-[11px] text-zinc-400">
                {@matching_count} matching sessions
              </p>
            </div>

            <div class="flex items-center gap-2">
              <button
                id="inference-sessions-refresh"
                phx-click="refresh"
                class="rounded border border-white/20 px-2 py-1 text-[11px] text-zinc-200 transition-colors hover:border-white/45"
              >
                Refresh
              </button>
              <.link
                navigate={~p"/froth"}
                class="rounded border border-white/10 px-2 py-1 text-[11px] text-zinc-400 transition-colors hover:border-white/25 hover:text-zinc-200"
              >
                Back
              </.link>
            </div>
          </div>
        </header>

        <main class="mx-auto grid max-w-[1500px] grid-cols-1 gap-3 px-3 pb-5 pt-3 xl:grid-cols-[420px_minmax(0,1fr)]">
          <section class="overflow-hidden rounded border border-white/10 bg-white/[0.03]">
            <.form
              for={@filter_form}
              id="inference-sessions-filter-form"
              phx-submit="apply_filters"
              class="space-y-2 border-b border-white/10 px-3 py-3"
            >
              <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
                <.input
                  field={@filter_form[:bot_id]}
                  type="text"
                  label="Bot"
                  variant="bare"
                  placeholder="charlie"
                  class="w-full rounded border border-white/20 bg-black/35 px-2 py-1.5 text-[12px] text-white placeholder:text-zinc-500 focus:border-white/45 focus:outline-none"
                />

                <.input
                  field={@filter_form[:chat_id]}
                  type="text"
                  label="Chat"
                  variant="bare"
                  placeholder="chat_id"
                  class="w-full rounded border border-white/20 bg-black/35 px-2 py-1.5 text-[12px] text-white placeholder:text-zinc-500 focus:border-white/45 focus:outline-none"
                />
              </div>

              <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
                <.input
                  field={@filter_form[:status]}
                  type="select"
                  label="Status"
                  options={@status_options}
                  class="w-full rounded border border-white/20 bg-black px-2 py-1.5 text-[12px] text-white focus:border-white/45 focus:outline-none"
                />

                <.input
                  field={@filter_form[:limit]}
                  type="number"
                  label="Rows"
                  min="1"
                  max={to_string(@max_limit)}
                  variant="bare"
                  class="w-full rounded border border-white/20 bg-black/35 px-2 py-1.5 text-[12px] text-white placeholder:text-zinc-500 focus:border-white/45 focus:outline-none"
                />
              </div>

              <div class="flex items-center gap-2 pt-1">
                <button
                  id="inference-sessions-apply-filters"
                  type="submit"
                  class="rounded border border-white/35 px-2.5 py-1 text-[11px] text-white transition-colors hover:border-white/55"
                >
                  Apply
                </button>
                <button
                  id="inference-sessions-clear-filters"
                  type="button"
                  phx-click="clear_filters"
                  class="rounded border border-white/20 px-2.5 py-1 text-[11px] text-zinc-300 transition-colors hover:border-white/40"
                >
                  Clear
                </button>
                <span class="ml-auto text-[11px] text-zinc-400">
                  showing {length(@session_summaries)}
                </span>
              </div>
            </.form>

            <div id="inference-session-list" class="max-h-[calc(100vh-300px)] overflow-y-auto">
              <.link
                :for={summary <- @session_summaries}
                patch={sessions_path(summary.id, @filter_query)}
                id={"inference-session-#{summary.id}"}
                class={[
                  "block border-t border-white/5 px-3 py-2 transition-colors first:border-t-0",
                  if(@selected_session_id == summary.id,
                    do: "bg-white/10",
                    else: "hover:bg-white/[0.06]"
                  )
                ]}
              >
                <div class="flex items-center justify-between gap-2">
                  <span class="font-mono text-[12px] text-zinc-100">{summary.id}</span>
                  <span class={[
                    "rounded border px-1.5 py-0.5 text-[10px] uppercase tracking-wide",
                    status_badge_class(summary.status)
                  ]}>
                    {summary.status}
                  </span>
                </div>

                <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-zinc-400">
                  <span>bot: {summary.bot_id || "-"}</span>
                  <span>chat: {summary.chat_id}</span>
                  <span>reply_to: {summary.reply_to || "-"}</span>
                </div>

                <div class="mt-1 text-[11px] text-zinc-500">
                  api {summary.api_count} · pending {summary.pending_count} · queued {summary.queued_count} · steps {summary.step_count}
                </div>

                <div class="mt-1 text-[10px] text-zinc-600">
                  {format_timestamp(summary.inserted_at)}
                </div>
              </.link>

              <div :if={@session_summaries == []} class="px-3 py-8 text-center text-zinc-500">
                No inference sessions matched these filters.
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <%= if @selected_session do %>
              <div
                id="inference-session-detail"
                class="rounded border border-white/10 bg-white/[0.03] p-3"
              >
                <div class="flex flex-wrap items-center gap-2">
                  <h2 class="font-mono text-[13px] text-white">
                    session_{@selected_session.id}
                  </h2>
                  <span class={[
                    "rounded border px-1.5 py-0.5 text-[10px] uppercase tracking-wide",
                    status_badge_class(@selected_session.status)
                  ]}>
                    {@selected_session.status}
                  </span>
                </div>

                <dl class="mt-3 grid grid-cols-1 gap-2 text-[12px] text-zinc-300 md:grid-cols-2">
                  <div>
                    <dt class="text-zinc-500">bot</dt>
                    <dd class="font-mono">{@selected_session.bot_id || "-"}</dd>
                  </div>
                  <div>
                    <dt class="text-zinc-500">chat_id</dt>
                    <dd class="font-mono">{@selected_session.chat_id}</dd>
                  </div>
                  <div>
                    <dt class="text-zinc-500">reply_to</dt>
                    <dd class="font-mono">{@selected_session.reply_to || "-"}</dd>
                  </div>
                  <div>
                    <dt class="text-zinc-500">inserted_at</dt>
                    <dd class="font-mono">{format_timestamp(@selected_session.inserted_at)}</dd>
                  </div>
                  <div>
                    <dt class="text-zinc-500">updated_at</dt>
                    <dd class="font-mono">{format_timestamp(@selected_session.updated_at)}</dd>
                  </div>
                </dl>
              </div>

              <.api_messages_panel messages={api_messages_for_view(@selected_session.api_messages)} />

              <details
                :for={section <- @sections}
                id={"inference-section-#{section.key}"}
                class="overflow-hidden rounded border border-white/10 bg-white/[0.03]"
                open
              >
                <% details =
                  Map.get(@selected_sections, section.key, %{count: 0, json: "[]", truncated: false}) %>
                <summary class="cursor-pointer select-none px-3 py-2 text-[12px] text-zinc-200">
                  <span class="font-medium">{section.title}</span>
                  <span class="ml-2 text-zinc-500">({details.count})</span>
                </summary>
                <div class="border-t border-white/10 px-3 py-2">
                  <p :if={details.truncated} class="mb-2 text-[11px] text-amber-300/90">
                    Preview truncated at {@max_json_chars} characters.
                  </p>
                  <pre
                    id={"inference-#{section.key}-json"}
                    class="max-h-[34rem] overflow-auto whitespace-pre-wrap rounded border border-white/10 bg-black/45 p-3 font-mono text-[11px] leading-relaxed text-zinc-200"
                  >{details.json}</pre>
                </div>
              </details>
            <% else %>
              <div class="rounded border border-white/10 bg-white/[0.03] px-3 py-12 text-center text-zinc-500">
                No inference sessions available yet.
              </div>
            <% end %>
          </section>
        </main>
      </div>
    </Layouts.app>
    """
  end

  defp load_page(socket, filters, requested_session_id) do
    session_summaries = list_session_summaries(filters)
    matching_count = count_matching_sessions(filters)
    selected_session = select_session(requested_session_id, session_summaries)
    selected_session_id = selected_session && selected_session.id

    socket
    |> assign(:filters, filters)
    |> assign(:filter_query, filter_query_params(filters))
    |> assign(:filter_form, to_form(filter_form_values(filters), as: :filters))
    |> assign(:session_summaries, session_summaries)
    |> assign(:matching_count, matching_count)
    |> assign(:selected_session, selected_session)
    |> assign(:selected_session_id, selected_session_id)
    |> assign(:selected_sections, section_payloads(selected_session))
  end

  defp sessions_path(nil, params), do: ~p"/froth/inference?#{params}"
  defp sessions_path(id, params) when is_integer(id), do: ~p"/froth/inference/#{id}?#{params}"

  defp select_session(requested_session_id, summaries) when is_list(summaries) do
    selected_session =
      case requested_session_id do
        id when is_integer(id) -> Repo.get(InferenceSession, id)
        _ -> nil
      end

    case selected_session do
      %InferenceSession{} = inference_session ->
        inference_session

      _ ->
        case summaries do
          [%{id: id} | _] -> Repo.get(InferenceSession, id)
          _ -> nil
        end
    end
  end

  defp list_session_summaries(filters) do
    sessions_base_query(filters)
    |> order_by([s], desc: s.inserted_at, desc: s.id)
    |> limit(^filters.limit)
    |> select([s], %{
      id: s.id,
      bot_id: s.bot_id,
      chat_id: s.chat_id,
      reply_to: s.reply_to,
      status: s.status,
      inserted_at: s.inserted_at,
      updated_at: s.updated_at,
      api_count: fragment("jsonb_array_length(COALESCE(?, '[]'::jsonb))", s.api_messages),
      pending_count: fragment("jsonb_array_length(COALESCE(?, '[]'::jsonb))", s.pending_tools),
      queued_count: fragment("jsonb_array_length(COALESCE(?, '[]'::jsonb))", s.queued_messages),
      step_count: fragment("jsonb_array_length(COALESCE(?, '[]'::jsonb))", s.tool_steps)
    })
    |> Repo.all(log: false)
  end

  defp count_matching_sessions(filters) do
    sessions_base_query(filters)
    |> select([s], count(s.id))
    |> Repo.one(log: false)
    |> case do
      nil -> 0
      count -> count
    end
  end

  defp sessions_base_query(filters) do
    InferenceSession
    |> maybe_filter_bot(filters.bot_id)
    |> maybe_filter_chat(filters.chat_id)
    |> maybe_filter_status(filters.status)
  end

  defp maybe_filter_bot(query, nil), do: query
  defp maybe_filter_bot(query, bot_id), do: from(s in query, where: s.bot_id == ^bot_id)

  defp maybe_filter_chat(query, nil), do: query
  defp maybe_filter_chat(query, chat_id), do: from(s in query, where: s.chat_id == ^chat_id)

  defp maybe_filter_status(query, "all"), do: query
  defp maybe_filter_status(query, status), do: from(s in query, where: s.status == ^status)

  defp section_payloads(nil), do: empty_sections()

  defp section_payloads(%InferenceSession{} = inference_session) do
    %{
      pending_tools: build_section(inference_session.pending_tools),
      queued_messages: build_section(inference_session.queued_messages),
      tool_steps: build_section(inference_session.tool_steps)
    }
  end

  defp empty_sections do
    Enum.into(@sections, %{}, fn %{key: key} ->
      {key, %{count: 0, json: "[]", truncated: false}}
    end)
  end

  defp build_section(value) when is_list(value) do
    {json, truncated} = encode_json(value)
    %{count: length(value), json: json, truncated: truncated}
  end

  defp build_section(value) do
    {json, truncated} = encode_json(value)
    %{count: 0, json: json, truncated: truncated}
  end

  defp encode_json(value) do
    json =
      case Jason.encode(value, pretty: true) do
        {:ok, encoded} -> encoded
        _ -> inspect(value, pretty: true, limit: :infinity, printable_limit: 500_000)
      end

    if String.length(json) > @max_json_chars do
      {
        String.slice(json, 0, @max_json_chars) <>
          "\n... [truncated, use psql or iex for full value]",
        true
      }
    else
      {json, false}
    end
  end

  defp filter_form_values(filters) do
    %{
      "bot_id" => filters.bot_id || "",
      "chat_id" =>
        if(is_integer(filters.chat_id), do: Integer.to_string(filters.chat_id), else: ""),
      "status" => filters.status,
      "limit" => Integer.to_string(filters.limit)
    }
  end

  defp filter_query_params(filters) do
    %{}
    |> maybe_put_query("bot_id", filters.bot_id)
    |> maybe_put_query(
      "chat_id",
      if(is_integer(filters.chat_id), do: Integer.to_string(filters.chat_id), else: nil)
    )
    |> maybe_put_query("status", if(filters.status == "all", do: nil, else: filters.status))
    |> maybe_put_query(
      "limit",
      if(filters.limit == @default_limit, do: nil, else: Integer.to_string(filters.limit))
    )
  end

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  defp default_filters do
    %{bot_id: nil, chat_id: nil, status: "all", limit: @default_limit}
  end

  defp normalize_filters(params) when is_map(params) do
    params = stringify_keys(params)

    %{
      bot_id: normalize_text(params["bot_id"]),
      chat_id: parse_optional_integer(params["chat_id"]),
      status: normalize_status(params["status"]),
      limit: parse_limit(params["limit"])
    }
  end

  defp normalize_filters(_), do: default_filters()

  defp normalize_status(status) when is_binary(status) do
    status = String.trim(status)
    if status in @status_values, do: status, else: "all"
  end

  defp normalize_status(_), do: "all"

  defp parse_limit(value) do
    case parse_optional_integer(value) do
      n when is_integer(n) and n > 0 -> min(n, @max_limit)
      _ -> @default_limit
    end
  end

  defp parse_optional_integer(value) when is_integer(value), do: value

  defp parse_optional_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_optional_integer(_), do: nil

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_text(_), do: nil

  defp stringify_keys(map) do
    Enum.into(map, %{}, fn {key, value} ->
      {to_string(key), value}
    end)
  end

  defp format_timestamp(%NaiveDateTime{} = dt) do
    dt
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_string()
    |> Kernel.<>("Z")
  end

  defp format_timestamp(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_timestamp(_), do: "-"

  attr :messages, :list, default: []

  defp api_messages_panel(assigns) do
    ~H"""
    <details
      id="inference-section-api-messages"
      class="overflow-hidden rounded border border-white/10 bg-white/[0.03]"
      open
    >
      <summary class="cursor-pointer select-none px-3 py-2 text-[12px] text-zinc-200">
        <span class="font-medium">API Messages</span>
        <span class="ml-2 text-zinc-500">({length(@messages)})</span>
        <span class="ml-2 text-zinc-600">oldest first</span>
      </summary>
      <div class="border-t border-white/10 px-3 py-2">
        <div
          :if={@messages == []}
          class="rounded bg-black/35 px-3 py-8 text-center text-zinc-500"
        >
          No API messages persisted for this session.
        </div>

        <div :if={@messages != []} class="max-h-[46rem] space-y-1 overflow-y-auto pr-1">
          <article
            :for={message <- @messages}
            id={"inference-api-message-#{message.index}"}
            class="rounded bg-white/[0.03] px-2.5 py-2"
          >
            <div class="mb-2 flex items-center justify-between gap-2">
              <div class="flex items-center gap-2">
                <span class="font-mono text-[11px] text-zinc-500">{"m#{message.index}"}</span>
                <span class={[
                  "rounded border px-1.5 py-0.5 text-[10px] uppercase tracking-wide",
                  api_role_class(message.role)
                ]}>
                  {message.role}
                </span>
              </div>
              <span class="text-[10px] text-zinc-600">{api_content_kind_label(message.content)}</span>
            </div>

            <.api_message_content content={message.content} />
          </article>
        </div>
      </div>
    </details>
    """
  end

  attr :content, :any, required: true

  defp api_message_content(assigns) do
    ~H"""
    <%= cond do %>
      <% is_binary(@content) -> %>
        <pre class="whitespace-pre-wrap break-words rounded bg-black/35 p-2 font-mono text-[11px] leading-relaxed text-zinc-200">{@content}</pre>
      <% is_list(@content) -> %>
        <div class="space-y-2">
          <div
            :for={{block, idx} <- Enum.with_index(@content, 1)}
            class="border-l border-white/10 pl-2"
          >
            <div class="mb-1 text-[10px] text-zinc-500">
              {"block #{idx} · #{api_block_kind(block)}"}
            </div>

            <% block_text = api_block_text(block) %>
            <pre
              :if={is_binary(block_text)}
              class="whitespace-pre-wrap break-words rounded bg-black/35 p-2 font-mono text-[11px] leading-relaxed text-zinc-200"
            >{block_text}</pre>

            <% block_json = api_block_json(block) %>
            <pre
              :if={is_binary(block_json)}
              class="mt-1 max-h-72 overflow-auto whitespace-pre-wrap break-words rounded bg-black/35 p-2 font-mono text-[11px] leading-relaxed text-zinc-300"
            >{block_json}</pre>
          </div>
        </div>
      <% true -> %>
        <pre class="max-h-96 overflow-auto whitespace-pre-wrap break-words rounded bg-black/35 p-2 font-mono text-[11px] leading-relaxed text-zinc-300">{pretty_json(@content)}</pre>
    <% end %>
    """
  end

  defp api_messages_for_view(messages) when is_list(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.map(fn {message, index} ->
      %{
        index: index,
        role: api_message_role(message),
        content: api_message_content_value(message)
      }
    end)
  end

  defp api_messages_for_view(_), do: []

  defp api_message_role(message) when is_map(message) do
    role =
      Map.get(message, "role") ||
        Map.get(message, :role)

    if is_binary(role) and role != "", do: role, else: "unknown"
  end

  defp api_message_role(_), do: "unknown"

  defp api_message_content_value(message) when is_map(message) do
    Map.get(message, "content") || Map.get(message, :content)
  end

  defp api_message_content_value(_), do: nil

  defp api_content_kind_label(content) when is_binary(content), do: "string"
  defp api_content_kind_label(content) when is_list(content), do: "#{length(content)} blocks"
  defp api_content_kind_label(content) when is_map(content), do: "map"
  defp api_content_kind_label(nil), do: "empty"
  defp api_content_kind_label(_), do: "value"

  defp api_block_kind(block) when is_map(block) do
    case Map.get(block, "type") || Map.get(block, :type) do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> "block"
    end
  end

  defp api_block_kind(_), do: "block"

  defp api_block_text(block) when is_map(block) do
    cond do
      is_binary(Map.get(block, "text")) ->
        Map.get(block, "text")

      is_binary(Map.get(block, :text)) ->
        Map.get(block, :text)

      is_binary(Map.get(block, "thinking")) ->
        Map.get(block, "thinking")

      is_binary(Map.get(block, :thinking)) ->
        Map.get(block, :thinking)

      is_binary(Map.get(block, "content")) and api_block_kind(block) == "tool_result" ->
        Map.get(block, "content")

      is_binary(Map.get(block, :content)) and api_block_kind(block) == "tool_result" ->
        Map.get(block, :content)

      true ->
        nil
    end
  end

  defp api_block_text(_), do: nil

  defp api_block_json(block) when is_map(block) do
    type = api_block_kind(block)

    cond do
      type in ["text", "thinking"] ->
        nil

      type == "tool_use" ->
        input = Map.get(block, "input") || Map.get(block, :input)
        if(is_nil(input), do: pretty_json(block), else: pretty_json(input))

      true ->
        pretty_json(block)
    end
  end

  defp api_block_json(_), do: nil

  defp pretty_json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, encoded} -> encoded
      _ -> inspect(value, pretty: true, limit: :infinity, printable_limit: 500_000)
    end
  end

  defp status_badge_class("done"), do: "border-emerald-500/30 bg-emerald-500/10 text-emerald-300"
  defp status_badge_class("error"), do: "border-red-500/30 bg-red-500/10 text-red-300"

  defp status_badge_class("awaiting_tools"),
    do: "border-amber-500/35 bg-amber-500/10 text-amber-300"

  defp status_badge_class("streaming"), do: "border-sky-500/35 bg-sky-500/10 text-sky-300"
  defp status_badge_class("pending"), do: "border-violet-500/35 bg-violet-500/10 text-violet-300"
  defp status_badge_class("stopped"), do: "border-zinc-500/35 bg-zinc-500/10 text-zinc-300"
  defp status_badge_class(_), do: "border-white/20 bg-white/5 text-zinc-300"

  defp api_role_class("user"), do: "border-emerald-500/30 bg-emerald-500/10 text-emerald-300"
  defp api_role_class("assistant"), do: "border-sky-500/30 bg-sky-500/10 text-sky-300"
  defp api_role_class(_), do: "border-white/20 bg-white/5 text-zinc-300"
end
