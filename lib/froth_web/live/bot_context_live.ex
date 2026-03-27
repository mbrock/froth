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
      recent_message_limit: config.recent_message_limit
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
      <div class="mx-auto max-w-4xl px-6 py-10 font-mono text-sm text-base-content">
        <header class="mb-8">
          <h1 class="text-lg font-bold">charlie context</h1>
          <p class="text-xs opacity-50">
            chat {@chat_id} · model {@model} · {length(@parts)} parts
          </p>
        </header>

        <section class="mb-10">
          <h2 class="mb-2 text-xs font-bold uppercase tracking-wide opacity-40">system</h2>
          <pre class="whitespace-pre-wrap text-xs leading-relaxed">{@system_prompt}</pre>
        </section>

        <details
          :for={{part, idx} <- Enum.with_index(@parts, 1)}
          class="mb-4"
          open={idx > length(@parts) - 20}
        >
          <summary class="cursor-pointer text-xs font-bold uppercase tracking-wide opacity-40">
            part {idx}
            <span class="ml-2 font-normal">{String.length(part)} chars</span>
          </summary>
          <pre class="mt-2 whitespace-pre-wrap text-xs leading-relaxed">{part}</pre>
        </details>
      </div>
    </Layouts.app>
    """
  end
end
