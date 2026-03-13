defmodule FrothWeb.ChatStatsLive do
  use FrothWeb, :live_view

  @chat_id -1_003_690_254_489

  @names %{
    6_789_382_533 => "Charlie",
    8_044_965_953 => "Amy HQ",
    8_591_092_800 => "Amy Israel",
    8_396_222_696 => "Walter",
    8_507_666_754 => "Walter Jr",
    8_526_337_359 => "Matilda",
    8_534_404_418 => "Tototo",
    8_648_890_209 => "Capt Kirk",
    1_635_262_887 => "Daniel",
    362_441_422 => "Mikael"
  }

  @impl true
  def mount(_params, _session, socket) do
    days = available_days()

    {:ok,
     assign(socket, days: days, day: nil, stats: [], user_id: nil, user_msgs: [], user_name: nil)}
  end

  @impl true
  def handle_params(%{"day" => day_str, "user" => uid_str}, _uri, socket) do
    with {:ok, day} <- Date.from_iso8601(day_str),
         {uid, ""} <- Integer.parse(uid_str) do
      stats = day_stats(day)
      msgs = user_messages(day, uid)
      name = Map.get(@names, uid, "uid:#{uid}")

      {:noreply,
       assign(socket, day: day, stats: stats, user_id: uid, user_msgs: msgs, user_name: name)}
    else
      _ -> {:noreply, push_patch(socket, to: ~p"/froth/chat-stats")}
    end
  end

  def handle_params(%{"day" => day_str}, _uri, socket) do
    case Date.from_iso8601(day_str) do
      {:ok, day} ->
        stats = day_stats(day)

        {:noreply,
         assign(socket, day: day, stats: stats, user_id: nil, user_msgs: [], user_name: nil)}

      _ ->
        {:noreply, push_patch(socket, to: ~p"/froth/chat-stats")}
    end
  end

  def handle_params(_params, _uri, socket) do
    day = List.first(socket.assigns.days) || Date.utc_today()
    stats = day_stats(day)

    {:noreply,
     assign(socket, day: day, stats: stats, user_id: nil, user_msgs: [], user_name: nil)}
  end

  @impl true
  def handle_event("prev", _, socket) do
    day = Date.add(socket.assigns.day, -1)
    {:noreply, push_patch(socket, to: ~p"/froth/chat-stats/#{Date.to_iso8601(day)}")}
  end

  def handle_event("next", _, socket) do
    day = Date.add(socket.assigns.day, 1)
    {:noreply, push_patch(socket, to: ~p"/froth/chat-stats/#{Date.to_iso8601(day)}")}
  end

  defp day_bounds(day) do
    s = day |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
    e = day |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
    {s, e}
  end

  defp available_days do
    Froth.Repo.query!(
      """
        SELECT DISTINCT date_trunc('day', to_timestamp(date))::date as d
        FROM (SELECT DISTINCT ON (chat_id, message_id) * FROM telegram_messages WHERE chat_id = $1) t
        WHERE true
        ORDER BY d DESC
      """,
      [@chat_id]
    ).rows
    |> Enum.map(fn [d] -> d end)
  end

  defp day_stats(day) do
    {s, e} = day_bounds(day)

    Froth.Repo.query!(
      """
        SELECT sender_id,
               count(*) as msg_count,
               sum(length(
                 coalesce(raw->'content'->'text'->>'text', '')
               )) as text_chars,
               min(date) as first_ts,
               max(date) as last_ts
        FROM (SELECT DISTINCT ON (message_id) * FROM telegram_messages
              WHERE chat_id = $1 AND date >= $2 AND date < $3
              ORDER BY message_id, inserted_at DESC) t
        GROUP BY sender_id
        ORDER BY text_chars DESC
      """,
      [@chat_id, s, e]
    ).rows
    |> Enum.map(fn [sid, count, chars, first_ts, last_ts] ->
      %{
        sender_id: sid,
        name: Map.get(@names, sid, "uid:#{sid}"),
        msg_count: count,
        text_chars: chars || 0,
        first_ts: first_ts,
        last_ts: last_ts
      }
    end)
  end

  defp user_messages(day, uid) do
    {s, e} = day_bounds(day)

    Froth.Repo.query!(
      """
        SELECT message_id, date,
               coalesce(raw->'content'->'text'->>'text', '') as text,
               raw->'content'->>'@type' as msg_type
        FROM (SELECT DISTINCT ON (message_id) * FROM telegram_messages
              WHERE chat_id = $1 AND sender_id = $2 AND date >= $3 AND date < $4
              ORDER BY message_id, inserted_at DESC) t
        ORDER BY date ASC
      """,
      [@chat_id, uid, s, e]
    ).rows
    |> Enum.map(fn [mid, ts, text, mtype] ->
      %{
        message_id: mid,
        time: DateTime.from_unix!(ts) |> Calendar.strftime("%H:%M:%S"),
        text: text,
        msg_type: mtype,
        chars: String.length(text || "")
      }
    end)
  end

  defp bar_width(chars, stats) do
    max_chars = stats |> Enum.map(& &1.text_chars) |> Enum.max(fn -> 1 end)
    if max_chars > 0, do: round(chars / max_chars * 100), else: 0
  end

  defp total_chars(stats), do: stats |> Enum.map(& &1.text_chars) |> Enum.sum()
  defp total_msgs(stats), do: stats |> Enum.map(& &1.msg_count) |> Enum.sum()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div class="mx-auto max-w-5xl px-6 py-8 font-mono text-base-content">
        <div class="mb-6">
          <h1 class="text-2xl font-bold">Chat Stats</h1>
          <p class="text-sm opacity-60 mt-1">
            Per-user contribution by day. Click a name to see their messages.
          </p>
        </div>

        <%!-- Day navigation --%>
        <div class="flex items-center gap-4 mb-6">
          <button phx-click="prev" class="btn btn-sm btn-ghost">&larr;</button>
          <span class="text-lg font-semibold">{Date.to_iso8601(@day)}</span>
          <button phx-click="next" class="btn btn-sm btn-ghost">&rarr;</button>
        </div>

        <%!-- Day picker --%>
        <div class="flex flex-wrap gap-1 mb-6 text-xs">
          <.link
            :for={d <- @days}
            patch={~p"/froth/chat-stats/#{Date.to_iso8601(d)}"}
            class={"px-2 py-1 rounded #{if d == @day, do: "btn-primary text-primary-content", else: "bg-base-200 hover:bg-base-300 text-base-content"}"}
          >
            {Calendar.strftime(d, "%m/%d")}
          </.link>
        </div>

        <%!-- Stats table --%>
        <div class="mb-8">
          <div class="text-xs opacity-50 mb-2">
            {total_msgs(@stats)} messages, {div(total_chars(@stats), 1000)}K text chars
          </div>
          <div class="space-y-1">
            <div :for={s <- @stats} class="flex items-center gap-2">
              <.link
                patch={~p"/froth/chat-stats/#{Date.to_iso8601(@day)}?user=#{s.sender_id}"}
                class={"w-28 text-sm truncate hover:underline #{if s.sender_id == @user_id, do: "font-bold text-primary", else: "opacity-70 hover:opacity-100"}"}
              >
                {s.name}
              </.link>
              <span class="w-12 text-right text-xs opacity-50">{s.msg_count}</span>
              <span class="w-14 text-right text-xs opacity-50">{div(s.text_chars, 1000)}K</span>
              <div class="flex-1 bg-base-200 rounded h-4 overflow-hidden">
                <div
                  class="h-full bg-primary rounded"
                  style={"width: #{bar_width(s.text_chars, @stats)}%"}
                />
              </div>
              <span class="w-12 text-right text-xs opacity-50">
                {if total_chars(@stats) > 0,
                  do: Float.round(s.text_chars / total_chars(@stats) * 100, 1),
                  else: 0}%
              </span>
            </div>
          </div>
        </div>

        <%!-- User messages --%>
        <div :if={@user_id} class="border-t border-base-300 pt-6">
          <h2 class="text-lg font-semibold mb-1">{@user_name}</h2>
          <p class="text-xs opacity-50 mb-4">
            {length(@user_msgs)} messages on {Date.to_iso8601(@day)}
          </p>
          <div class="space-y-2">
            <div :for={m <- @user_msgs} class="border border-base-300 rounded p-3 bg-base-200">
              <div class="flex items-center gap-2 mb-1 text-xs opacity-40">
                <span>{m.time}</span>
                <span class="opacity-30">|</span>
                <span>{m.msg_type}</span>
                <span class="opacity-30">|</span>
                <span>{m.chars} chars</span>
              </div>
              <pre class="text-sm whitespace-pre-wrap break-words leading-relaxed">{m.text}</pre>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
