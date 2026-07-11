defmodule Froth.Codex.Threads do
  @moduledoc "Thread-centric queries against the shared Codex app-server."

  @spec list(pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list(limit \\ 120) when is_integer(limit) and limit > 0 do
    with {:ok, client} <- Froth.Codex.Server.client(),
         {:ok, result} <-
           Froth.Codex.thread_list(client, %{
             "limit" => limit,
             "sortKey" => "updated_at",
             "sortDirection" => "desc"
           }) do
      {:ok, Map.get(result, "data", [])}
    end
  end

  def list_sessions(limit \\ 120), do: list(limit)
end
