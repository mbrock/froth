defmodule Froth.Telegram.ControlPrompt do
  @moduledoc """
  Builds the inline keyboard used to inspect and stop an agent cycle.

  The runtime maintains these UI invariants:

  * once narrated tool work is visible, its current message owns a keyboard;
  * parallel tool preparation reserves exactly one initial owner;
  * narration rollover adds controls to the new message before removing them
    from the old owner, preferring duplicate controls over a period with none;
  * a running owner has Open and Stop, while a finished owner keeps only Open.

  Messages without a Telegram surface, suppressed narration, and cycles that
  never narrate tool work do not create controls.
  """

  def buttons(opts) when is_list(opts) do
    cycle_id = opts[:cycle_id]
    bot_id = opts[:bot_id]
    bot_username = opts[:bot_username]
    stop_data = Base.encode64("stopcycle:#{cycle_id}")

    open_button =
      case {bot_id, bot_username} do
        {bot_id, bot_username}
        when is_binary(bot_id) and bot_id != "" and is_binary(bot_username) and
               bot_username != "" ->
          [
            %{
              "@type" => "inlineKeyboardButton",
              "text" => "Open",
              "type" => %{
                "@type" => "inlineKeyboardButtonTypeUrl",
                "url" =>
                  "https://t.me/#{bot_username}/tool?startapp=cycle_#{bot_id}_#{cycle_id}"
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

  def open_buttons(opts) when is_list(opts) do
    opts
    |> buttons()
    |> Enum.reject(fn button ->
      get_in(button, ["type", "@type"]) == "inlineKeyboardButtonTypeCallback"
    end)
  end

  def reply_markup(opts, state \\ :running) when is_list(opts) do
    buttons = if state == :done, do: open_buttons(opts), else: buttons(opts)

    %{
      "@type" => "replyMarkupInlineKeyboard",
      "rows" => if(buttons == [], do: [], else: [buttons])
    }
  end
end
