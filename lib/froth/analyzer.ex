defmodule Froth.Analyzer do
  @valid_reactions ~w(👍 👎 ❤ 🔥 🥰 👏 😁 🤔 🤯 😱 🤬 😢 🎉 🤩 🤮 💩 🙏 👌 🕊 🤡 🥱 🥴 😍 🐳 ❤️‍🔥 🌚 🌭 💯 🤣 ⚡ 🍌 🏆 💔 🤨 😐 🍓 🍾 💋 🖕 😈 😴 😭 🤓 👻 👨‍💻 👀 🎃 🙈 😇 😨 🤝 ✍ 🤗 🫡 🎅 🎄 ☃ 💅 🤪 🗿 🆒 💘 🙉 🦄 😘 💊 🙊 😎 👾 🤷‍♂️ 🤷 🤷‍♀️ 😡)

  def valid_reactions, do: @valid_reactions

  @doc "TDLib session used for file downloads in analyzer workers."
  def tdlib_session do
    Application.get_env(:froth, __MODULE__, [])[:tdlib_session] ||
      raise "ANALYZER_TDLIB_SESSION not configured"
  end

  @doc """
  Wraps analyzer work with Telegram reactions.
  Adds 👀 before work starts, replaces with 👨‍💻 on success,
  removes reaction on discard, leaves 👀 on error (will retry).
  """
  def with_reactions(chat_id, message_id, fun) do
    set_reactions(chat_id, message_id, ["👀"])
    result = fun.()

    case result do
      :ok ->
        set_reactions(chat_id, message_id, ["👨‍💻"])

      {:discard, _} ->
        set_reactions(chat_id, message_id, [])

      _ ->
        :ok
    end

    result
  end

  defp set_reactions(chat_id, message_id, emojis) do
    Froth.Telegram.send("charlie", %{
      "@type" => "setMessageReactions",
      "chat_id" => chat_id,
      "message_id" => message_id,
      "reaction_types" => Enum.map(emojis, &%{"@type" => "reactionTypeEmoji", "emoji" => &1}),
      "is_big" => false
    })
  end
end
