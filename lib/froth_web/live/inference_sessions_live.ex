defmodule FrothWeb.InferenceSessionsLive do
  use FrothWeb, :live_view

  import Ecto.Query

  alias Froth.Agent
  alias Froth.Agent.{Cycle, Message}
  alias Froth.Telegram.CycleLink
  alias Froth.Repo

  @default_limit 120
  @max_limit 500

  @impl true
  def mount(_params, _session, socket) do
    filters = default_filters()

    {:ok,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_query, %{})
     |> assign(:max_limit, @max_limit)
     |> assign(:filter_form, to_form(filter_form_values(filters), as: :filters))
     |> assign(:cycle_summaries, [])
     |> assign(:matching_count, 0)
     |> assign(:selected_cycle, nil)
     |> assign(:selected_cycle_id, nil)
     |> assign(:selected_messages, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = normalize_filters(params)
    requested_id = params["id"]

    {:noreply, load_page(socket, filters, requested_id)}
  end

  @impl true
  def handle_event("apply_filters", %{"filters" => params}, socket) do
    filters = normalize_filters(params)
    {:noreply, push_patch(socket, to: cycles_path(nil, filter_query_params(filters)))}
  end

  def handle_event("clear_filters", _params, socket) do
    filters = default_filters()
    {:noreply, push_patch(socket, to: cycles_path(nil, filter_query_params(filters)))}
  end

  def handle_event("refresh", _params, socket) do
    filters = socket.assigns.filters
    selected_id = socket.assigns.selected_cycle_id
    {:noreply, load_page(socket, filters, selected_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div id="cycles-page" class="min-h-screen bg-black text-zinc-100 text-[13px]">
        <header class="sticky top-0 z-30 border-b border-white/10 bg-black/95 backdrop-blur">
          <div class="mx-auto flex max-w-[1500px] items-center justify-between gap-3 px-3 py-2">
            <div class="min-w-0">
              <h1 class="text-[14px] font-semibold text-white">Agent Cycles</h1>
              <p class="text-[11px] text-zinc-400">
                {@matching_count} matching cycles
              </p>
            </div>

            <div class="flex items-center gap-2">
              <button
                id="cycles-refresh"
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
              id="cycles-filter-form"
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
                  id="cycles-apply-filters"
                  type="submit"
                  class="rounded border border-white/35 px-2.5 py-1 text-[11px] text-white transition-colors hover:border-white/55"
                >
                  Apply
                </button>
                <button
                  id="cycles-clear-filters"
                  type="button"
                  phx-click="clear_filters"
                  class="rounded border border-white/20 px-2.5 py-1 text-[11px] text-zinc-300 transition-colors hover:border-white/40"
                >
                  Clear
                </button>
                <span class="ml-auto text-[11px] text-zinc-400">
                  showing {length(@cycle_summaries)}
                </span>
              </div>
            </.form>

            <div id="cycle-list" class="max-h-[calc(100vh-300px)] overflow-y-auto">
              <.link
                :for={summary <- @cycle_summaries}
                patch={cycles_path(summary.cycle_id, @filter_query)}
                id={"cycle-#{summary.cycle_id}"}
                class={[
                  "block border-t border-white/5 px-3 py-2 transition-colors first:border-t-0",
                  if(@selected_cycle_id == summary.cycle_id,
                    do: "bg-white/10",
                    else: "hover:bg-white/[0.06]"
                  )
                ]}
              >
                <div class="flex items-center justify-between gap-2">
                  <span class="font-mono text-[12px] text-zinc-100 truncate">
                    {String.slice(summary.cycle_id, 0, 16)}..
                  </span>
                  <span class="rounded border border-zinc-500/30 bg-zinc-500/10 px-1.5 py-0.5 text-[10px] text-zinc-300">
                    {summary.message_count} msgs
                  </span>
                </div>

                <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-zinc-400">
                  <span>bot: {summary.bot_id || "-"}</span>
                  <span>chat: {summary.chat_id}</span>
                  <span :if={summary.reply_to}>reply_to: {summary.reply_to}</span>
                </div>

                <div class="mt-1 text-[10px] text-zinc-600">
                  {format_timestamp(summary.inserted_at)}
                </div>
              </.link>

              <div :if={@cycle_summaries == []} class="px-3 py-8 text-center text-zinc-500">
                No agent cycles matched these filters.
              </div>
            </div>
          </section>

          <section class="space-y-3">
            <%= if @selected_cycle do %>
              <div
                id="cycle-detail"
                class="rounded border border-white/10 bg-white/[0.03] p-3"
              >
                <div class="flex flex-wrap items-center gap-2">
                  <h2 class="font-mono text-[13px] text-white truncate">
                    {@selected_cycle.cycle_id}
                  </h2>
                </div>

                <dl class="mt-3 grid grid-cols-1 gap-2 text-[12px] text-zinc-300 md:grid-cols-2">
                  <div>
                    <dt class="text-zinc-500">bot</dt>
                    <dd class="font-mono">{@selected_cycle.bot_id || "-"}</dd>
                  </div>
                  <div>
                    <dt class="text-zinc-500">chat_id</dt>
                    <dd class="font-mono">{@selected_cycle.chat_id}</dd>
                  </div>
                  <div :if={@selected_cycle.reply_to}>
                    <dt class="text-zinc-500">reply_to</dt>
                    <dd class="font-mono">{@selected_cycle.reply_to}</dd>
                  </div>
                  <div>
                    <dt class="text-zinc-500">created</dt>
                    <dd class="font-mono">{format_timestamp(@selected_cycle.inserted_at)}</dd>
                  </div>
                  <div :if={@selected_cycle.legacy_inference_session_id}>
                    <dt class="text-zinc-500">legacy session</dt>
                    <dd class="font-mono">{@selected_cycle.legacy_inference_session_id}</dd>
                  </div>
                </dl>
              </div>

              <.api_messages_panel messages={@selected_messages} />
            <% else %>
              <div class="rounded border border-white/10 bg-white/[0.03] px-3 py-12 text-center text-zinc-500">
                No agent cycles available yet.
              </div>
            <% end %>
          </section>
        </main>
      </div>
    </Layouts.app>
    """
  end

  defp load_page(socket, filters, requested_id) do
    cycle_summaries = list_cycle_summaries(filters)
    matching_count = count_matching_cycles(filters)
    selected = select_cycle(requested_id, cycle_summaries)
    selected_id = selected && selected.cycle_id

    messages =
      if selected do
        head_id = Agent.latest_head_id(%Cycle{id: selected_id})

        head_id
        |> Agent.load_messages()
        |> Enum.map(&Message.to_api/1)
        |> api_messages_for_view()
      else
        []
      end

    socket
    |> assign(:filters, filters)
    |> assign(:filter_query, filter_query_params(filters))
    |> assign(:filter_form, to_form(filter_form_values(filters), as: :filters))
    |> assign(:cycle_summaries, cycle_summaries)
    |> assign(:matching_count, matching_count)
    |> assign(:selected_cycle, selected)
    |> assign(:selected_cycle_id, selected_id)
    |> assign(:selected_messages, messages)
  end

  defp cycles_path(nil, params), do: ~p"/froth/inference?#{params}"

  defp cycles_path(id, params) when is_binary(id),
    do: ~p"/froth/inference/#{id}?#{params}"

  defp select_cycle(requested_id, summaries) when is_list(summaries) do
    found =
      if is_binary(requested_id) and requested_id != "" do
        Enum.find(summaries, &(&1.cycle_id == requested_id))
      end

    found || List.first(summaries)
  end

  defp list_cycle_summaries(filters) do
    cycles_base_query(filters)
    |> order_by([_l, c], desc: c.inserted_at)
    |> limit(^filters.limit)
    |> select([l, c], %{
      cycle_id: l.cycle_id,
      bot_id: l.bot_id,
      chat_id: l.chat_id,
      reply_to: l.reply_to,
      legacy_inference_session_id: l.legacy_inference_session_id,
      inserted_at: c.inserted_at,
      message_count:
        fragment(
          "(SELECT COUNT(*) FROM agent_events WHERE cycle_id = ?)",
          l.cycle_id
        )
    })
    |> Repo.all(log: false)
  end

  defp count_matching_cycles(filters) do
    cycles_base_query(filters)
    |> select([l, _c], count(l.cycle_id))
    |> Repo.one(log: false) || 0
  end

  defp cycles_base_query(filters) do
    from(l in CycleLink, join: c in Cycle, on: c.id == l.cycle_id)
    |> maybe_filter_bot(filters.bot_id)
    |> maybe_filter_chat(filters.chat_id)
  end

  defp maybe_filter_bot(query, nil), do: query
  defp maybe_filter_bot(query, bot_id), do: from([l, c] in query, where: l.bot_id == ^bot_id)

  defp maybe_filter_chat(query, nil), do: query
  defp maybe_filter_chat(query, chat_id), do: from([l, c] in query, where: l.chat_id == ^chat_id)

  defp filter_form_values(filters) do
    %{
      "bot_id" => filters.bot_id || "",
      "chat_id" =>
        if(is_integer(filters.chat_id), do: Integer.to_string(filters.chat_id), else: ""),
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
    |> maybe_put_query(
      "limit",
      if(filters.limit == @default_limit, do: nil, else: Integer.to_string(filters.limit))
    )
  end

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  defp default_filters do
    %{bot_id: nil, chat_id: nil, limit: @default_limit}
  end

  defp normalize_filters(params) when is_map(params) do
    params = stringify_keys(params)

    %{
      bot_id: normalize_text(params["bot_id"]),
      chat_id: parse_optional_integer(params["chat_id"]),
      limit: parse_limit(params["limit"])
    }
  end

  defp normalize_filters(_), do: default_filters()

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
      id="cycle-messages"
      class="overflow-hidden rounded border border-white/10 bg-white/[0.03]"
      open
    >
      <summary class="cursor-pointer select-none px-3 py-2 text-[12px] text-zinc-200">
        <span class="font-medium">Messages</span>
        <span class="ml-2 text-zinc-500">({length(@messages)})</span>
        <span class="ml-2 text-zinc-600">oldest first</span>
      </summary>
      <div class="border-t border-white/10 px-3 py-2">
        <div
          :if={@messages == []}
          class="rounded bg-black/35 px-3 py-8 text-center text-zinc-500"
        >
          No messages in this cycle.
        </div>

        <div :if={@messages != []} class="max-h-[46rem] space-y-1 overflow-y-auto pr-1">
          <article
            :for={message <- @messages}
            id={"cycle-msg-#{message.index}"}
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

  defp api_role_class("user"), do: "border-emerald-500/30 bg-emerald-500/10 text-emerald-300"
  defp api_role_class("assistant"), do: "border-sky-500/30 bg-sky-500/10 text-sky-300"
  defp api_role_class(_), do: "border-white/20 bg-white/5 text-zinc-300"
end
