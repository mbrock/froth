defmodule Froth.AnthropicCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Froth.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Froth.Repo, {:shared, self()})

    Froth.Repo.insert!(%Froth.ApiKey{
      name: "test-anthropic",
      provider: "anthropic",
      key: "test-key-not-real"
    })

    on_exit(fn ->
      Application.delete_env(:froth, :sse_stream_fun)
      Application.delete_env(:froth, :llm_stream_fun)
      Application.delete_env(:froth, :llm_stream_single_fun)
      Application.delete_env(:froth, :post_json_fun)
    end)

    :ok
  end
end
