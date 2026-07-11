defmodule FrothWeb.BotContextLive do
  use FrothWeb, :live_view

  alias Froth.Telegram.BotContext
  alias Froth.Telegram.Charlie

  @default_chat_id -1_003_690_254_489

  @impl true
  def mount(_params, _session, socket) do
    config = Charlie.default_config()

    opts = [
      telegram_session_id: config.session_id,
      bot_id: config.id,
      chronicle_dir: config.chronicle_dir,
      recent_message_limit: Map.get(config, :recent_message_limit),
      recent_window_target_hours:
        Map.get(config, :recent_window_target_hours),
      recent_window_min_hours: Map.get(config, :recent_window_min_hours),
      recent_window_backfill_hours:
        Map.get(config, :recent_window_backfill_hours),
      recent_window_char_budget: Map.get(config, :recent_window_char_budget),
      recent_window_bucket_minutes:
        Map.get(config, :recent_window_bucket_minutes)
    ]

    parts = BotContext.render_parts(@default_chat_id, opts)
    system_prompt = config.system_prompt_fun.(@default_chat_id, config)

    {:ok,
     assign(socket,
       parts: parts,
       system_prompt: system_prompt,
       chat_id: @default_chat_id,
       model: config.model
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <main
        id="bot-context-reader"
        class="min-h-screen overflow-x-hidden bg-[#fefef8] px-4 py-10 text-[#1a1a1a] sm:px-6 sm:py-14"
      >
        <div class="mx-auto max-w-[760px]">
          <header class="text-center [font-family:'Times_New_Roman',Times,Georgia,serif]">
            <p class="text-[11px] uppercase tracking-[0.24em] text-stone-500">
              Charlie's working memory
            </p>
            <h1 class="mt-2 text-4xl font-normal tracking-[0.03em] [font-variant:small-caps] sm:text-5xl">
              Bot Context
            </h1>
            <p class="mx-auto mt-5 max-w-xl text-base italic leading-7 text-stone-600">
              The exact layered context Charlie receives before a conversation turn
            </p>
          </header>

          <nav
            id="memory-reader-nav"
            aria-label="Chronicle archives"
            class="mt-6 flex flex-wrap justify-center gap-2 [font-family:ui-sans-serif,system-ui,sans-serif]"
          >
            <a
              href={~p"/froth/summaries"}
              class="rounded-full border border-stone-300 px-3.5 py-1 text-xs tracking-wide text-stone-600 transition hover:border-stone-500 hover:text-stone-950"
            >
              Daily
            </a>
            <a
              href={~p"/froth/weekly"}
              class="rounded-full border border-stone-300 px-3.5 py-1 text-xs tracking-wide text-stone-600 transition hover:border-stone-500 hover:text-stone-950"
            >
              Weekly
            </a>
            <a
              href={~p"/froth/bot-context"}
              aria-current="page"
              class="rounded-full border border-stone-400 bg-[#eeeae0] px-3.5 py-1 text-xs tracking-wide text-stone-950"
            >
              Bot context
            </a>
          </nav>

          <div class="mt-12 border-y border-stone-300 py-4 [font-family:ui-monospace,SFMono-Regular,Menlo,monospace] text-[11px] text-stone-500 sm:flex sm:items-center sm:justify-between">
            <span>chat {@chat_id}</span>
            <span class="mt-1 block sm:mt-0">
              {@model} · {length(@parts)} cached parts
            </span>
          </div>

          <section id="bot-context-system" class="mt-10">
            <div class="mb-3 flex items-baseline justify-between gap-4">
              <h2 class="[font-family:'Times_New_Roman',Times,Georgia,serif] text-xl [font-variant:small-caps]">
                System prompt
              </h2>
              <span class="font-mono text-[10px] uppercase tracking-wider text-stone-400">
                {String.length(@system_prompt)} chars
              </span>
            </div>
            <pre class="overflow-x-auto whitespace-pre-wrap border-l-2 border-stone-300 bg-[#faf8f1] px-5 py-4 font-mono text-[12px] leading-6 text-stone-700">{@system_prompt}</pre>
          </section>

          <section id="bot-context-parts" class="mt-12">
            <div class="mb-4">
              <h2 class="[font-family:'Times_New_Roman',Times,Georgia,serif] text-2xl [font-variant:small-caps]">
                Context parts
              </h2>
              <p class="mt-1 text-sm italic text-stone-500 [font-family:'Times_New_Roman',Times,Georgia,serif]">
                Chronicle chapters, summaries, and the recent conversation in cache-friendly order
              </p>
            </div>

            <details
              :for={{part, idx} <- Enum.with_index(@parts, 1)}
              id={"bot-context-part-#{idx}"}
              class="group border-t border-stone-300 last:border-b"
              open={idx > length(@parts) - 20}
            >
              <summary class="flex cursor-pointer list-none items-center justify-between gap-4 py-3.5 font-mono text-[11px] uppercase tracking-[0.12em] text-stone-500 transition hover:text-stone-950 marker:hidden">
                <span class="flex items-center gap-2">
                  <span class="inline-block text-stone-400 transition group-open:rotate-90">
                    ›
                  </span>
                  part {idx}
                </span>
                <span class="font-normal normal-case tracking-normal text-stone-400">
                  {String.length(part)} chars
                </span>
              </summary>
              <pre class="mb-5 overflow-x-auto whitespace-pre-wrap bg-[#faf8f1] px-5 py-4 font-mono text-[12px] leading-6 text-stone-700">{part}</pre>
            </details>
          </section>

          <footer class="mt-16 border-t border-stone-300 py-8 text-center [font-family:'Times_New_Roman',Times,Georgia,serif] text-sm italic text-stone-400">
            The assembled prompt, shown without inference or interpretation
          </footer>
        </div>
      </main>
    </Layouts.app>
    """
  end
end
