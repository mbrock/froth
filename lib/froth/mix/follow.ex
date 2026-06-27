defmodule Froth.Mix.Follow do
  @moduledoc false

  alias Froth.Follow.{Entry, Filter, Source}
  alias Froth.Mix.LiveNode

  @default_tail 80

  @spec main([String.t()]) :: no_return()
  def main(args) do
    ensure_repo_started!()

    {opts, remaining, invalid} = parse_args(args)

    if opts[:help] do
      IO.write(usage())
      System.halt(0)
    end

    validate_args!(remaining, invalid)

    node = LiveNode.connect!("follow")
    Node.monitor(node, true)

    mode = parse_mode(opts)
    tail = max(opts[:tail] || @default_tail, 0)

    filter =
      Filter.new(
        event_prefix: parse_event_prefix(remaining),
        cycle_id: opts[:cycle],
        span_id: opts[:span]
      )

    subscribe_remote_events!(node)

    IO.puts("Connected to #{node}")
    IO.puts(follow_banner(filter, mode))

    Process.flag(:trap_exit, true)

    state0 = %{mode: mode, filter: filter, tree: %{}}
    state1 = render_recent_history(state0, tail)
    loop(node, state1)
  end

  defp parse_args(args) do
    OptionParser.parse(args,
      strict: [
        help: :boolean,
        errors: :boolean,
        debug: :boolean,
        cycle: :string,
        span: :string,
        tail: :integer
      ]
    )
  end

  defp usage do
    """
    Usage: bin/follow [EVENT_PREFIX] [options]

    Subscribe to the `events` pub/sub topic on the running node and
    print each event as a single line. A prefix argument narrows the
    stream (e.g. `bin/follow froth.agent` only shows agent events).

        bin/follow
        bin/follow --tail 120
        bin/follow froth.agent
        bin/follow --cycle 01ABC...
        bin/follow --errors

    Options:
      --tail N     Number of recent matching entries to print before following
      --errors     Render only warn/error entries
      --debug      Include debug-level events (llm.edit, sse deltas, span starts)
      --cycle ID   Restrict to a cycle id prefix
      --span ID    Restrict to a span id prefix
      --help       Show this help
    """
  end

  defp validate_args!([], []), do: :ok

  defp validate_args!(remaining, invalid) do
    invalid_args =
      invalid
      |> Enum.map(fn
        {name, nil} -> "--#{name}"
        {name, value} -> "--#{name}=#{value}"
      end)

    too_many_args? = length(remaining) > 1

    cond do
      invalid_args != [] ->
        abort(
          "Unknown options: #{Enum.join(invalid_args, ", ")}\n\n#{usage()}"
        )

      too_many_args? ->
        abort("Expected at most one EVENT_PREFIX argument.\n\n#{usage()}")

      true ->
        :ok
    end
  end

  # Subscribe to the remote node's "events" topic by spawning a
  # process there that forwards each broadcast back to us. Phoenix
  # pubsub is node-local, so we can't just subscribe from here.
  defp subscribe_remote_events!(node) do
    me = self()

    case :rpc.call(node, __MODULE__, :start_remote_subscriber, [me]) do
      {:ok, _pid} ->
        :ok

      {:badrpc, reason} ->
        abort("Could not subscribe to events on #{node}: #{inspect(reason)}")

      other ->
        abort("Could not subscribe to events on #{node}: #{inspect(other)}")
    end
  end

  @doc false
  def start_remote_subscriber(target_pid) when is_pid(target_pid) do
    pid =
      spawn(fn ->
        :ok = Phoenix.PubSub.subscribe(Froth.PubSub, "events")
        ref = Process.monitor(target_pid)
        forward_loop(target_pid, ref)
      end)

    {:ok, pid}
  end

  defp forward_loop(target_pid, ref) do
    receive do
      {:event, _event} = msg ->
        send(target_pid, msg)
        forward_loop(target_pid, ref)

      {:DOWN, ^ref, :process, ^target_pid, _reason} ->
        :ok

      _other ->
        forward_loop(target_pid, ref)
    end
  end

  defp follow_banner(filter, mode) do
    filter_summary = Filter.summary(filter)

    prefix =
      if filter_summary == [],
        do: "",
        else: " (#{Enum.join(filter_summary, ", ")})"

    "Following events#{prefix} #{mode_label(mode)}\n"
  end

  defp parse_mode(opts) do
    cond do
      opts[:errors] -> :errors
      opts[:debug] -> :raw
      true -> :smart
    end
  end

  defp mode_label(:errors), do: "(errors only)"
  defp mode_label(:raw), do: "(with debug)"
  defp mode_label(_), do: "(info+)"

  defp parse_event_prefix([]), do: nil
  defp parse_event_prefix([filter]), do: filter

  defp loop(node, %{mode: mode, filter: filter} = state) do
    receive do
      {:event, event} ->
        entry = Entry.from_event(event)

        # Always update the span tree so hierarchy stays accurate —
        # even for events we're about to hide. Only emit output when
        # the entry passes the filter and the visibility mode.
        {depth, tree} = depth_for(entry, state.tree)
        state = %{state | tree: tree}

        state =
          cond do
            !Filter.matches?(entry, filter) ->
              state

            !Entry.visible?(entry, mode) ->
              state

            dedupe_hidden?(entry) ->
              state

            true ->
              IO.puts(render_entry(entry, depth))
              state
          end

        loop(node, state)

      {:nodedown, ^node} ->
        abort("Disconnected from #{node}")
    end
  end

  defp render_recent_history(state, 0), do: state

  defp render_recent_history(%{mode: mode, filter: filter} = state, tail) do
    # Pull a generous history tail so hidden-but-tree-shaping events
    # (the Span .start events and .cnode debug noise) still populate
    # the tree, then walk in chronological order.
    entries =
      Source.recent_entries(filter: filter, limit: tail * 6)
      |> Enum.reverse()

    visible_count =
      entries |> Enum.count(&Entry.visible?(&1, mode)) |> min(tail)

    if visible_count == 0 do
      state
    else
      IO.puts("Recent matching entries (last #{visible_count} shown):\n")

      # Window the entries so we keep the last `tail` visible ones,
      # along with anything before them needed to seed the tree.
      entries = last_n_with_context(entries, mode, tail)

      tree =
        Enum.reduce(entries, state.tree, fn entry, tree ->
          {depth, tree} = depth_for(entry, tree)

          if Entry.visible?(entry, mode) and not dedupe_hidden?(entry) do
            IO.puts(render_entry(entry, depth))
          end

          tree
        end)

      IO.write("\n")
      %{state | tree: tree}
    end
  end

  defp last_n_with_context(entries, mode, n) do
    visible_indexes =
      entries
      |> Enum.with_index()
      |> Enum.filter(fn {e, _i} -> Entry.visible?(e, mode) end)
      |> Enum.map(fn {_e, i} -> i end)

    case visible_indexes do
      [] ->
        entries

      idxs ->
        first_visible = Enum.at(idxs, max(length(idxs) - n, 0))
        Enum.drop(entries, first_visible)
    end
  end

  # The stream is rendered as a nested tree: each event is placed at
  # the depth of its span within the open-span ancestry. Opening
  # events ("*.start" / "*.started") push; closing events ("*.stop"
  # / "*.completed" / "*.failed" / "*.timed_out" / "*.cancelled" /
  # "*.exception") pop. Glyphs signal open vs close vs point. The
  # output is two lines per event:
  #
  #     GLYPH  family.kind  verb
  #       HH:MM:SS  (duration)  key=value  key=value  …
  #
  # indented by depth*2 spaces. The indent makes the span tree
  # legible; removing it is what made the previous flat layout
  # feel like a dump.
  defp render_entry(%Entry{} = entry, depth) do
    ansi = IO.ANSI.enabled?()
    indent = String.duplicate("  ", depth)
    header = indent <> render_header(entry, ansi)

    case render_meta_line(entry, ansi) do
      nil -> header
      meta -> header <> "\n" <> indent <> meta
    end
  end

  # Events that only duplicate a sibling. The Span-level
  # froth.agent.cycle.stop fires alongside the agent-level
  # cycle.completed/failed/cancelled events but carries only the
  # raw duration — we hide it so the cycle shows up once with
  # its rich metadata. The tree still updates from the hidden
  # event so the span closes correctly.
  defp dedupe_hidden?(%Entry{event: "froth.agent.cycle.stop"}), do: true
  defp dedupe_hidden?(_), do: false

  defp render_header(%Entry{} = entry, ansi) do
    glyph = glyph_for(entry, ansi)
    level = level_tag(entry.level, ansi)
    name = event_name(entry, ansi)
    verb = verb_tag(entry, ansi)

    [glyph <> level <> name, verb]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("  ")
  end

  defp render_meta_line(%Entry{} = entry, ansi) do
    pairs = meta_pairs(entry.metadata)
    time = dim(format_time(entry.at), ansi)
    duration = duration_tag(entry.duration_ms, ansi)

    body =
      pairs
      |> Enum.map_join("  ", fn {k, v} -> dim(k, ansi) <> "=" <> v end)

    parts =
      ["  " <> time, duration, body]
      |> Enum.reject(&(&1 in ["", "  "]))

    case parts do
      ["  " <> _ = first] when pairs == [] and duration == "" -> first
      parts -> Enum.join(parts, "  ")
    end
    |> case do
      "" -> nil
      line -> truncate(line, 200)
    end
  end

  # Span tree tracking. Each entry may open a new span, close an
  # existing one, or fire as a point event inside one. We identify
  # the span by `span_id`, fall back to `parent_id` for nesting of
  # fresh spans, and for spanless events (like message.appended) we
  # ask "what's the deepest currently-open span in this cycle?" and
  # tuck them in one level below it.
  defp depth_for(%Entry{} = entry, tree) do
    close? = close_event?(entry)
    open? = open_event?(entry)
    sid = entry.span_id

    cond do
      is_binary(sid) and Map.has_key?(tree, sid) ->
        # already-known span — close or point-in-span
        depth = tree[sid].depth
        tree = if close?, do: Map.delete(tree, sid), else: tree
        {depth, tree}

      is_binary(sid) and open? ->
        parent_depth =
          case entry.parent_id do
            p when is_binary(p) ->
              case Map.get(tree, p) do
                %{depth: d} -> d
                _ -> -1
              end

            _ ->
              -1
          end

        depth = parent_depth + 1
        {depth, Map.put(tree, sid, %{depth: depth, cycle_id: entry.cycle_id})}

      is_binary(sid) ->
        # new point event with a span_id we haven't seen — treat as
        # floating under its parent if any, else at top.
        parent_depth =
          case entry.parent_id do
            p when is_binary(p) ->
              case Map.get(tree, p) do
                %{depth: d} -> d
                _ -> -1
              end

            _ ->
              -1
          end

        {parent_depth + 1, tree}

      is_binary(entry.cycle_id) ->
        # spanless event (e.g. message.appended) — tuck it one level
        # below the deepest open span in this cycle.
        depth =
          tree
          |> Map.values()
          |> Enum.filter(&(&1.cycle_id == entry.cycle_id))
          |> Enum.map(& &1.depth)
          |> Enum.max(fn -> -1 end)

        {depth + 1, tree}

      true ->
        {0, tree}
    end
  end

  @open_suffixes ~w(.start .started)
  @close_suffixes ~w(
    .stop .completed .failed .timed_out .cancelled .exception
  )

  defp open_event?(%Entry{event: name}),
    do: Enum.any?(@open_suffixes, &String.ends_with?(name, &1))

  defp close_event?(%Entry{event: name}),
    do: Enum.any?(@close_suffixes, &String.ends_with?(name, &1))

  defp glyph_for(%Entry{} = entry, ansi) do
    cond do
      entry.level == :error ->
        color(ansi, [:red, :bright], "✗ ")

      close_event?(entry) ->
        color(ansi, [:green], "● ")

      open_event?(entry) ->
        color(ansi, [:yellow], "∘ ")

      true ->
        dim("· ", ansi)
    end
  end

  defp verb_tag(%Entry{event: name}, ansi) do
    cond do
      String.ends_with?(name, ".start") ->
        color(ansi, [:faint], "started")

      String.ends_with?(name, ".started") ->
        color(ansi, [:faint], "started")

      String.ends_with?(name, ".stop") ->
        color(ansi, [:faint], "completed")

      String.ends_with?(name, ".completed") ->
        color(ansi, [:faint], "completed")

      String.ends_with?(name, ".failed") ->
        color(ansi, [:red], "failed")

      String.ends_with?(name, ".timed_out") ->
        color(ansi, [:red], "timed out")

      String.ends_with?(name, ".cancelled") ->
        color(ansi, [:faint], "cancelled")

      String.ends_with?(name, ".exception") ->
        color(ansi, [:red], "exception")

      true ->
        ""
    end
  end

  defp event_name(%Entry{event: event, family: family, kind: kind}, ansi) do
    if String.starts_with?(event, "froth.") do
      # Strip the verb suffix from kind; the verb renders separately.
      base =
        kind
        |> String.replace_suffix(".start", "")
        |> String.replace_suffix(".started", "")
        |> String.replace_suffix(".stop", "")
        |> String.replace_suffix(".completed", "")
        |> String.replace_suffix(".failed", "")
        |> String.replace_suffix(".timed_out", "")
        |> String.replace_suffix(".cancelled", "")
        |> String.replace_suffix(".exception", "")

      family_colored = colorize_family(family, ansi)

      case base do
        "" -> family_colored
        bare -> family_colored <> dim(".", ansi) <> bare
      end
    else
      event
    end
  end

  defp duration_tag(nil, _ansi), do: ""
  defp duration_tag(ms, ansi), do: dim("(#{ms}ms)", ansi)

  defp format_time(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%H:%M:%S.%f") |> String.slice(0, 12)

  defp format_time(%NaiveDateTime{} = dt),
    do: Calendar.strftime(dt, "%H:%M:%S.%f") |> String.slice(0, 12)

  defp format_time(_), do: "--:--:--.---"

  defp level_tag(:error, ansi),
    do: color(ansi, [:red, :bright], "ERR ")

  defp level_tag(:warn, ansi),
    do: color(ansi, [:yellow, :bright], "WRN ")

  defp level_tag(:debug, ansi),
    do: dim("dbg ", ansi)

  defp level_tag(_, _ansi), do: ""

  defp meta_pairs(metadata) when map_size(metadata) == 0, do: []

  defp meta_pairs(metadata) do
    metadata
    |> Map.drop([
      "system_time",
      "blob_ref",
      "cycle_id",
      "span_id",
      "parent_id",
      "seq",
      "kind",
      "head_id"
    ])
    |> Enum.reject(fn {_k, v} -> is_map(v) or is_list(v) end)
    |> Enum.sort_by(&pair_weight/1)
    |> Enum.take(8)
    |> Enum.map(fn {k, v} -> {k, short(v)} end)
  end

  # Pull a few particularly useful keys to the front (provider, model,
  # tool_name, text_preview, reason, error, outcome), then alphabetical.
  defp pair_weight({key, _}) do
    priority = %{
      "provider" => 0,
      "model" => 1,
      "tool_name" => 2,
      "outcome" => 3,
      "reason" => 4,
      "error" => 5,
      "text_preview" => 6,
      "role" => 7
    }

    {Map.get(priority, key, 100), key}
  end

  defp short(v) when is_binary(v) do
    if String.length(v) > 60, do: String.slice(v, 0, 60) <> "…", else: v
  end

  defp short(v) when is_integer(v) or is_float(v) or is_boolean(v),
    do: to_string(v)

  defp short(nil), do: "nil"
  defp short(v), do: inspect(v, limit: 4, printable_limit: 60)

  defp truncate(text, max) when byte_size(text) > max,
    do: binary_part(text, 0, max) <> "…"

  defp truncate(text, _max), do: text

  # Family palette: light touch, easy on dark and light terminals.
  defp colorize_family(family, ansi) do
    codes =
      case family do
        "agent" -> [:cyan]
        "http" -> [:faint]
        "anthropic" -> [:magenta]
        "openai" -> [:magenta]
        "gemini" -> [:magenta]
        "google" -> [:magenta]
        "grok" -> [:magenta]
        "xai" -> [:magenta]
        "llm" -> [:magenta]
        "codex" -> [:green]
        "telegram" -> [:blue]
        "tools" -> [:yellow]
        "tasks" -> [:yellow]
        "browser" -> [:yellow]
        "web" -> [:yellow]
        "headlines" -> [:green]
        "replicate" -> [:green]
        "podcast" -> [:green]
        _ -> [:default_color]
      end

    color(ansi, codes, family)
  end

  defp color(true, codes, text) do
    IO.iodata_to_binary([
      Enum.map(codes, &IO.ANSI.format_fragment(&1, true)),
      text,
      IO.ANSI.reset()
    ])
  end

  defp color(false, _codes, text), do: text

  defp dim(text, ansi), do: color(ansi, [:faint], text)

  defp ensure_repo_started! do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.config")

    if Process.whereis(Froth.Repo) do
      :ok
    else
      Application.ensure_all_started(:postgrex)
      Application.ensure_all_started(:ecto_sql)

      case Froth.Repo.start_link() do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          abort("Could not start Froth.Repo: #{inspect(reason)}")
      end
    end
  end

  defp abort(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end
