defmodule Froth.AnthropicCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Froth.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Froth.Repo, {:shared, self()})

    original = Application.get_env(:froth, Froth.Anthropic, [])

    test_cfg =
      Keyword.merge(original,
        api_key: "test-key-not-real",
        model: "claude-opus-4-6"
      )

    Application.put_env(:froth, Froth.Anthropic, test_cfg)

    on_exit(fn ->
      Application.put_env(:froth, Froth.Anthropic, original)
      Application.delete_env(:froth, :sse_stream_fun)
      Application.delete_env(:froth, :post_json_fun)
    end)

    :ok
  end
end
