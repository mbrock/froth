defmodule FrothWeb.PageController do
  use FrothWeb, :controller

  def home(conn, _params) do
    conn
    |> assign(:page_title, "Froth")
    |> assign(:primary_links, primary_links())
    |> assign(:secondary_links, secondary_links())
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
        description: "Watch the event stream, search it, and inspect one entry at a time.",
        badge: "live",
        path_label: "/froth/follow",
        icon: "hero-rss",
        icon_class: "border-emerald-400/20 bg-emerald-400/10 text-emerald-100",
        badge_class: "border-emerald-400/20 bg-emerald-400/10 text-emerald-100"
      },
      %{
        id: "froth-link-headlines",
        href: ~p"/froth/headlines",
        title: "Headlines",
        description: "Open the tabloid headline ledger for the latest registered stories.",
        badge: "reader",
        path_label: "/froth/headlines",
        icon: "hero-newspaper",
        icon_class: "border-amber-400/20 bg-amber-400/10 text-amber-100",
        badge_class: "border-amber-400/20 bg-amber-400/10 text-amber-100"
      },
      %{
        id: "froth-link-podcasts",
        href: ~p"/froth/podcasts",
        title: "Podcasts",
        description: "Every generated episode with audio players and full manuscripts.",
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
        description: "Read the long-form daily summaries in a plain document-style view.",
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
        description: "Inspect the XML-like context rendered for Telegram bot prompts.",
        badge: "prompt",
        path_label: "/froth/bot-context",
        icon: "hero-chat-bubble-left-right",
        icon_class: "border-violet-400/20 bg-violet-400/10 text-violet-100",
        badge_class: "border-violet-400/20 bg-violet-400/10 text-violet-100"
      },
      %{
        id: "froth-link-analyses",
        href: ~p"/froth/analyses",
        title: "Analyses",
        description: "Browse the media and text analyses grouped by day.",
        badge: "day view",
        path_label: "/froth/analyses",
        icon: "hero-chart-bar",
        icon_class: "border-sky-400/20 bg-sky-400/10 text-sky-100",
        badge_class: "border-sky-400/20 bg-sky-400/10 text-sky-100"
      }
    ]
  end

  defp secondary_links do
    [
      %{
        id: "froth-link-dataset",
        href: ~p"/froth/dataset",
        title: "Dataset",
        description: "Inspect collections, models, and other stored records.",
        icon: "hero-cube",
        icon_class: "border-lime-400/20 bg-lime-400/10 text-lime-100"
      },
      %{
        id: "froth-link-wiki",
        href: ~p"/froth/wiki",
        title: "Wiki",
        description: "Open the Encyclopædia Pallica entry browser.",
        icon: "hero-globe-alt",
        icon_class: "border-cyan-400/20 bg-cyan-400/10 text-cyan-100"
      },
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
        description: "Watch the queue, retry jobs, and inspect backlog state.",
        icon: "hero-wrench-screwdriver",
        icon_class: "border-emerald-400/20 bg-emerald-400/10 text-emerald-100"
      },
      %{
        id: "froth-link-scene",
        href: ~p"/froth/scene",
        title: "Scene",
        description: "Open the scene viewer and related drilldowns.",
        icon: "hero-film",
        icon_class: "border-rose-400/20 bg-rose-400/10 text-rose-100"
      }
    ]
  end
end
