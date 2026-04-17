defmodule Froth.Context.MarkupTest do
  use ExUnit.Case, async: true

  alias Froth.Context.Markup

  test "render_prompt_markup drops heex debug comments and phx attrs" do
    html =
      Phoenix.HTML.raw("""
      <!-- <Froth.Context.BlockHTML.live> lib/froth/context/block_html.ex:34 (froth) -->
      <shell data-phx-loc="48" phx-update="ignore" task_id="shell:abc">
        hello
      </shell>
      """)
      |> Markup.render_prompt_markup()

    refute html =~ "<!--"
    refute html =~ "data-phx-loc"
    refute html =~ "phx-update"
    assert html =~ ~s(<shell task_id="shell:abc">)
    assert html =~ "hello"
  end

  test "render_markup keeps html-like structure while removing comments and phx attrs" do
    html =
      Phoenix.HTML.raw("""
      <!-- transient -->
      <msg data-phx-loc="12">
        <cycle phx-hook="x">ok</cycle>
      </msg>
      """)
      |> Markup.render_markup(true)

    refute html =~ "<!--"
    refute html =~ "data-phx-loc"
    refute html =~ "phx-hook"
    assert html =~ "<msg>"
    assert html =~ "<cycle>"
    assert html =~ "ok"
  end
end
