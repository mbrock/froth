defmodule FrothWeb.SyntaxHighlightTest do
  use ExUnit.Case, async: true

  alias FrothWeb.SyntaxHighlight

  test "formats a narrower mobile variant for long valid elixir input" do
    source = ~s|for f <- ["phoenix.ex", "ecto.ex", "logs.ex", "eval.ex"] do\n  f\nend|

    htmls = SyntaxHighlight.elixir_htmls(source)

    assert is_binary(htmls.desktop_html)
    assert is_binary(htmls.mobile_html)
    refute htmls.desktop_html == htmls.mobile_html
    assert htmls.mobile_html =~ "phoenix.ex"
    assert htmls.mobile_html =~ "eval.ex"
  end

  test "falls back to the original code when mobile formatting cannot parse it" do
    source = ~s|for f <- ["phoenix.ex", "ecto.ex", "logs.ex", "|

    htmls = SyntaxHighlight.elixir_htmls(source)

    assert normalize_group_ids(htmls.desktop_html) == normalize_group_ids(htmls.mobile_html)
  end

  defp normalize_group_ids(html) do
    Regex.replace(~r/data-group-id="[^"]+"/, html, ~s(data-group-id="group"))
  end
end
