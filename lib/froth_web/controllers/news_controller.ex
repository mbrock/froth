defmodule FrothWeb.NewsController do
  use FrothWeb, :controller

  @stream_timeout_ms 75_000
  @stream_message :regional_news_stream

  def show(conn, _params) do
    ip = get_client_ip(conn)

    case Froth.RegionalNews.open_stream(ip) do
      {:ok, stream} ->
        conn =
          conn
          |> put_resp_content_type("text/plain")
          |> put_resp_header("cache-control", "no-store")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)

        try do
          case stream_response(conn, stream) do
            {:ok, conn} -> conn
            {:error, conn} -> conn
          end
        after
          Froth.RegionalNews.detach(stream.cache_key)
        end

      {:error, reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "Error: #{reason}")
    end
  end

  defp get_client_ip(conn) do
    # Check forwarded headers (Cloudflare, nginx, etc.)
    cf_ip = get_req_header(conn, "cf-connecting-ip") |> List.first()
    xff = get_req_header(conn, "x-forwarded-for") |> List.first()
    xri = get_req_header(conn, "x-real-ip") |> List.first()

    cond do
      cf_ip && cf_ip != "" -> cf_ip
      xff && xff != "" -> xff |> String.split(",") |> List.first() |> String.trim()
      xri && xri != "" -> xri
      true -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp stream_response(conn, stream) do
    with {:ok, conn} <- maybe_chunk(conn, stream.header),
         {:ok, conn} <- chunk_existing(conn, stream.chunks) do
      if stream.done? do
        {:ok, conn}
      else
        stream_updates(conn, stream.cache_key)
      end
    end
  end

  defp chunk_existing(conn, chunks) do
    Enum.reduce_while(chunks, {:ok, conn}, fn chunk, {:ok, conn} ->
      case maybe_chunk(conn, chunk) do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, conn} -> {:halt, {:error, conn}}
      end
    end)
  end

  defp stream_updates(conn, cache_key) do
    receive do
      {@stream_message, ^cache_key, {:chunk, chunk}} ->
        case maybe_chunk(conn, chunk) do
          {:ok, conn} -> stream_updates(conn, cache_key)
          {:error, conn} -> {:error, conn}
        end

      {@stream_message, ^cache_key, :done} ->
        {:ok, conn}

      {@stream_message, ^cache_key, {:error, reason}} ->
        maybe_chunk(conn, "\n\nError: #{reason}\n")
    after
      @stream_timeout_ms ->
        maybe_chunk(conn, "\n\nError: timed out waiting for regional news.\n")
    end
  end

  defp maybe_chunk(conn, ""), do: {:ok, conn}

  defp maybe_chunk(conn, chunk) do
    case Plug.Conn.chunk(conn, chunk) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, conn}
    end
  end
end
