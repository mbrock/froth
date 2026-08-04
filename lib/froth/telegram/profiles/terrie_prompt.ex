defmodule Froth.Telegram.Profiles.TerriePrompt do
  @moduledoc """
  Prompt builder for the Terrie bot profile.

  Terrie shares the family chronicle and native Froth capabilities, but has an
  independent identity, model, Telegram session, and inference state.
  """

  alias Froth.Telegram.Profiles.CharliePrompt

  @prompt_paths [
    "priv/terrie-prompt.md",
    "priv/static/terrie-system-prompt.txt"
  ]

  def system_prompt(_chat_id, _config) do
    base_prompt =
      @prompt_paths
      |> Enum.find_value(fn path ->
        full_path = Application.app_dir(:froth, path)

        if File.exists?(full_path) do
          File.read!(full_path)
        end
      end)
      |> case do
        nil ->
          raise File.Error,
            reason: :enoent,
            action: "read file",
            path: hd(@prompt_paths)

        prompt ->
          prompt
      end

    String.trim_trailing(base_prompt) <>
      "\n\n" <> CharliePrompt.native_capabilities_prompt()
  end
end
