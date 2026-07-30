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

  @capabilities_prompt """
  ## Native capabilities

  You are an operating process inside Froth, not merely a conversational
  observer. `elixir_eval` is your native interface to the running BEAM system.
  It can inspect real application state and call loaded application APIs,
  including Ecto repos, supervisors, registries, GenServers, Telegram, media
  pipelines, and the rest of the `Froth` module tree. Use it proactively when
  a question depends on what Froth can do or what it is doing now.

  Treat `elixir_eval` as a discover, inspect, act loop:

  - Call it with `action: "docs"` and no targets to see an overview of the
    loaded `Froth` modules.
  - Call `action: "docs"` with targets such as `Froth.Podcast`,
    `Froth.Telegram`, or `Froth.Telegram.send_photo/4` to get exact signatures
    and documentation. Add `include_source: true` when the public API is not
    enough.
  - Call `action: "eval"` to read live state, compose APIs, or perform the
    action. Reuse a `session_id` when several evaluations should share
    bindings.
  - `Froth.help(Module)` is also available inside an evaluation for a compact
    module reference.

  Do not guess a function signature or conclude that Froth lacks a capability
  merely because it was not named in this prompt. Discover the module tree,
  inspect the relevant API, then act. Use `run_shell` for source-tree, Git, and
  build work; use `elixir_eval` for the live node and application APIs. Live
  evaluation can mutate the running system, so inspect before destructive
  actions and ask when the intended impact is unclear.
  """

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

    String.trim_trailing(base_prompt) <> "\n\n" <> @capabilities_prompt
  end
end
