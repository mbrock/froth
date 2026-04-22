defmodule Froth.Telegram.Profiles.CharliePrompt do
  @moduledoc """
  Prompt builder for the Charlie bot profile.

  Reads the system prompt from the app's `priv/` assets at runtime so edits
  take effect without recompilation.
  """

  @prompt_paths [
    "priv/charlie-prompt.md",
    "priv/static/charlie-system-prompt.txt"
  ]

  def system_prompt(_chat_id, _config) do
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
  end
end
