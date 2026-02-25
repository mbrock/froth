defmodule FrothWeb.MiniDebugController do
  use FrothWeb, :controller
  require Logger

  def create(conn, %{"logs" => logs}) when is_list(logs) do
    for entry <- logs do
      level = entry["level"] || "log"
      msg = entry["msg"] || ""
      Logger.warning("[MINIAPP:#{level}] #{msg}")
    end

    json(conn, %{ok: true})
  end

  def create(conn, params) do
    Logger.warning("[MINIAPP] #{inspect(params, pretty: true, limit: :infinity)}")
    json(conn, %{ok: true})
  end
end
