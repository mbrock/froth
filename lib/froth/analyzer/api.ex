defmodule Froth.Analyzer.API do
  @moduledoc "HTTP clients for Gemini and Grok APIs."

  @gemini_url "https://generativelanguage.googleapis.com/v1beta/models"
  @xai_url "https://api.x.ai/v1/chat/completions"
  @xai_responses_url "https://api.x.ai/v1/responses"

  def gemini(model \\ "gemini-3-flash-preview", contents, opts \\ []) do
    api_key = System.get_env("GOOGLE_API_KEY")
    url = "#{@gemini_url}/#{model}:generateContent?key=#{api_key}"

    body = %{"contents" => contents}

    body =
      if opts[:system],
        do: Map.put(body, "systemInstruction", %{"parts" => [%{"text" => opts[:system]}]}),
        else: body

    case post_json(url, body) do
      {:ok, %{"candidates" => [%{"content" => %{"parts" => parts}} | _]}} ->
        text = parts |> Enum.map_join("", & &1["text"])
        {:ok, text}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, _} = err ->
        err
    end
  end

  def gemini_with_file(model \\ "gemini-3-flash-preview", file_uri, mime_type, prompt) do
    contents = [
      %{
        "parts" => [
          %{"text" => prompt},
          %{"fileData" => %{"fileUri" => file_uri, "mimeType" => mime_type}}
        ]
      }
    ]

    gemini(model, contents)
  end

  def gemini_with_inline(model \\ "gemini-3-flash-preview", data, mime_type, prompt) do
    b64 = Base.encode64(data)

    contents = [
      %{
        "parts" => [
          %{"text" => prompt},
          %{"inlineData" => %{"mimeType" => mime_type, "data" => b64}}
        ]
      }
    ]

    gemini(model, contents)
  end

  def grok(prompt, opts \\ []) do
    api_key = System.get_env("XAI_API_KEY")
    model = opts[:model] || "grok-4-1-fast-non-reasoning"

    body = %{
      "model" => model,
      "messages" => [%{"role" => "user", "content" => prompt}]
    }

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    case post_json(@xai_url, body, headers) do
      {:ok, %{"choices" => [%{"message" => %{"content" => text}} | _]}} ->
        {:ok, text}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, _} = err ->
        err
    end
  end


  def grok_search(prompt, opts \\ []) do
    api_key = System.get_env("XAI_API_KEY")
    model = opts[:model] || "grok-4-1-fast-reasoning"

    body = %{
      "model" => model,
      "input" => [%{"role" => "user", "content" => prompt}],
      "tools" => [%{"type" => "x_search"}]
    }

    body = if opts[:max_tokens],
      do: Map.put(body, "max_output_tokens", opts[:max_tokens]),
      else: body

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    case post_json(@xai_responses_url, body, headers) do
      {:ok, %{"output" => output}} ->
        text = output
          |> Enum.filter(&(&1["type"] == "message"))
          |> Enum.flat_map(& &1["content"])
          |> Enum.filter(&(&1["type"] == "output_text"))
          |> Enum.map(& &1["text"])
          |> Enum.join("\n\n")
        {:ok, text}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, _} = err ->
        err
    end
  end

  def claude(messages, opts \\ []) do
    api_key = anthropic_api_key()
    model = opts[:model] || "claude-sonnet-4-6"

    body = %{
      "model" => model,
      "max_tokens" => opts[:max_tokens] || 4096,
      "messages" => messages
    }

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    case post_json("https://api.anthropic.com/v1/messages", body, headers) do
      {:ok, %{"content" => content}} ->
        text =
          content
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("", & &1["text"])

        {:ok, text}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, _} = err ->
        err
    end
  end

  defp anthropic_api_key do
    Froth.Anthropic.active_api_key() ||
      Application.get_env(:froth, Froth.Anthropic, []) |> Keyword.get(:api_key) ||
      System.get_env("ANTHROPIC_API_KEY")
  end

  defp post_json(url, body, extra_headers \\ []) do
    headers =
      if extra_headers == [],
        do: [{"content-type", "application/json"}],
        else: extra_headers

    req = Finch.build(:post, url, headers, Jason.encode!(body))

    case Finch.request(req, Froth.Finch, receive_timeout: 120_000) do
      {:ok, %Finch.Response{status: 200, body: resp}} ->
        Jason.decode(resp)

      {:ok, %Finch.Response{status: status, body: resp}} ->
        {:error, {:http_error, status, resp}}

      {:error, err} ->
        {:error, err}
    end
  end
end
