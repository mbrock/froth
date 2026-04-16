defmodule Froth.RouteAudit do
  @moduledoc """
  Screenshots Froth routes and writes a summary alongside the image artifacts.

  Intended usage from the running app node:

      Froth.RouteAudit.run()
      Froth.RouteAudit.run(base_url: "https://less.rest")
  """

  import Ecto.Query

  alias Froth.Agent.Cycle
  alias Froth.Browser
  alias Froth.Codex.Events, as: CodexEvents
  alias Froth.Codex.Session, as: CodexSession
  alias Froth.Podcast.Script, as: PodcastScript
  alias Froth.Repo
  alias Froth.SceneEvents
  alias Froth.Telegram.CycleLink
  alias Froth.Wiki

  @chat_stats_chat_id -1_003_690_254_489
  @default_base_url "https://less.rest"
  @default_output_dir Path.expand("priv/route_audit")
  @default_navigation_timeout_ms 45_000
  @default_settle_ms 4_000
  @default_wait_timeout_ms 8_000
  @default_command_timeout_ms 10_000
  @default_screenshot_timeout_ms 20_000
  @default_viewport [width: 1440, height: 1400]

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    opts = normalize_opts(opts)
    context = sample_context()
    prepared_routes = prepare_routes(context, opts)

    with :ok <- prepare_output_dir(opts[:output_dir]),
         {:ok, browser_id} <- Browser.checkout(label: "route audit"),
         :ok <- Browser.set_viewport(browser_id, opts[:viewport]) do
      try do
        results =
          prepared_routes
          |> Enum.map(&audit_route(browser_id, &1, opts))

        summary =
          %{
            generated_at: DateTime.utc_now(),
            base_url: opts[:base_url],
            output_dir: opts[:output_dir],
            route_count: length(prepared_routes),
            captured_count: Enum.count(results, &(&1.status == :captured)),
            skipped_count: Enum.count(results, &(&1.status == :skipped)),
            error_count: Enum.count(results, &(&1.status == :error)),
            routes: results
          }

        write_summary_files(summary, opts[:output_dir])
      after
        _ = Browser.release(browser_id)
      end
    end
  end

  defp normalize_opts(opts) do
    base_url =
      opts
      |> Keyword.get(:base_url, @default_base_url)
      |> to_string()
      |> String.trim_trailing("/")

    output_dir =
      opts
      |> Keyword.get(:output_dir, @default_output_dir)
      |> Path.expand()

    [
      base_url: base_url,
      output_dir: output_dir,
      screenshot_dir: Path.join(output_dir, "screenshots"),
      navigation_timeout_ms:
        Keyword.get(opts, :navigation_timeout_ms, @default_navigation_timeout_ms),
      settle_ms: Keyword.get(opts, :settle_ms, @default_settle_ms),
      wait_timeout_ms: Keyword.get(opts, :wait_timeout_ms, @default_wait_timeout_ms),
      command_timeout_ms: Keyword.get(opts, :command_timeout_ms, @default_command_timeout_ms),
      screenshot_timeout_ms:
        Keyword.get(opts, :screenshot_timeout_ms, @default_screenshot_timeout_ms),
      viewport: Keyword.get(opts, :viewport, @default_viewport),
      full_page: Keyword.get(opts, :full_page, false)
    ]
  end

  defp prepare_output_dir(output_dir) do
    with :ok <- File.mkdir_p(output_dir),
         :ok <- File.mkdir_p(Path.join(output_dir, "screenshots")) do
      clear_old_screenshots(Path.join(output_dir, "screenshots"))
      :ok
    end
  end

  defp clear_old_screenshots(screenshot_dir) do
    screenshot_dir
    |> Path.join("*.png")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)

    :ok
  end

  defp prepare_routes(context, opts) do
    FrothWeb.Router.__routes__()
    |> Enum.filter(&audit_candidate?/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {route, index} ->
      base = %{
        index: index,
        method: route.verb,
        template: route.path,
        handler: handler_label(route),
        handler_kind: handler_kind(route),
        live_view?: live_view_route?(route)
      }

      case resolve_route_path(route, context) do
        {:ok, path, resolution} ->
          filename = screenshot_filename(index, path)

          Map.merge(base, %{
            status: :pending,
            resolution: resolution,
            path: path,
            url: opts[:base_url] <> path,
            screenshot_path: Path.join(opts[:screenshot_dir], filename),
            screenshot_rel_path: Path.join("screenshots", filename)
          })

        {:skip, reason} ->
          Map.merge(base, %{
            status: :skipped,
            skip_reason: reason,
            path: nil,
            url: nil,
            screenshot_path: nil,
            screenshot_rel_path: nil
          })
      end
    end)
  end

  defp audit_candidate?(%{verb: :get, plug: Phoenix.LiveDashboard.Assets}), do: false
  defp audit_candidate?(%{verb: :get}), do: true
  defp audit_candidate?(_route), do: false

  defp sample_context do
    latest_session = CodexEvents.list_sessions(1) |> List.first()

    %{
      analysis_day: latest_analysis_day(),
      chat_stats_day: latest_chat_stats_day(),
      cycle_id: latest_cycle_id(),
      cycle_link: latest_cycle_link(),
      codex_session_id: latest_session && latest_session.session_id,
      codex_thread_id: latest_session && latest_codex_thread_id(latest_session.session_id),
      media_message: latest_media_message(),
      object_store_key: first_object_store_key(),
      podcast_batch_id: latest_podcast_batch_id(),
      podcast_id: latest_podcast_id(),
      rfc_slug: first_rfc_slug(),
      reel_id: first_reel_id(),
      scene_id: latest_scene_id(),
      wiki_slug: first_wiki_slug()
    }
  end

  defp latest_analysis_day do
    Repo.one(
      from(a in Froth.Analysis,
        order_by: [desc: a.generated_at],
        select: fragment("?::date::text", a.generated_at),
        limit: 1
      ),
      log: false
    ) || Date.to_iso8601(Date.utc_today())
  end

  defp latest_chat_stats_day do
    Repo.query!(
      """
      SELECT date(to_timestamp(max(date)))::text
      FROM telegram_messages
      WHERE chat_id = $1
      """,
      [@chat_stats_chat_id],
      log: false
    ).rows
    |> case do
      [[day]] when is_binary(day) -> day
      _ -> latest_analysis_day()
    end
  rescue
    _ -> latest_analysis_day()
  end

  defp latest_cycle_id do
    Repo.one(from(c in Cycle, order_by: [desc: c.inserted_at], select: c.id, limit: 1),
      log: false
    )
  end

  defp latest_cycle_link do
    Repo.one(
      from(l in CycleLink,
        order_by: [desc: l.inserted_at],
        select: %{bot_id: l.bot_id, cycle_id: l.cycle_id},
        limit: 1
      ),
      log: false
    )
  end

  defp latest_codex_thread_id(session_id) when is_binary(session_id) do
    case CodexSession.current_thread_id(session_id) do
      {:ok, thread_id} when is_binary(thread_id) -> thread_id
      _ -> nil
    end
  end

  defp latest_codex_thread_id(_session_id), do: nil

  defp latest_media_message do
    Repo.query!(
      """
      SELECT chat_id, message_id
      FROM telegram_messages
      WHERE raw->'content'->>'@type' IN ('messagePhoto', 'messageDocument')
      ORDER BY inserted_at DESC
      LIMIT 1
      """,
      [],
      log: false
    ).rows
    |> case do
      [[chat_id, message_id]] -> %{chat_id: chat_id, message_id: message_id}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp first_object_store_key do
    root_dir = Froth.ObjectStore.root_dir()

    if File.dir?(root_dir) do
      root_dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.find_value(fn path ->
        if File.regular?(path) do
          Path.relative_to(path, root_dir)
        end
      end)
    end
  end

  defp latest_podcast_batch_id do
    Repo.one(
      from(s in PodcastScript,
        where: not is_nil(s.batch_id),
        order_by: [desc: s.inserted_at],
        select: s.batch_id,
        limit: 1
      ),
      log: false
    )
  end

  defp latest_podcast_id do
    Repo.one(
      from(s in PodcastScript, order_by: [desc: s.inserted_at], select: s.id, limit: 1),
      log: false
    )
  end

  defp first_rfc_slug do
    Path.expand("rfc")
    |> Path.join("froth-rfc*.xml")
    |> Path.wildcard()
    |> Enum.sort()
    |> List.first()
    |> case do
      nil ->
        nil

      path ->
        path
        |> Path.basename()
        |> String.replace_prefix("froth-rfc", "")
        |> String.replace_suffix(".xml", "")
    end
  end

  defp first_reel_id do
    Path.join(Application.app_dir(:froth, "priv"), "reels")
    |> File.ls()
    |> case do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".html"))
        |> Enum.map(&String.replace_suffix(&1, ".html", ""))
        |> Enum.sort()
        |> List.first()

      _ ->
        nil
    end
  end

  defp latest_scene_id do
    Repo.one(
      from(e in SceneEvents,
        where: not is_nil(e.scene_id),
        order_by: [desc: e.inserted_at],
        select: e.scene_id,
        limit: 1
      ),
      log: false
    ) || "default"
  end

  defp first_wiki_slug do
    Wiki.entries()
    |> Enum.map(& &1.slug)
    |> Enum.find(&is_binary/1)
  end

  defp resolve_route_path(%{path: path}, context) do
    case path do
      "/froth/analyses/day/:day" ->
        {:ok, "/froth/analyses/day/#{context.analysis_day}", "latest analysis day"}

      "/froth/inference/:id" ->
        resolve_param_path("/froth/inference/:id", context.cycle_id, "latest cycle id")

      "/froth/wiki/:slug" ->
        resolve_param_path("/froth/wiki/:slug", context.wiki_slug, "first wiki slug")

      "/froth/media/:chat_id/:message_id" ->
        case context.media_message do
          %{chat_id: chat_id, message_id: message_id} ->
            {:ok, "/froth/media/#{chat_id}/#{message_id}", "latest photo/document message"}

          _ ->
            {:skip, "no photo/document telegram message found"}
        end

      "/froth/chat-stats/:day" ->
        {:ok, "/froth/chat-stats/#{context.chat_stats_day}", "latest chat-stats day"}

      "/froth/scene/:id" ->
        resolve_param_path("/froth/scene/:id", context.scene_id, "latest scene id")

      "/froth/mini/tool/:ref" ->
        case context.cycle_link do
          %{bot_id: bot_id, cycle_id: cycle_id}
          when is_binary(bot_id) and is_binary(cycle_id) ->
            {:ok, "/froth/mini/tool/cycle_#{bot_id}_#{cycle_id}", "latest telegram cycle link"}

          _ ->
            {:skip, "no telegram cycle link found"}
        end

      "/froth/mini/codex/thread/:thread_id" ->
        resolve_param_path(
          "/froth/mini/codex/thread/:thread_id",
          context.codex_thread_id,
          "latest active Codex thread"
        )

      "/froth/mini/codex/:session_id" ->
        resolve_param_path(
          "/froth/mini/codex/:session_id",
          context.codex_session_id,
          "latest persisted Codex session"
        )

      "/rfc/:slug" ->
        resolve_param_path("/rfc/:slug", context.rfc_slug, "first RFC slug")

      "/embed/:batch_id" ->
        resolve_param_path(
          "/embed/:batch_id",
          context.podcast_batch_id,
          "latest podcast batch id"
        )

      "/embed/:batch_id/audio" ->
        resolve_param_path(
          "/embed/:batch_id/audio",
          context.podcast_batch_id,
          "latest podcast batch id"
        )

      "/reel/:id" ->
        resolve_param_path("/reel/:id", context.reel_id, "first reel id")

      "/froth/voice/episodes/:id" ->
        resolve_param_path("/froth/voice/episodes/:id", context.podcast_id, "latest episode id")

      "/api/podcasts/:id" ->
        resolve_param_path("/api/podcasts/:id", context.podcast_id, "latest podcast id")

      "/froth/objects/*key" ->
        resolve_param_path(
          "/froth/objects/*key",
          context.object_store_key,
          "first object-store key"
        )

      "/dev/dashboard/:page" ->
        {:ok, "/dev/dashboard/metrics", "default LiveDashboard page"}

      "/dev/dashboard/:node/:page" ->
        {:ok, "/dev/dashboard/#{Node.self()}/processes", "current node LiveDashboard page"}

      static_path when is_binary(static_path) ->
        if String.contains?(static_path, [":", "*"]) do
          {:skip, "no sample value configured for dynamic route"}
        else
          {:ok, static_path, "static route"}
        end

      _ ->
        {:skip, "unsupported route path"}
    end
  end

  defp resolve_param_path(template, value, resolution) when is_binary(value) and value != "" do
    {:ok, substitute_param(template, value), resolution}
  end

  defp resolve_param_path(template, value, resolution) when is_integer(value) do
    {:ok, substitute_param(template, Integer.to_string(value)), resolution}
  end

  defp resolve_param_path(_template, _value, resolution) do
    {:skip, "missing sample value (#{resolution})"}
  end

  defp substitute_param(template, value) do
    template
    |> String.replace(~r/(:[^\/]+|\*[^\/]+)/, value, global: false)
  end

  defp audit_route(_browser_id, %{status: :skipped} = route, _opts) do
    Map.drop(route, [:status])
    |> Map.merge(%{
      status: :skipped,
      title: nil,
      content_type: nil,
      page_heading: nil,
      description: nil,
      text_preview: nil
    })
  end

  defp audit_route(browser_id, route, opts) do
    IO.puts("route audit #{route.index}: #{route.url}")

    case navigate_and_capture(browser_id, route, opts) do
      {:ok, metadata} ->
        Map.merge(route, %{
          status: :captured,
          title: metadata["title"],
          content_type: metadata["contentType"],
          page_heading: metadata["heading"],
          text_preview: metadata["preview"],
          live_view_detected?: metadata["liveView"],
          description: describe_route(route, metadata)
        })

      {:error, reason} ->
        Map.merge(route, %{
          status: :error,
          title: nil,
          content_type: nil,
          page_heading: nil,
          text_preview: nil,
          error: inspect(reason),
          description: "Failed to capture route audit screenshot."
        })
    end
  end

  defp navigate_and_capture(browser_id, route, opts) do
    with :ok <- navigate_route(browser_id, route.url, opts),
         :ok <- settle_route(browser_id, route, opts),
         {:ok, metadata} <- page_metadata(browser_id, opts),
         {:ok, _path} <-
           Browser.screenshot(browser_id,
             path: route.screenshot_path,
             full_page: opts[:full_page],
             timeout_ms: opts[:screenshot_timeout_ms]
           ) do
      {:ok, metadata}
    end
  end

  defp navigate_route(browser_id, url, opts) do
    case Browser.navigate(browser_id, url, timeout_ms: opts[:navigation_timeout_ms]) do
      :ok ->
        :ok

      {:error, :timeout} ->
        salvage_navigation_timeout(browser_id, url, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp salvage_navigation_timeout(browser_id, url, opts) do
    case Browser.eval(browser_id, navigation_probe_script(),
           timeout_ms: opts[:command_timeout_ms]
         ) do
      {:ok, %{"href" => href} = snapshot} ->
        if salvageable_navigation?(href, url, snapshot) do
          _ =
            Browser.eval(browser_id, "window.stop(); true", timeout_ms: opts[:command_timeout_ms])

          :ok
        else
          {:error, :timeout}
        end

      _ ->
        {:error, :timeout}
    end
  end

  defp salvageable_navigation?(href, url, snapshot)
       when is_binary(href) and is_binary(url) and is_map(snapshot) do
    body_text_length = snapshot["bodyTextLength"] || 0
    body_child_count = snapshot["bodyChildCount"] || 0
    content_type = snapshot["contentType"] || ""
    ready_state = snapshot["readyState"] || ""

    String.starts_with?(href, url) and
      (body_text_length > 0 or body_child_count > 0 or content_type != "" or
         ready_state in ["interactive", "complete"])
  end

  defp settle_route(browser_id, route, opts) do
    Process.sleep(opts[:settle_ms])

    if route.live_view? do
      _ = wait_for_live_view(browser_id, opts)
    end

    :ok
  end

  defp wait_for_live_view(browser_id, opts) do
    deadline = System.monotonic_time(:millisecond) + opts[:wait_timeout_ms]
    do_wait_for_live_view(browser_id, deadline, opts[:command_timeout_ms])
  end

  defp do_wait_for_live_view(browser_id, deadline, command_timeout_ms) do
    case Browser.eval(browser_id, live_view_ready_script(), timeout_ms: command_timeout_ms) do
      {:ok, true} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(250)
          do_wait_for_live_view(browser_id, deadline, command_timeout_ms)
        end
    end
  end

  defp page_metadata(browser_id, opts) do
    Browser.eval(browser_id, page_metadata_script(), timeout_ms: opts[:command_timeout_ms])
  end

  defp page_metadata_script do
    """
    (() => {
      const root = document.querySelector("[data-phx-main]");
      const heading =
        Array.from(document.querySelectorAll("h1, h2"))
          .map((el) => (el.innerText || "").replace(/\\s+/g, " ").trim())
          .find(Boolean) || null;

      const textSource = root || document.body;
      const preview =
        ((textSource && textSource.innerText) || "")
          .replace(/\\s+/g, " ")
          .trim()
          .slice(0, 280) || null;

      return {
        title: document.title || null,
        contentType: document.contentType || null,
        heading,
        preview,
        liveView: !!root,
        hasImage: !!document.querySelector("img"),
        hasAudio: !!document.querySelector("audio"),
        hasVideo: !!document.querySelector("video"),
        readyState: document.readyState,
        href: window.location.href
      };
    })()
    """
  end

  defp navigation_probe_script do
    """
    (() => ({
      href: window.location.href,
      readyState: document.readyState,
      contentType: document.contentType || "",
      bodyTextLength: document.body?.innerText?.trim().length || 0,
      bodyChildCount: document.body?.children?.length || 0
    }))()
    """
  end

  defp live_view_ready_script do
    """
    (() => {
      const root = document.querySelector("[data-phx-main]");
      if (!root) return false;

      const textLength = (root.innerText || "").trim().length;
      const htmlLength = (root.innerHTML || "").length;
      const childCount = root.children?.length || 0;
      const hasSceneEditor = !!document.querySelector("#scene-editor");
      const hasMiniShell = !!document.querySelector("#tool-loop-viewer, #codex-live-viewer");

      return textLength > 40 || htmlLength > 200 || childCount > 1 || hasSceneEditor || hasMiniShell;
    })()
    """
  end

  defp describe_route(route, metadata) do
    handler_sentence =
      case route.handler_kind do
        :live_view -> "LiveView #{route.handler}."
        :controller -> "Controller #{route.handler}."
        _ -> "#{route.handler}."
      end

    visual_sentence =
      cond do
        present?(metadata["heading"]) and present?(metadata["preview"]) ->
          "Shows #{metadata["heading"]}. Preview: #{metadata["preview"]}"

        present?(metadata["heading"]) ->
          "Shows #{metadata["heading"]}."

        present?(metadata["preview"]) ->
          "Preview: #{metadata["preview"]}"

        metadata["hasImage"] ->
          "Chrome rendered a direct image response."

        metadata["hasAudio"] ->
          "Chrome rendered an audio response."

        present?(metadata["contentType"]) ->
          "Rendered as #{metadata["contentType"]}."

        true ->
          "Rendered without readable body text."
      end

    String.trim("#{handler_sentence} #{visual_sentence}")
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp handler_label(route) do
    case route.metadata[:phoenix_live_view] do
      {module, action, _opts, _session} ->
        "#{inspect(module)}##{action}"

      _ ->
        "#{inspect(route.plug)}##{route.plug_opts}"
    end
  end

  defp handler_kind(route) do
    if live_view_route?(route), do: :live_view, else: :controller
  end

  defp live_view_route?(route) do
    match?(
      {module, action, opts, session}
      when is_atom(module) and is_atom(action) and is_list(opts) and is_map(session),
      route.metadata[:phoenix_live_view]
    )
  end

  defp screenshot_filename(index, path) do
    ordinal = index |> Integer.to_string() |> String.pad_leading(3, "0")
    slug = slugify_path(path)
    "#{ordinal}-#{slug}.png"
  end

  defp slugify_path(path) when is_binary(path) do
    path
    |> String.trim("/")
    |> case do
      "" -> "root"
      trimmed -> trimmed
    end
    |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
    |> String.trim("-")
    |> String.downcase()
    |> String.slice(0, 100)
  end

  defp write_summary_files(summary, output_dir) do
    summary_path = Path.join(output_dir, "summary.json")
    markdown_path = Path.join(output_dir, "summary.md")

    json_payload =
      summary
      |> json_ready_summary(summary_path, markdown_path)
      |> Jason.encode!(pretty: true)

    markdown_payload = render_markdown_summary(summary)

    with :ok <- File.write(summary_path, json_payload),
         :ok <- File.write(markdown_path, markdown_payload) do
      {:ok,
       summary
       |> Map.put(:summary_path, summary_path)
       |> Map.put(:markdown_path, markdown_path)}
    end
  end

  defp json_ready_summary(summary, summary_path, markdown_path) do
    summary
    |> Map.put(:summary_path, summary_path)
    |> Map.put(:markdown_path, markdown_path)
    |> Map.update!(:generated_at, &DateTime.to_iso8601/1)
  end

  defp render_markdown_summary(summary) do
    header = [
      "# Froth Route Audit",
      "",
      "- Generated at: #{format_datetime(summary.generated_at)}",
      "- Base URL: #{summary.base_url}",
      "- Captured: #{summary.captured_count}",
      "- Skipped: #{summary.skipped_count}",
      "- Errors: #{summary.error_count}",
      ""
    ]

    body =
      Enum.map(summary.routes, fn route ->
        method = route |> Map.get(:method, :get) |> Atom.to_string() |> String.upcase()

        [
          "## #{Map.get(route, :index)}. `#{method} #{Map.get(route, :template)}`",
          "",
          Map.get(route, :url) && "- URL: #{Map.get(route, :url)}",
          Map.get(route, :screenshot_rel_path) &&
            "- Screenshot: `#{Map.get(route, :screenshot_rel_path)}`",
          Map.get(route, :title) && "- Title: #{Map.get(route, :title)}",
          Map.get(route, :page_heading) && "- Heading: #{Map.get(route, :page_heading)}",
          Map.get(route, :description) && "- Description: #{Map.get(route, :description)}",
          Map.get(route, :resolution) && "- Sample Source: #{Map.get(route, :resolution)}",
          Map.get(route, :skip_reason) && "- Skip Reason: #{Map.get(route, :skip_reason)}",
          Map.get(route, :error) && "- Error: `#{Map.get(route, :error)}`",
          ""
        ]
        |> Enum.reject(&is_nil/1)
      end)

    (header ++ List.flatten(body))
    |> Enum.join("\n")
  end

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end
end
