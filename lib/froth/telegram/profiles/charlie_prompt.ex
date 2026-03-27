defmodule Froth.Telegram.Profiles.CharliePrompt do
  @moduledoc """
  Prompt builder for the Charlie bot profile.

  Reads the system prompt from `priv/charlie-prompt.md` at runtime
  so edits take effect without recompilation.
  """

  @prompt_path "priv/charlie-prompt.md"

  def system_prompt(_chat_id, _config) do
    Application.app_dir(:froth, @prompt_path)
    |> File.read!()
  end
end
