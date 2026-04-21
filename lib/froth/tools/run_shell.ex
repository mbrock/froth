defmodule Froth.Tools.RunShell do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse
  alias Froth.Telegram.Bot.Config, as: BotConfig
  alias Froth.Tools.Support

  @impl true
  def name, do: "run_shell"

  @impl true
  def label, do: "run shell"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        """
        Run a shell command via bash in the Froth environment. Use this for filesystem work, git inspection, local scripts, builds, and other OS-level actions that are better expressed as shell than Elixir.

        This is not a plain terminal. Command output is captured as a structured block and handled by Froth before it reaches you, so several habits from normal shell usage are unnecessary here:

        * Large text output is fine. Long output is automatically folded into head + tail with the omitted middle stored in a blob (shown as `blob:01K…`), and you can read the middle or search it later with the `pager` tool. Do not pipe into `head`, `tail`, `cut`, `wc -l`, or `less` just to avoid "too much output" — emit the full output and inspect it at your own pace.
        * Binary output is fine. Bytes that are not safe as text (invalid UTF-8, NUL) are auto-detected, MIME-sniffed, and stored in a blob. Images and PDFs are delivered to you as real content parts, so `cat logo.png`, `curl -sL https://…/cat.jpg`, or `pdftoppm …` will actually show you the image/document — no need to base64-encode or hex-dump first. The text stream will also carry a `[binary: <mime> <N> bytes → blob:…]` placeholder so you can always see that something was captured and where it went.
        * Slow or long-running commands are fine. If the command has not finished after a short window, it continues in the background and the tool result gives you a `task_id`; use `list_tasks`, `task_output`, `subscribe_task`, `send_input`, or `stop_task` to drive it from there. Do not wrap things in `timeout`, `nohup`, or `&` just to keep the call snappy — run the real command.

        The required `description` field is a user-visible observer note: use it to state the action, your layered goals, and the ungrounded assumptions this invocation depends on before acting. A non-zero exit code is treated as an error, so do not assume a command worked unless the tool result says it did.
        """
        |> String.trim(),
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" =>
              "Shell command to run. Bash syntax; multi-line and pipelines are fine. Emit the full output you actually want — no need to pre-truncate with head/tail/wc, and no need to avoid commands that produce binary. Runs under `/bin/bash -c` with stderr merged into stdout."
          },
          "description" => %{
            "type" => "object",
            "description" =>
              "Required structured observer note that becomes visible to humans while the tool runs. Use it to say what action you are taking, what success hierarchy you are pursuing, and what ungrounded assumptions this invocation depends on.",
            "properties" => %{
              "action" => %{
                "type" => "string",
                "description" =>
                  "A present-tense verb phrase labeling the action, for example \"Listing the workspace root\"."
              },
              "goals" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "maxItems" => 3,
                "description" =>
                  "A short stack of desired outcomes, in order, up to three items long. Express the hierarchy of what you are trying to achieve, from immediate check to broader practical aim."
              },
              "assumptions" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" =>
                  "Things that must be true for this invocation to succeed but that you are not actually grounded enough to claim yet."
              }
            },
            "required" => ["action", "goals", "assumptions"],
            "additionalProperties" => false
          },
          "working_dir" => %{
            "type" => "string",
            "description" =>
              "Optional working directory for the command. Defaults to the Froth project root."
          }
        },
        "required" => ["command", "description"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(%Context{} = ctx, %ToolUse{input: input}, _hooks)
      when is_map(input) do
    shell_opts = [working_dir: Support.working_dir(input)]

    shell_opts =
      case ctx.bot_config do
        %BotConfig{id: bot_id} when is_binary(bot_id) ->
          Keyword.put(shell_opts, :telegram, %{
            bot_id: bot_id,
            chat_id: Support.chat_id(ctx)
          })

        _ ->
          shell_opts
      end

    Froth.Tasks.Shell.run_shell(input["command"], shell_opts)
  end
end
