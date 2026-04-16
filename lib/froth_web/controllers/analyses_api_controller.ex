defmodule FrothWeb.AnalysesApiController do
  use FrothWeb, :controller

  import Ecto.Query

  alias Froth.Analysis
  alias Froth.Repo

  @default_limit 100
  @max_limit 1000
  @example_chat_id -1_003_690_254_489

  def index(conn, _params) do
    json(conn, %{
      endpoint: "/froth/analyses/:chat_id",
      method: "GET",
      description: "Returns analyses for a Telegram chat ordered by message_id ascending.",
      query_params: %{
        after: "Optional message_id cursor. Only analyses with message_id > after are returned.",
        limit: "Optional page size. Defaults to 100 and is capped at 1000."
      },
      example: "/froth/analyses/#{@example_chat_id}?after=12345&limit=200"
    })
  end

  def show(conn, %{"chat_id" => chat_id_param} = params) do
    with {:ok, chat_id} <- parse_integer(chat_id_param, "chat_id"),
         {:ok, after_message_id} <- parse_optional_integer(params["after"], "after"),
         {:ok, limit} <- parse_limit(params["limit"]) do
      analyses =
        chat_id
        |> analyses_query(after_message_id)
        |> limit(^limit)
        |> Repo.all(log: false)

      json(conn, analyses)
    else
      {:error, {param, message}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: message, param: param})
    end
  end

  defp analyses_query(chat_id, after_message_id) do
    Analysis
    |> where([a], a.chat_id == ^chat_id)
    |> maybe_after_message_id(after_message_id)
    |> order_by([a], asc: a.message_id, asc: a.id)
    |> select([a], %{
      id: a.id,
      type: a.type,
      chat_id: a.chat_id,
      message_id: a.message_id,
      agent: a.agent,
      analysis_text: a.analysis_text,
      metadata: a.metadata,
      generated_at: a.generated_at,
      inserted_at: a.inserted_at
    })
  end

  defp maybe_after_message_id(query, nil), do: query

  defp maybe_after_message_id(query, after_message_id) do
    where(query, [a], a.message_id > ^after_message_id)
  end

  defp parse_optional_integer(nil, _param), do: {:ok, nil}
  defp parse_optional_integer(value, param), do: parse_integer(value, param)

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(value) do
    with {:ok, parsed_limit} <- parse_integer(value, "limit"),
         true <- parsed_limit >= 0 or {:error, {"limit", "must be a non-negative integer"}} do
      {:ok, min(parsed_limit, @max_limit)}
    end
  end

  defp parse_integer(value, _param) when is_integer(value), do: {:ok, value}

  defp parse_integer(value, param) when is_binary(value) do
    case Integer.parse(value) do
      {parsed_value, ""} ->
        {:ok, parsed_value}

      _ ->
        {:error, {param, "must be an integer"}}
    end
  end

  defp parse_integer(_value, param), do: {:error, {param, "must be an integer"}}
end
