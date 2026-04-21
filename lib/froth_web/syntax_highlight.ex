defmodule FrothWeb.SyntaxHighlight do
  @moduledoc false

  @css_class "froth-highlight"
  @mobile_line_length String.length(~s|for f <- ["phoenix.ex", "ecto.ex", "logs.ex", "|)
  @stylesheet """
  .#{@css_class},
  .#{@css_class} .hll,
  pre.#{@css_class},
  pre.#{@css_class} code {
    background: transparent !important;
  }

  pre.#{@css_class} {
    margin: 0;
    overflow-x: auto;
    padding: 0;
    font-family: var(--font-mono);
    font-size: 12px;
    line-height: 1.6667;
    tab-size: 2;
    color: var(--color-fg-dim);
  }

  pre.#{@css_class} code {
    padding: 0;
    font-family: inherit;
    font-size: inherit;
    line-height: inherit;
  }

  .#{@css_class} .w {
    color: inherit;
  }

  .#{@css_class} .c,
  .#{@css_class} .c1,
  .#{@css_class} .ch,
  .#{@css_class} .cm,
  .#{@css_class} .cp,
  .#{@css_class} .cpf,
  .#{@css_class} .cs {
    color: var(--color-fg-mute);
    font-style: italic;
  }

  .#{@css_class} .err,
  .#{@css_class} .gr,
  .#{@css_class} .gt {
    color: var(--color-red);
  }

  .#{@css_class} .k,
  .#{@css_class} .kc,
  .#{@css_class} .kd,
  .#{@css_class} .kn,
  .#{@css_class} .kp,
  .#{@css_class} .kr,
  .#{@css_class} .kt,
  .#{@css_class} .o,
  .#{@css_class} .ow {
    color: var(--color-amber);
  }

  .#{@css_class} .bp,
  .#{@css_class} .fm,
  .#{@css_class} .na,
  .#{@css_class} .nb,
  .#{@css_class} .nc,
  .#{@css_class} .nd,
  .#{@css_class} .nf,
  .#{@css_class} .nl,
  .#{@css_class} .nn,
  .#{@css_class} .nt {
    color: var(--color-cyan);
  }

  .#{@css_class} .n,
  .#{@css_class} .py,
  .#{@css_class} .nv,
  .#{@css_class} .nx {
    color: var(--color-fg);
  }

  .#{@css_class} .no,
  .#{@css_class} .ni {
    color: var(--color-violet);
  }

  .#{@css_class} .dl,
  .#{@css_class} .s,
  .#{@css_class} .s1,
  .#{@css_class} .s2,
  .#{@css_class} .sb,
  .#{@css_class} .sc,
  .#{@css_class} .sd,
  .#{@css_class} .se,
  .#{@css_class} .sh,
  .#{@css_class} .si,
  .#{@css_class} .sx,
  .#{@css_class} .sr,
  .#{@css_class} .ss {
    color: var(--color-green);
  }

  .#{@css_class} .m,
  .#{@css_class} .mb,
  .#{@css_class} .mf,
  .#{@css_class} .mh,
  .#{@css_class} .mi,
  .#{@css_class} .il,
  .#{@css_class} .mo {
    color: var(--color-peach);
  }

  .#{@css_class} .p {
    color: var(--color-fg-ghost);
  }
  """

  def stylesheet, do: @stylesheet

  def elixir_htmls(source) when is_binary(source) do
    source = String.trim_trailing(source)

    %{
      desktop_html: highlight(source),
      mobile_html: source |> format_for_mobile() |> highlight()
    }
  end

  def elixir_htmls(_), do: %{desktop_html: "", mobile_html: ""}

  def elixir_html(source) when is_binary(source) do
    source
    |> String.trim_trailing()
    |> highlight()
  end

  def elixir_html(_), do: ""

  defp format_for_mobile(source) when is_binary(source) do
    try do
      source
      |> Code.format_string!(line_length: @mobile_line_length)
      |> IO.iodata_to_binary()
      |> String.trim_trailing()
    rescue
      _ -> source
    end
  end

  defp highlight(source) when is_binary(source) do
    Makeup.highlight(
      source,
      lexer: Makeup.Lexers.ElixirLexer,
      formatter_options: [css_class: @css_class]
    )
  end
end
