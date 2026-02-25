defmodule Mix.Tasks.RecordFixtures do
  @moduledoc "Re-record SSE test fixtures from the live Anthropic API using the app's Finch client."
  use Mix.Task

  @api_url "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"
  @fixtures_dir "test/fixtures/sse"

  @shortdoc "Record SSE test fixtures from the Anthropic API"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    cfg = Application.get_env(:froth, Froth.Anthropic, [])
    api_key = Keyword.get(cfg, :api_key)
    model = Keyword.get(cfg, :model, "claude-opus-4-6")

    if is_nil(api_key) or api_key == "" do
      Mix.raise("ANTHROPIC_API_KEY not configured")
    end

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]

    # simple_reply
    record(headers, "simple_reply/turn_0.sse", %{
      "model" => model,
      "max_tokens" => 256,
      "stream" => true,
      "messages" => [
        %{"role" => "user", "content" => "What year was the transistor invented? One sentence."}
      ]
    })

    # tool_use_echo turn 0
    tool = %{
      "name" => "froth_echo",
      "description" => "Echo back text unchanged.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"],
        "additionalProperties" => false
      }
    }

    record(headers, "tool_use_echo/turn_0.sse", %{
      "model" => model,
      "max_tokens" => 256,
      "stream" => true,
      "messages" => [
        %{
          "role" => "user",
          "content" => "Use the froth_echo tool to echo back the text \"test message\"."
        }
      ],
      "tools" => [tool],
      "tool_choice" => %{"type" => "tool", "name" => "froth_echo"}
    })

    # Extract tool_use_id from turn_0 for turn_1
    turn_0_data = File.read!(Path.join(@fixtures_dir, "tool_use_echo/turn_0.sse"))

    tool_use_id =
      case Regex.run(~r/"id":"(toolu_[^"]+)"/, turn_0_data) do
        [_, id] -> id
        _ -> Mix.raise("Could not extract tool_use_id from tool_use_echo/turn_0.sse")
      end

    Mix.shell().info("  tool_use_id: #{tool_use_id}")

    # tool_use_echo turn 1
    record(headers, "tool_use_echo/turn_1.sse", %{
      "model" => model,
      "max_tokens" => 256,
      "stream" => true,
      "messages" => [
        %{
          "role" => "user",
          "content" => "Use the froth_echo tool to echo back the text \"test message\"."
        },
        %{
          "role" => "assistant",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => tool_use_id,
              "name" => "froth_echo",
              "input" => %{"text" => "test message"}
            }
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => tool_use_id, "content" => "test message"}
          ]
        }
      ],
      "tools" => [tool]
    })

    # thinking_reply
    record(headers, "thinking_reply/turn_0.sse", %{
      "model" => model,
      "max_tokens" => 4096,
      "stream" => true,
      "thinking" => %{"type" => "enabled", "budget_tokens" => 1024},
      "messages" => [%{"role" => "user", "content" => "What is 2+2? Think about it first."}]
    })

    Mix.shell().info("Done. All fixtures recorded with model=#{model}")
  end

  defp record(headers, fixture_path, body) do
    Mix.shell().info("Recording #{fixture_path} ...")
    full_path = Path.join(@fixtures_dir, fixture_path)
    File.mkdir_p!(Path.dirname(full_path))

    req = Finch.build(:post, @api_url, headers, Jason.encode!(body))

    {:ok, file} = File.open(full_path, [:write, :utf8])

    fun = fn
      {:status, _status}, acc ->
        {:cont, acc}

      {:headers, _headers}, acc ->
        {:cont, acc}

      {:data, chunk}, acc when is_binary(chunk) ->
        IO.write(file, chunk)
        {:cont, acc}
    end

    case Finch.stream_while(req, Froth.Finch, nil, fun, receive_timeout: 60_000) do
      {:ok, _} -> :ok
      {:error, err} -> Mix.raise("Failed to record #{fixture_path}: #{inspect(err)}")
    end

    File.close(file)
  end
end
