defmodule FrothWeb.MiniDebugController do
  use FrothWeb, :controller

  alias Froth.Telemetry.Span

  def create(conn, %{"logs" => logs}) when is_list(logs) do
    for entry <- logs do
      level = entry["level"] || "log"
      msg = entry["msg"] || ""
      Span.execute([:froth, :web, :miniapp_log], nil, %{level: level, msg: msg})
    end

    json(conn, %{ok: true})
  end

  def create(conn, params) do
    Span.execute([:froth, :web, :miniapp_params], nil, %{
      params: inspect(params, pretty: true, limit: :infinity)
    })

    json(conn, %{ok: true})
  end
end
