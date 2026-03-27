defmodule FrothWeb.PodcastsHTML do
  use FrothWeb, :html

  embed_templates "podcasts_html/*"

  def card_bg(index) do
    case rem(index, 4) do
      0 -> "bg-[#1a1a17] text-[#d4cfc0] border-[#3a3630]"
      1 -> "bg-[#17191a] text-[#c0ccd4] border-[#303638]"
      2 -> "bg-[#1a1917] text-[#cfd4c0] border-[#363a30]"
      _ -> "bg-[#191a17] text-[#c4d0c0] border-[#343830]"
    end
  end

  def format_date(dt) do
    Calendar.strftime(dt, "%b %d, %Y · %H:%M UTC")
  end

  def speakers(script) when is_list(script) do
    script
    |> Enum.map(& &1["speaker"])
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  def speakers(_), do: ""

  def manuscript_lines(script) when is_list(script) do
    Enum.map(script, fn seg ->
      speaker = seg["speaker"] || "?"
      text = seg["text"] || ""
      {speaker, text}
    end)
  end

  def manuscript_lines(_), do: []
end
