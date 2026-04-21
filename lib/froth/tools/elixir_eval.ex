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
        "Elixir multitool for the live Froth node. Use `action=\"eval\"` to run Elixir code against real runtime state: Ecto repos, OTP processes, registries, GenServers, and Froth modules are all available, and eval session bindings persist when you reuse `session_id`. Use `action=\"docs\"` to inspect loaded modules and functions reflexively, including signatures, docs, Froth module hierarchy, and optional source clips when available. Prefer this tool over guessing how the system works. For `eval`, the `description` field is a user-visible observer note, so fill it in concretely before acting. If an eval runs long, it continues in the background and returns a task_id that you can inspect with the task tools.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ["eval", "docs"],
            "description" =>
              "What to do. Use `eval` to run code and `docs` to inspect modules/functions. Defaults to `eval` when `code` is present, otherwise `docs`."
          },
          "code" => %{
            "type" => "string",
            "description" =>
              "For `eval`: Elixir code to evaluate. The value of the last expression is returned."
          },
          "description" => %{
            "type" => "object",
            "description" =>
              "For `eval`: required structured observer note that becomes visible to humans while the tool runs. Use it to say what action you are taking, what success hierarchy you are pursuing, and what ungrounded assumptions this invocation depends on.",
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
              "For `eval`: optional eval session ID. Variables declared in one eval remain available to later evals that reuse the same session_id."
          },
          "targets" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "For `docs`: modules or functions to inspect, such as `Froth.Telegram`, `Froth.help/1`, or `Code.string_to_quoted_with_comments/2`. Omit or pass an empty list to get an overview of the Froth module hierarchy."
          },
          "include_source" => %{
            "type" => "boolean",
            "description" =>
              "For `docs`: include source clips when the source file is available. For Elixir standard-library modules, Froth will try to fetch and cache the matching source for the running Elixir version."
          }
        },
        "required" => [],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(%Context{} = ctx, %ToolUse{input: input}, _hooks)
      when is_map(input) do
    case action(input) do
      "docs" ->
        ElixirDocs.query(input)

      "eval" ->
        with {:ok, code} <- Support.required_trimmed_string(input, "code"),
             :ok <- validate_eval_description(input["description"]) do
          eval_opts = [session_id: Support.eval_session_id(input)]
          eval_opts = Support.maybe_put_eval_topic(eval_opts, ctx)
          eval_opts = Support.maybe_put_eval_telegram(eval_opts, ctx)
          Froth.Tasks.Eval.run_eval(code, eval_opts)
        end

      other ->
        {:error, "Unknown action for elixir_eval: #{inspect(other)}"}
    end
  end

  defp action(input) when is_map(input) do
    cond do
      is_binary(input["action"]) and input["action"] != "" ->
        input["action"]

      input["mode"] == "docs" ->
        "docs"

      is_binary(input["code"]) and String.trim(input["code"]) != "" ->
        "eval"

      true ->
        "docs"
    end
  end

  defp validate_eval_description(%{} = description) do
    with :ok <-
           validate_description_string(
             description["action"],
             "description.action"
           ),
         :ok <-
           validate_description_list(
             description["goals"],
             "description.goals"
           ),
         :ok <-
           validate_description_list(
             description["assumptions"],
             "description.assumptions"
           ) do
      :ok
    end
  end

  defp validate_eval_description(_),
    do: {:error, "description must be an object for eval"}

  defp validate_description_string(value, label) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, "#{label} must be a non-empty string"}
    else
      :ok
    end
  end

  defp validate_description_string(_value, label),
    do: {:error, "#{label} must be a string"}

  defp validate_description_list(values, label) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, "#{label} must be a list of non-empty strings"}
    end
  end

  defp validate_description_list(_values, label),
    do: {:error, "#{label} must be a list of non-empty strings"}
end
