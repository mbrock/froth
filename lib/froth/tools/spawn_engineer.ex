defmodule Froth.Tools.SpawnEngineer do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse
  alias Froth.Context.Block
  alias Froth.Tools.Support

  @impl true
  def name, do: "spawn_engineer"

  @impl true
  def label, do: "spawn engineer"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Dispatch a coding task to Codex, a trusted senior engineer who works in the background. This is the best way to do complex coding work — refactors, migrations, new features, bug fixes. Codex gets NO chat context, so your prompt must be self-contained: explain what we want done, why, and any constraints. Do NOT over-specify implementation details — Codex is a competent engineer who will read the codebase, make good architectural decisions, commit the result, and report back. Codex has excellent web search capabilities built in, so it can find docs, APIs, solutions, and examples on its own — you do not need to look things up for it. Think of it as explaining the problem to a colleague, not dictating line-by-line changes. Good: 'the telemetry live view is too fluffy on mobile; tighten the layout significantly.' Bad: 'change .events-header padding from 1.5rem to 0.25rem in lib/froth/...' Returns a session URL where you can watch progress. The task runs in background — you do not need to wait.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "prompt" => %{
            "type" => "string",
            "description" =>
              "What you want built or fixed. Be clear about the goal, not the implementation. Codex will figure out the how."
          }
        },
        "required" => ["prompt"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(%Context{} = ctx, %ToolUse{input: input}, _hooks) when is_map(input) do
    with {:ok, prompt} <- Support.required_trimmed_string(input, "prompt") do
      case Froth.Codex.Task.run(prompt, chat_id: Support.chat_id(ctx)) do
        {:ok, session_id} ->
          url = Froth.Codex.Task.url(session_id)

          {:ok,
           [
             Block.new(
               [kind: "engineer_spawned", session_id: session_id, url: url],
               nil
             )
           ]}

        {:error, reason} ->
          {:error, "Failed to start Codex task: #{inspect(reason)}"}
      end
    end
  end
end
