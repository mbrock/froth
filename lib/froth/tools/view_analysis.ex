defmodule Froth.Tools.ViewAnalysis do
  @moduledoc false

  @behaviour Froth.Tools.Definition

  import Ecto.Query

  alias Froth.Agent.CycleRuntime.Context
  alias Froth.Agent.ToolUse
  alias Froth.Analysis
  alias Froth.Context.Block
  alias Froth.Repo

  @impl true
  def name, do: "view_analysis"

  @impl true
  def label, do: "open analysis"

  @impl true
  def spec do
    %{
      "name" => name(),
      "description" =>
        "Read the full analysis text for one or more analysis IDs. Use this when timeline shows an analysis:N snippet and you want the complete analysis behind it. This is the right tool for media that has already been interpreted by other agents, such as photos, voice notes, videos, PDFs, YouTube links, or X posts. If you need the original image or PDF content block itself rather than the generated analysis text, use fetch instead.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "ids" => %{
            "type" => "array",
            "items" => %{"type" => "integer"},
            "description" =>
              "Analysis IDs to read, taken from analysis:N references in the chat log."
          }
        },
        "required" => ["ids"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def execute(%Context{}, %ToolUse{input: input}, _hooks)
      when is_map(input) do
    ids = input["ids"] || []

    analyses =
      Repo.all(
        from(a in Analysis,
          where: a.id in ^ids,
          select: %{
            id: a.id,
            type: a.type,
            message_id: a.message_id,
            agent: a.agent,
            analysis_text: a.analysis_text
          }
        ),
        log: false
      )

    if analyses == [] do
      {:ok, "No analyses found for the given IDs."}
    else
      {:ok,
       Enum.map(analyses, fn analysis ->
         Block.new(
           [
             kind: "analysis",
             id: analysis.id,
             type: analysis.type,
             message_id: analysis.message_id,
             agent: analysis.agent
           ],
           analysis.analysis_text
         )
       end)}
    end
  end
end
