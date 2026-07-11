defmodule FrothWeb.PageController do
  use FrothWeb, :controller

  import Ecto.Query

  alias Froth.{Analysis, ChatSummary, Repo, Task}

  @chat_id -1_003_690_254_489

  def home(conn, _params) do
    conn
    |> assign(:page_title, "Froth")
    |> assign(:primary_links, primary_links())
    |> assign(:secondary_links, secondary_links())
    |> assign(:dashboard, dashboard())
    |> render(:home)
  end

  defp primary_links do
    [
      %{
        id: "froth-link-codex",
        href: ~p"/froth/mini/codex",
        title: "Codex index",
        description: "Browse persisted sessions and open a new Codex run.",
        badge: "mini / live",
        path_label: "/froth/mini/codex",
        icon: "hero-code-bracket-square",
        icon_class: "border-cyan-400/20 bg-cyan-400/10 text-cyan-100",
        badge_class: "border-cyan-400/20 bg-cyan-400/10 text-cyan-100"
      },
      %{
        id: "froth-link-follow",
        href: ~p"/froth/follow",
        title: "Follow",
        description:
          "Watch the event stream, search it, and inspect one entry at a time.",
        badge: "live",
        path_label: "/froth/follow",
        icon: "hero-rss",
        icon_class:
          "border-emerald-400/20 bg-emerald-400/10 text-emerald-100",
        badge_class:
          "border-emerald-400/20 bg-emerald-400/10 text-emerald-100"
      },
      %{
        id: "froth-link-podcasts",
        href: ~p"/froth/podcasts",
        title: "Podcasts",
        description:
          "Every generated episode with audio players and full manuscripts.",
        badge: "archive",
        path_label: "/froth/podcasts",
        icon: "hero-microphone",
        icon_class: "border-orange-400/20 bg-orange-400/10 text-orange-100",
        badge_class: "border-orange-400/20 bg-orange-400/10 text-orange-100"
      },
      %{
        id: "froth-link-chronicle",
        href: ~p"/froth/summaries",
        title: "Chronicle",
        description:
          "Read the long-form daily summaries in a plain document-style view.",
        badge: "archive",
        path_label: "/froth/summaries",
        icon: "hero-book-open",
        icon_class: "border-rose-400/20 bg-rose-400/10 text-rose-100",
        badge_class: "border-rose-400/20 bg-rose-400/10 text-rose-100"
      },
      %{
        id: "froth-link-bot-context",
        href: ~p"/froth/bot-context",
        title: "Bot context",
        description:
          "Inspect the XML-like context rendered for Telegram bot prompts.",
        badge: "prompt",
        path_label: "/froth/bot-context",
        icon: "hero-chat-bubble-left-right",
        icon_class: "border-violet-400/20 bg-violet-400/10 text-violet-100",
        badge_class: "border-violet-400/20 bg-violet-400/10 text-violet-100"
      },
      %{
        id: "froth-link-analyses",
        href: ~p"/froth/analyses/day",
        title: "Analyses",
        description: "Browse the media and text analyses grouped by day.",
        badge: "day view",
        path_label: "/froth/analyses/day",
        icon: "hero-chart-bar",
        icon_class: "border-sky-400/20 bg-sky-400/10 text-sky-100",
        badge_class: "border-sky-400/20 bg-sky-400/10 text-sky-100"
      }
    ]
  end

  defp secondary_links do
    [
      %{
        id: "froth-link-chat-stats",
        href: ~p"/froth/chat-stats",
        title: "Chat stats",
        description: "Review sender breakdowns and day-by-day chat activity.",
        icon: "hero-chart-pie",
        icon_class: "border-amber-400/20 bg-amber-400/10 text-amber-100"
      },
      %{
        id: "froth-link-jobs",
        href: ~p"/froth/jobs",
        title: "Jobs",
        description:
          "Watch the queue, retry jobs, and inspect backlog state.",
        icon: "hero-wrench-screwdriver",
        icon_class: "border-emerald-400/20 bg-emerald-400/10 text-emerald-100"
      }
    ]
  end

  defp dashboard do
    Froth.Tasks.reconcile_stale_process_tasks()

    task_counts =
      Repo.all(
        from(t in Task,
          group_by: t.status,
          select: {t.status, count(t.task_id)}
        ),
        log: false
      )
      |> Map.new()

    job_counts =
      Repo.all(
        from(j in Oban.Job,
          group_by: j.state,
          select: {j.state, count(j.id)}
        ),
        log: false
      )
      |> Map.new()

    recent_tasks =
      Repo.all(
        from(t in Task,
          order_by: [desc: t.inserted_at],
          limit: 5,
          select: %{
            id: t.task_id,
            label: t.label,
            type: t.type,
            status: t.status
          }
        ),
        log: false
      )

    latest_summary =
      Repo.one(
        from(s in ChatSummary,
          where: s.chat_id == ^@chat_id,
          where: s.from_date != s.to_date,
          where: fragment("? - ? <= 86400", s.to_date, s.from_date),
          order_by: [desc: s.from_date, desc: s.inserted_at],
          limit: 1
        ),
        log: false
      )

    recent_analyses =
      Repo.all(
        from(a in Analysis,
          order_by: [desc: a.generated_at],
          limit: 5,
          select: %{
            type: a.type,
            generated_at: a.generated_at,
            metadata: a.metadata
          }
        ),
        log: false
      )

    %{
      active_tasks:
        Map.get(task_counts, "running", 0) +
          Map.get(task_counts, "pending", 0),
      failed_tasks: Map.get(task_counts, "failed", 0),
      queued_jobs:
        Map.get(job_counts, "available", 0) +
          Map.get(job_counts, "scheduled", 0),
      executing_jobs: Map.get(job_counts, "executing", 0),
      discarded_jobs: Map.get(job_counts, "discarded", 0),
      analysis_count: Repo.aggregate(Analysis, :count, :id),
      weekly_count:
        Repo.aggregate(
          from(s in ChatSummary,
            where: fragment("?->>'kind' = 'weekly_chronicle'", s.metadata)
          ),
          :count
        ),
      latest_summary: latest_summary,
      recent_tasks: recent_tasks,
      recent_analyses: recent_analyses
    }
  end
end
