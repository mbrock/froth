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
        "Run a shell command via bash in the Froth environment. Use this for filesystem work, git inspection, local scripts, builds, and other OS-level actions that are better expressed as shell than Elixir. Fast commands return inline output; longer commands continue in the background and return a task_id for use with list_tasks, task_output, subscribe_task, stop_task, or send_input. The required description field is a user-visible observer note, so use it to explain the action, your layered goals, and your ungrounded assumptions before acting. A non-zero exit code is treated as an error, so do not assume a command worked unless the tool result says it did.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "Shell command to run."
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
  def execute(%Context{} = ctx, %ToolUse{input: input}, _hooks) when is_map(input) do
    shell_opts = [working_dir: Support.working_dir(input)]

    shell_opts =
      case ctx.bot_config do
        %BotConfig{id: bot_id} when is_binary(bot_id) ->
          Keyword.put(shell_opts, :telegram, %{bot_id: bot_id, chat_id: Support.chat_id(ctx)})

        _ ->
          shell_opts
      end

    Froth.Tasks.Shell.run_shell(input["command"], shell_opts)
  end
end
