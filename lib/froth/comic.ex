defmodule Froth.Comic do
  @moduledoc """
  Generates Comic Chat-inspired strips from chat messages.

  Messages accept atom or string keys and require `sender` and `text`.
  `timestamp`, `emotion`, and `balloon` are optional.

      messages = [
        %{sender: "Ada", text: "Hello! :)"},
        %{sender: "Lin", text: "THIS IS GREAT!!!", emotion: :happy}
      ]

      {:ok, png} = Froth.Comic.render(messages)

  `render/2` returns an in-memory PNG binary. `layout/2` exposes the complete
  panel geometry for callers that want to inspect or customize composition.
  """

  alias Froth.Comic.{Layout, Renderer}

  @spec render([map()], keyword()) :: {:ok, binary()} | {:error, term()}
  def render(messages, opts \\ []) do
    with {:ok, layout} <- layout(messages, opts) do
      Renderer.png(layout, opts)
    end
  end

  @spec render_svg([map()], keyword()) :: {:ok, binary()} | {:error, term()}
  def render_svg(messages, opts \\ []) do
    with {:ok, layout} <- layout(messages, opts) do
      Renderer.svg(layout, opts)
    end
  end

  @spec layout([map()], keyword()) :: {:ok, map()} | {:error, String.t()}
  defdelegate layout(messages, opts \\ []), to: Layout
end
