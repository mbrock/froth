defmodule Froth.Replicate do
  @moduledoc """
  Replicate API client. Designed to be called from eval tasks — IO output
  is captured by the eval's group leader and streams into task_events.

  Usage:

      {:ok, p} = Froth.Replicate.start("a white cube")
      {:ok, p} = Froth.Replicate.await(p.id)
      url = hd(p.output["urls"])
      Froth.Telegram.send_photo("charlie", chat_id, url)

      # Or with options:
      {:ok, p} = Froth.Replicate.start("a cat", model: "black-forest-labs/flux-schnell", aspect_ratio: "16:9")
      {:ok, p} = Froth.Replicate.await(p.id)

      # List models in a collection:
      {:ok, models} = Froth.Replicate.list_models("text-to-image")

      # Get model schema:
      {:ok, schema} = Froth.Replicate.model_schema("black-forest-labs/flux-schnell")
  """

  require Logger

  alias Froth.Repo
  alias Froth.Replicate.Prediction

  import Ecto.Query

  @api_base "https://api.replicate.com/v1"
  @default_model "black-forest-labs/flux-schnell"
  @poll_interval_ms 2_000

  defp api_token do
    Application.get_env(:froth, __MODULE__, [])
    |> Keyword.get(:api_token)
    |> case do
      nil -> raise "REPLICATE_API_TOKEN not configured"
      key -> key
    end
  end

  @doc false
  def headers do
    [
      {"authorization", "Bearer #{api_token()}"},
      {"content-type", "application/json"}
    ]
  end

  # --- Public API ---

  @doc """
  Start a prediction. Submits to the Replicate API and saves a DB row.
  Returns `{:ok, %Prediction{}}` immediately.

  Options:
    - `:model` - Replicate model (default: flux-schnell)
    - All other keys passed as model input (e.g. `aspect_ratio: "16:9"`)
  """
  def start(prompt, opts \\ []) do
    {model, opts} = Keyword.pop(opts, :model, @default_model)
    input = Keyword.merge([prompt: prompt], opts) |> Map.new()

    IO.puts("Starting prediction with #{model}...")

    case create_prediction(model, input) do
      {:ok, %{"id" => replicate_id, "status" => status} = resp} ->
        attrs = %{
          model: model,
          prompt: prompt,
          input: input,
          status: status,
          replicate_id: replicate_id,
          output: normalize_output(resp["output"]),
          error: resp["error"],
          logs: resp["logs"],
          metrics: resp["metrics"]
        }

        attrs =
          if status == "succeeded" do
            Map.put(attrs, :completed_at, DateTime.utc_now() |> DateTime.truncate(:second))
          else
            attrs
          end

        {:ok, prediction} = %Prediction{} |> Prediction.changeset(attrs) |> Repo.insert()
        IO.puts("Prediction #{prediction.id} (#{replicate_id}): #{status}")
        {:ok, prediction}

      {:error, reason} ->
        IO.puts("Failed to start prediction: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Wait for a prediction to complete. Polls the Replicate API and prints
  logs as they arrive via IO.puts (captured by the eval task's group leader).

  Returns `{:ok, %Prediction{}}` or `{:error, reason}`.
  Default timeout is 5 minutes.
  """
  def await(id, timeout \\ 300_000) do
    prediction = Repo.get!(Prediction, id)

    if prediction.status == "succeeded" do
      {:ok, prediction}
    else
      deadline = System.monotonic_time(:millisecond) + timeout
      poll_loop(prediction, deadline, "")
    end
  end

  defp poll_loop(prediction, deadline, prev_logs) do
    if System.monotonic_time(:millisecond) > deadline do
      IO.puts("Timed out waiting for prediction #{prediction.id}")
      {:error, :timeout}
    else
      case poll_prediction(prediction.replicate_id) do
        {:ok, %{"status" => "succeeded", "output" => output} = resp} ->
          print_new_logs(resp["logs"], prev_logs)
          IO.puts("Prediction #{prediction.id} succeeded.")

          prediction =
            prediction
            |> Prediction.changeset(%{
              status: "succeeded",
              output: normalize_output(output),
              metrics: resp["metrics"],
              logs: resp["logs"],
              completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })
            |> Repo.update!()

          {:ok, prediction}

        {:ok, %{"status" => "failed", "error" => err} = resp} ->
          print_new_logs(resp["logs"], prev_logs)
          IO.puts("Prediction #{prediction.id} failed: #{err}")

          prediction
          |> Prediction.changeset(%{status: "failed", error: err, logs: resp["logs"]})
          |> Repo.update!()

          {:error, err}

        {:ok, %{"status" => "canceled"} = resp} ->
          print_new_logs(resp["logs"], prev_logs)
          IO.puts("Prediction #{prediction.id} canceled.")

          prediction
          |> Prediction.changeset(%{status: "failed", error: "canceled", logs: resp["logs"]})
          |> Repo.update!()

          {:error, "canceled"}

        {:ok, %{"status" => status} = resp} ->
          new_logs = resp["logs"] || ""
          print_new_logs(new_logs, prev_logs)

          prediction
          |> Prediction.changeset(%{status: status})
          |> Repo.update!()

          Process.sleep(@poll_interval_ms)
          poll_loop(prediction, deadline, new_logs)

        {:error, reason} ->
          IO.puts("Poll error: #{inspect(reason)}, retrying...")
          Process.sleep(@poll_interval_ms)
          poll_loop(prediction, deadline, prev_logs)
      end
    end
  end

  defp print_new_logs(nil, _prev), do: :ok

  defp print_new_logs(logs, prev) when is_binary(logs) and is_binary(prev) do
    if String.length(logs) > String.length(prev) do
      new_part = String.slice(logs, String.length(prev)..-1//1)
      trimmed = String.trim(new_part)
      if trimmed != "", do: IO.puts(trimmed)
    end
  end

  @doc """
  Get a prediction by local DB id.
  """
  def get(id), do: Repo.get(Prediction, id)

  @doc """
  List recent predictions from the local DB.

  Options:
    - `:limit` - max results (default 20)
    - `:status` - filter by status (e.g. "succeeded", "failed")
  """
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    status = Keyword.get(opts, :status)

    q = Prediction |> order_by(desc: :id) |> limit(^limit)
    q = if status, do: where(q, [p], p.status == ^status), else: q
    Repo.all(q)
  end

  @doc """
  List models in a Replicate collection.
  Collections: "text-to-image", "text-to-video", "image-to-video", etc.
  """
  def list_models(collection \\ "text-to-image") do
    url = "#{@api_base}/collections/#{collection}"
    req = Finch.build(:get, url, headers())

    case Finch.request(req, Froth.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        %{"models" => models} = Jason.decode!(body)

        models =
          Enum.map(models, fn m ->
            %{
              id: "#{m["owner"]}/#{m["name"]}",
              description: m["description"],
              run_count: m["run_count"]
            }
          end)

        {:ok, models}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, err} ->
        {:error, {:request_failed, err}}
    end
  end

  @doc "Get the input schema for a model."
  def model_schema(model) do
    url = "#{@api_base}/models/#{model}"
    req = Finch.build(:get, url, headers())

    case Finch.request(req, Froth.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        data = Jason.decode!(body)
        schema = get_in(data, ["latest_version", "openapi_schema"])
        input_props = get_in(schema, ["components", "schemas", "Input", "properties"]) || %{}

        fields =
          Enum.map(input_props, fn {name, spec} ->
            %{
              name: name,
              type: spec["type"] || "enum",
              default: spec["default"],
              description: spec["description"]
            }
          end)

        {:ok, fields}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, err} ->
        {:error, {:request_failed, err}}
    end
  end

  @doc """
  Get the latest version hash for a model.

      {:ok, "5c7d5dc6..."} = Froth.Replicate.get_latest_version("openai/whisper")
  """
  def get_latest_version(model) do
    url = "#{@api_base}/models/#{model}"
    req = Finch.build(:get, url, headers())

    case Finch.request(req, Froth.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode!(body) do
          %{"latest_version" => %{"id" => version}} -> {:ok, version}
          _ -> {:error, :no_version}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, err} ->
        {:error, {:request_failed, err}}
    end
  end

  # --- HTTP helpers ---

  @doc false
  def create_prediction(model, input) do
    url = "#{@api_base}/models/#{model}/predictions"
    body = Jason.encode!(%{input: input})
    req = Finch.build(:post, url, headers(), body)

    case Finch.request(req, Froth.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: status, body: resp}} when status in [200, 201] ->
        {:ok, Jason.decode!(resp)}

      {:ok, %Finch.Response{status: 404, body: _}} ->
        create_prediction_with_version(model, input)

      {:ok, %Finch.Response{status: status, body: resp}} ->
        {:error, {:http_error, status, resp}}

      {:error, err} ->
        {:error, {:request_failed, err}}
    end
  end

  defp create_prediction_with_version(model, input) do
    case get_latest_version(model) do
      {:ok, version} ->
        Logger.info(
          event: :replicate_using_version,
          model: model,
          version: String.slice(version, 0, 12)
        )

        url = "#{@api_base}/predictions"
        body = Jason.encode!(%{version: version, input: input})
        req = Finch.build(:post, url, headers(), body)

        case Finch.request(req, Froth.Finch, receive_timeout: 30_000) do
          {:ok, %Finch.Response{status: status, body: resp}} when status in [200, 201] ->
            {:ok, Jason.decode!(resp)}

          {:ok, %Finch.Response{status: status, body: resp}} ->
            {:error, {:http_error, status, resp}}

          {:error, err} ->
            {:error, {:request_failed, err}}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc false
  def poll_prediction(replicate_id) do
    url = "#{@api_base}/predictions/#{replicate_id}"
    req = Finch.build(:get, url, headers())

    case Finch.request(req, Froth.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: resp}} ->
        {:ok, Jason.decode!(resp)}

      {:ok, %Finch.Response{status: status, body: resp}} ->
        {:error, {:http_error, status, resp}}

      {:error, err} ->
        {:error, {:request_failed, err}}
    end
  end

  defp normalize_output(nil), do: nil
  defp normalize_output([url | _] = urls) when is_binary(url), do: %{"urls" => urls}
  defp normalize_output(url) when is_binary(url), do: %{"urls" => [url]}
  defp normalize_output(%{} = map), do: map
  defp normalize_output(other), do: %{"raw" => other}
end
