defmodule Froth.Tools.ElixirEval do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.ElixirDocs
  alias Froth.Agent.ToolUse
  alias Froth.Tools.Support

  @impl true
  def name, do: "elixir_eval"

  @impl true
  def label, do: "run code"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Evaluate Elixir code on the live Froth node. This is the main way to inspect or manipulate real runtime state: Ecto repos, OTP processes, registries, GenServers, and Froth modules are all available. Use it for ad-hoc queries, system inspection, one-off automation, and calling application APIs, and prefer it over guessing how the system works. Variable bindings persist inside an eval session, so reuse session_id when a sequence of evals should share local variables; if you need module docs or function signatures, call Froth.help(Module) instead of inventing them. The required description field is a user-visible observer note, so fill it in concretely before acting. If execution runs long, it continues in the background and returns a task_id that you can inspect with the task tools.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "code" => %{
            "type" => "string",
            "description" =>
              "Elixir code to evaluate. The value of the last expression is returned."
          },
          "description" => %{
            "type" => "object",
            "description" =>
              "Required structured observer note that becomes visible to humans while the tool runs. Use it to say what action you are taking, what success hierarchy you are pursuing, and what ungrounded assumptions this invocation depends on.",
            "properties" => %{
              "action" => %{
                "type" => "string",
                "description" =>
                  "A present-tense verb phrase labeling the action, for example \"Inspecting the runtime registry\"."
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
          "session_id" => %{
            "type" => "string",
            "description" =>
              "Optional eval session ID. Variables declared in one eval remain available to later evals that reuse the same session_id."
          }
        },
        "required" => ["code", "description"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(%Context{} = ctx, %ToolUse{input: input}, _hooks) when is_map(input) do
    case input["mode"] do
      "docs" ->
        ElixirDocs.query(input)

      _ ->
        eval_opts = [session_id: Support.eval_session_id(input)]
        eval_opts = Support.maybe_put_eval_topic(eval_opts, ctx)
        eval_opts = Support.maybe_put_eval_telegram(eval_opts, ctx)
        Froth.Tasks.Eval.run_eval(input["code"], eval_opts)
    end
  end
end
