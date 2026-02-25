defmodule Froth.Inference.Recovery do
  @moduledoc """
  Restart/recovery handling for persisted inference sessions.
  """

  require Logger

  alias Froth.Inference.StepLog
  alias Froth.Repo
  alias Froth.Inference.InferenceSession
  import Ecto.Query

  def resume_on_startup(bot_id) when is_binary(bot_id) do
    {n, _} =
      Repo.update_all(
        from(c in InferenceSession,
          where: c.bot_id == ^bot_id and c.status in ["pending", "streaming"]
        ),
        set: [status: "error"]
      )

    if n > 0, do: Logger.info(event: :interrupted_inference_sessions, count: n)

    awaiting =
      Repo.all(
        from(c in InferenceSession, where: c.bot_id == ^bot_id and c.status == "awaiting_tools")
      )

    Enum.each(awaiting, fn inference_session ->
      if Enum.any?(inference_session.pending_tools, &(&1["status"] == "executing")) do
        pending_tools =
          Enum.map(inference_session.pending_tools, fn tool ->
            if tool["status"] == "executing" do
              %{
                tool
                | "status" => "resolved",
                  "result" => "Interrupted by restart.",
                  "is_error" => true
              }
            else
              tool
            end
          end)

        inference_session
        |> InferenceSession.changeset(%{pending_tools: pending_tools})
        |> Repo.update!()

        StepLog.append(inference_session.id, "recovered_after_restart", %{
          "interrupted_executing" => true
        })
      end

      inference_session = Repo.get!(InferenceSession, inference_session.id)

      if Enum.all?(inference_session.pending_tools, &(&1["status"] in ["resolved", "stopped"])) and
           inference_session.status == "awaiting_tools" do
        send(self(), {:resume_inference_session, inference_session.id})
      end
    end)

    resumable =
      Repo.aggregate(
        from(c in InferenceSession, where: c.bot_id == ^bot_id and c.status == "awaiting_tools"),
        :count
      )

    if resumable > 0, do: Logger.info(event: :resumable_inference_sessions, count: resumable)
    :ok
  end
end
