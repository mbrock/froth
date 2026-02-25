defmodule Froth.Replicate.SyncWorker do
  @moduledoc """
  Oban worker that fetches the Replicate collections list and enqueues
  a CollectionSyncWorker job for each one.
  """
  use Oban.Worker, queue: :replicate, max_attempts: 3

  require Logger

  @api_base "https://api.replicate.com/v1"

  @impl true
  def perform(%Oban.Job{}) do
    req = Finch.build(:get, "#{@api_base}/collections", Froth.Replicate.headers())

    case Finch.request(req, Froth.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        %{"results" => collections} = Jason.decode!(body)

        Enum.each(collections, fn c ->
          %{"slug" => c["slug"]}
          |> Froth.Replicate.CollectionSyncWorker.new()
          |> Oban.insert!()
        end)

        Logger.info(event: :replicate_sync_enqueued, collections: length(collections))
        :ok

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{String.slice(body, 0, 200)}"}

      {:error, err} ->
        {:error, inspect(err)}
    end
  end
end
