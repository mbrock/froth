defmodule FrothWeb.HeadlinesHTML do
  use FrothWeb, :html

  embed_templates "headlines_html/*"

  def brutalist_day_card_class(index) when rem(index, 3) == 0,
    do: "bg-[var(--headline-brutalist-paper)] text-black"

  def brutalist_day_card_class(index) when rem(index, 3) == 1,
    do: "bg-[var(--headline-brutalist-acid)] text-black"

  def brutalist_day_card_class(_index),
    do: "bg-[var(--headline-brutalist-concrete)] text-black"
end
