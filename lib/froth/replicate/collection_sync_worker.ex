defmodule Froth.Replicate.CollectionSyncWorker do
  @moduledoc "Oban worker that syncs a single Replicate collection and its models."
  use Oban.Worker, queue: :replicate, max_attempts: 5

  alias Froth.Repo
  alias Froth.Telemetry.Span
  alias Froth.Replicate.{Collection, Model}

  @api_base "https://api.replicate.com/v1"

  @impl true
  def perform(%Oban.Job{args: %{"slug" => slug}}) do
    req = Finch.build(:get, "#{@api_base}/collections/#{slug}", Froth.Replicate.headers())

    case Finch.request(req, Froth.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        data = Jason.decode!(body)
        models = data["models"] || []

        %Collection{slug: slug}
        |> Collection.changeset(%{
          name: data["name"] || slug,
          description: data["description"],
          full_description: data["full_description"]
        })
        |> Repo.insert!(
          on_conflict: {:replace, [:name, :description, :full_description, :updated_at]},
          conflict_target: :slug
        )

        Enum.each(models, &upsert_model(&1, slug))

        Span.execute([:froth, :replicate, :collection_synced], nil, %{
          slug: slug,
          models: length(models)
        })

        :ok

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{String.slice(body, 0, 200)}"}

      {:error, err} ->
        {:error, inspect(err)}
    end
  end

  defp upsert_model(m, slug) do
    input_schema =
      get_in(m, [
        "latest_version",
        "openapi_schema",
        "components",
        "schemas",
        "Input",
        "properties"
      ])

    created_at =
      case m["created_at"] do
        s when is_binary(s) ->
          case DateTime.from_iso8601(s) do
            {:ok, dt, _} -> DateTime.truncate(dt, :second)
            _ -> nil
          end

        _ ->
          nil
      end

    %Model{owner: m["owner"], name: m["name"]}
    |> Model.changeset(%{
      description: m["description"],
      run_count: m["run_count"] || 0,
      visibility: m["visibility"] || "public",
      is_official: m["is_official"] || false,
      url: m["url"],
      cover_image_url: m["cover_image_url"],
      github_url: m["github_url"],
      license_url: m["license_url"],
      paper_url: m["paper_url"],
      input_schema: input_schema,
      collection_slug: slug,
      created_at: created_at
    })
    |> Repo.insert!(
      on_conflict:
        {:replace,
         [
           :description,
           :run_count,
           :visibility,
           :is_official,
           :url,
           :cover_image_url,
           :github_url,
           :license_url,
           :paper_url,
           :input_schema,
           :collection_slug,
           :created_at,
           :updated_at
         ]},
      conflict_target: [:owner, :name]
    )
  end
end
