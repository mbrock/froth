defmodule Froth.Telegram.ControlPrompt do
  @moduledoc false

  def reserve(cycles, cycle_id) when is_struct(cycles, MapSet) and is_binary(cycle_id) do
    if MapSet.member?(cycles, cycle_id) do
      {cycles, false}
    else
      {MapSet.put(cycles, cycle_id), true}
    end
  end

  def reserve(cycles, _cycle_id) when is_struct(cycles, MapSet), do: {cycles, false}

  def maybe_put(input, true, opts)
      when is_map(input) and is_list(opts) do
    case payload(opts) do
      nil -> input
      control_prompt -> Map.put(input, "control_prompt", control_prompt)
    end
  end

  def maybe_put(input, _send?, _opts), do: input

  def payload(opts) when is_list(opts) do
    cycle_id = opts[:cycle_id]
    chat_id = opts[:chat_id]
    session_id = opts[:session_id]

    if is_binary(cycle_id) and is_integer(chat_id) and is_binary(session_id) do
      reply_to = opts[:reply_to]

      %{
        "session_id" => session_id,
        "chat_id" => chat_id,
        "reply_to" => reply_to,
        "reply_markup" => %{
          "@type" => "replyMarkupInlineKeyboard",
          "rows" => [buttons(opts)]
        }
      }
      |> maybe_put_content(opts)
    end
  end

  def payload(_opts), do: nil

  def buttons(opts) when is_list(opts) do
    cycle_id = opts[:cycle_id]
    bot_id = opts[:bot_id]
    bot_username = opts[:bot_username]
    stop_data = Base.encode64("stopcycle:#{cycle_id}")

    open_button =
      case {bot_id, bot_username} do
        {bot_id, bot_username}
        when is_binary(bot_id) and bot_id != "" and is_binary(bot_username) and bot_username != "" ->
          [
            %{
              "@type" => "inlineKeyboardButton",
              "text" => "Open",
              "type" => %{
                "@type" => "inlineKeyboardButtonTypeUrl",
                "url" => "https://t.me/#{bot_username}/tool?startapp=cycle_#{bot_id}_#{cycle_id}"
              }
            }
          ]

        _ ->
          []
      end

    open_button ++
      [
        %{
          "@type" => "inlineKeyboardButton",
          "text" => "Stop",
          "type" => %{
            "@type" => "inlineKeyboardButtonTypeCallback",
            "data" => stop_data
          }
        }
      ]
  end

  def adhoc_markdown(model, provider, prompt) do
    model = display_value(model, "unknown model")
    provider = display_value(provider, "unknown provider")
    prompt = display_value(prompt, "(empty prompt)")

    Enum.join(
      [
        "*Running* #{markdown_escape(model)} \\(#{markdown_escape(provider)}\\)",
        "",
        "*Prompt*",
        markdown_escape(prompt)
      ],
      "\n"
    )
  end

  def markdown_escape(text) when is_binary(text) do
    text
    |> String.graphemes()
    |> Enum.map_join(&escape_markdown_grapheme/1)
  end

  defp maybe_put_content(payload, opts) when is_map(payload) and is_list(opts) do
    cond do
      is_binary(opts[:markdown]) and opts[:markdown] != "" ->
        Map.put(payload, "markdown", opts[:markdown])

      is_binary(opts[:text]) and opts[:text] != "" ->
        Map.put(payload, "text", opts[:text])

      true ->
        payload
    end
  end

  defp display_value(value, fallback) when is_binary(value) do
    if value == "", do: fallback, else: value
  end

  defp display_value(_value, fallback), do: fallback

  defp escape_markdown_grapheme("\\"), do: "\\\\"
  defp escape_markdown_grapheme("_"), do: "\\_"
  defp escape_markdown_grapheme("*"), do: "\\*"
  defp escape_markdown_grapheme("["), do: "\\["
  defp escape_markdown_grapheme("]"), do: "\\]"
  defp escape_markdown_grapheme("("), do: "\\("
  defp escape_markdown_grapheme(")"), do: "\\)"
  defp escape_markdown_grapheme("~"), do: "\\~"
  defp escape_markdown_grapheme("`"), do: "\\`"
  defp escape_markdown_grapheme(">"), do: "\\>"
  defp escape_markdown_grapheme("#"), do: "\\#"
  defp escape_markdown_grapheme("+"), do: "\\+"
  defp escape_markdown_grapheme("-"), do: "\\-"
  defp escape_markdown_grapheme("="), do: "\\="
  defp escape_markdown_grapheme("|"), do: "\\|"
  defp escape_markdown_grapheme("{"), do: "\\{"
  defp escape_markdown_grapheme("}"), do: "\\}"
  defp escape_markdown_grapheme("."), do: "\\."
  defp escape_markdown_grapheme("!"), do: "\\!"
  defp escape_markdown_grapheme(grapheme), do: grapheme
end
