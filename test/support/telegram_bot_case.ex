defmodule Froth.TelegramBotCase do
  @moduledoc """
  Test case template for tests that exercise a live `Froth.Telegram.Bot`
  plus a `Froth.FakeTelegramSession`, with a per-test Ecto sandbox
  owner.

  Replaces the ad-hoc setup boilerplate that used to live in each
  individual test module (separate sandbox checkouts, separate
  fake-session boot, near-identical `start_charlie_bot/1` helpers).

  ## Usage

      defmodule MyTest do
        use Froth.TelegramBotCase, async: true

        test "something" do
          %{bot_ref: bot_ref, bot_id: _bot_id, session_id: _sid} = start_charlie_bot()
          # ... interact with bot ...
        end
      end

  Set `async: false` when the test relies on application-wide singleton
  state it cannot scope to a per-test owner.

  ## What the setup gives you

    * A per-test Ecto sandbox owner process (`start_owner!/2`) that is
      torn down in an `on_exit/1` callback. Allowed-chain processes
      transitively reach this owner via `Froth.Repo.allow/2`.
    * `import`s `Froth.TelegramBotCase` so `start_charlie_bot/1` and
      `start_fake_session/1` are callable without qualification.

  ## Fixtures

    * `start_fake_session/1` — starts a `Froth.FakeTelegramSession`
      under the test supervisor and returns the `session_id`.
    * `start_charlie_bot/1` — starts a fake session *and* a `Bot` in
      one call, with sane Charlie-profile defaults. Caller overrides
      any keyword option. Returns `%{bot: pid, bot_ref: via, bot_id: id,
      session_id: id}`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Froth.LLM.Fake, as: FakeLLM
      alias Froth.Repo
      alias Froth.Telegram.Bot

      import Froth.TelegramBotCase
    end
  end

  setup tags do
    Froth.Repo.put_test_context(tags)

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Froth.Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Start a `Froth.FakeTelegramSession` under the current test supervisor.
  Returns the session id (generated if not supplied).
  """
  def start_fake_session(opts \\ []) do
    session_id =
      Keyword.get(opts, :session_id, "session-#{System.unique_integer([:positive])}")

    session_opts =
      opts
      |> Keyword.put(:session_id, session_id)
      |> Keyword.put(:test_pid, self())

    ExUnit.Callbacks.start_supervised!({Froth.FakeTelegramSession, session_opts})

    session_id
  end

  @doc """
  Start a fake Telegram session *and* a `Froth.Telegram.Bot` configured
  with the Charlie-profile defaults. Unspecified `:id`, `:session_id`,
  and `:model` get unique generated values (the model is claimed via
  `FakeLLM.claim/0`, so any request routed to it lands on the current
  test pid via `assert_receive`).

  Returns `%{bot: pid, bot_ref: via, bot_runtime: pid, bot_id: id, session_id: id, model: id}`.
  """
  def start_charlie_bot(opts \\ []) do
    session_id =
      Keyword.get_lazy(opts, :session_id, fn ->
        "charlie-session-#{System.unique_integer([:positive])}"
      end)

    bot_id =
      Keyword.get_lazy(opts, :id, fn -> "charlie-#{System.unique_integer([:positive])}" end)

    model = Keyword.get_lazy(opts, :model, fn -> Froth.LLM.Fake.claim() end)

    _ = start_fake_session(session_id: session_id)

    bot_opts =
      [
        id: bot_id,
        session_id: session_id,
        model: model,
        bot_username: "charliebuddybot",
        bot_user_id: 1,
        owner_user_id: 1,
        system_prompt: "You are Charlie.",
        debounce_ms: 0,
        tools_module: Froth.Telegram.Toolsets.Charlie
      ]
      |> Keyword.merge(opts)
      |> Keyword.put(:id, bot_id)
      |> Keyword.put(:session_id, session_id)
      |> Keyword.put(:model, model)
      |> Keyword.put_new(:name, Froth.Telegram.Bots.via(bot_id))

    runtime = ExUnit.Callbacks.start_supervised!({Froth.Telegram.BotRuntime, bot_opts})
    bot_ref = Froth.Telegram.Bots.via(bot_id)
    {bot, _config} = Froth.Telegram.Bot.snapshot(bot_ref)

    %{
      bot: bot,
      bot_ref: bot_ref,
      bot_runtime: runtime,
      bot_id: bot_id,
      session_id: session_id,
      model: model
    }
  end
end
