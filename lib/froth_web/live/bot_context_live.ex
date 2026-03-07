defmodule FrothWeb.BotContextLive do
  use FrothWeb, :live_view

  alias Froth.Telegram.BotContextHTML

  @impl true
  def mount(_params, _session, socket) do
    ctx = BotContextHTML.sample_context()
    component = BotContextHTML.context(%{ctx: ctx})
    rendered = BotContextHTML.render_to_string(component)
    parts = BotContextHTML.render_to_parts(component)

    {:ok, assign(socket, ctx: ctx, rendered: rendered, parts: parts)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant={:plain}>
      <div class="mx-auto max-w-6xl px-6 py-8">
        <div class="rounded-2xl border border-zinc-200 bg-gradient-to-br from-white via-zinc-50 to-emerald-50 p-6 shadow-sm">
          <h1 class="text-2xl font-semibold tracking-tight text-zinc-900">Bot Context Preview</h1>
          <p class="mt-2 max-w-3xl text-sm leading-6 text-zinc-600">
            Sample context rendered from shared HEEx templates. This example includes summary text, analyses,
            and message-linked cycle traces.
          </p>
        </div>

        <div class="mt-6 grid gap-6 lg:grid-cols-2">
          <section class="rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm">
            <header class="mb-3 flex items-center justify-between">
              <h2 class="text-base font-medium text-zinc-900">Context Parts</h2>
              <span class="rounded-full bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-700">
                {length(@parts)} parts
              </span>
            </header>
            <div class="space-y-3">
              <div
                :for={{part, idx} <- Enum.with_index(@parts, 1)}
                class="rounded-xl border border-zinc-200"
              >
                <div class="border-b border-zinc-200 bg-zinc-50 px-3 py-1.5 text-xs font-medium text-zinc-600">
                  Part {idx}
                </div>
                <pre class="max-h-56 overflow-auto p-3 text-xs leading-5 text-zinc-800"><code>{part}</code></pre>
              </div>
            </div>
          </section>

          <section class="rounded-2xl border border-zinc-200 bg-zinc-950 p-5 shadow-sm">
            <h2 class="mb-3 text-base font-medium text-zinc-100">Rendered Markup</h2>
            <pre class="max-h-[32rem] overflow-auto text-xs leading-5 text-emerald-200"><code>{@rendered}</code></pre>
          </section>
        </div>

        <section class="mt-6 rounded-2xl border border-zinc-200 bg-white p-5 shadow-sm">
          <h2 class="mb-3 text-base font-medium text-zinc-900">Component Output</h2>
          <div class="overflow-auto rounded-xl border border-zinc-200 bg-zinc-50 p-4 text-sm font-mono text-zinc-800">
            <BotContextHTML.context ctx={@ctx} />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
