defmodule Froth.Replicate.ReadmeWorker do
  @moduledoc "Oban worker that fetches a README from GitHub and stores it on the replicate model."
  use Oban.Worker, queue: :github, max_attempts: 5

  require Logger

  alias Froth.Repo
  alias Froth.Replicate.Model

  import Ecto.Query

  @impl true
  def perform(%Oban.Job{args: %{"owner" => owner, "name" => name, "gh_repo" => gh_repo} = args}) do
    path = args["path"]

    case fetch_readme(gh_repo, path) do
      {:ok, content} ->
        from(m in Model, where: m.owner == ^owner and m.name == ^name)
        |> Repo.update_all(
          set: [readme: content, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )

        Logger.info(event: :readme_fetched, owner: owner, name: name, bytes: byte_size(content))
        :ok

      {:error, :not_found} ->
        Logger.info(event: :readme_not_found, gh_repo: gh_repo, path: path)
        {:discard, "no README found"}

      {:error, :rate_limited} ->
        {:snooze, 60}

      {:error, reason} ->
        Logger.error(event: :readme_fetch_failed, gh_repo: gh_repo, reason: inspect(reason))
        {:error, inspect(reason)}
    end
  end

  defp fetch_readme(repo, path) do
    url =
      case path do
        nil -> "https://api.github.com/repos/#{repo}/readme"
        "" -> "https://api.github.com/repos/#{repo}/readme"
        p -> "https://api.github.com/repos/#{repo}/readme/#{p}"
      end

    headers = [
      {"accept", "application/vnd.github.raw+json"},
      {"authorization", "Bearer #{github_token()}"},
      {"user-agent", "froth/1.0"},
      {"x-github-api-version", "2022-11-28"}
    ]

    req = Finch.build(:get, url, headers)

    case Finch.request(req, Froth.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Finch.Response{status: 301, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"url" => redirect_url}} ->
            Logger.info(event: :github_redirect, repo: repo, url: redirect_url)
            redirect_req = Finch.build(:get, redirect_url, headers)

            case Finch.request(redirect_req, Froth.Finch, receive_timeout: 15_000) do
              {:ok, %Finch.Response{status: 200, body: body}} ->
                {:ok, body}

              {:ok, %Finch.Response{status: 404}} ->
                {:error, :not_found}

              {:ok, %Finch.Response{status: s, body: b}} ->
                {:error, {:http_error, s, String.slice(b, 0, 500)}}

              {:error, err} ->
                {:error, {:request_failed, err}}
            end

          _ ->
            {:error, {:http_error, 301, String.slice(body, 0, 500)}}
        end

      {:ok, %Finch.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Finch.Response{status: 403, body: body}} ->
        Logger.warning(event: :github_rate_limited, body: String.slice(body, 0, 200))
        {:error, :rate_limited}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, String.slice(body, 0, 500)}}

      {:error, err} ->
        {:error, {:request_failed, err}}
    end
  end

  defp github_token do
    case System.get_env("GH_TOKEN") || System.get_env("GITHUB_TOKEN") do
      nil ->
        case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
          {token, 0} -> String.trim(token)
          _ -> raise "No GitHub token available (set GH_TOKEN or install gh CLI)"
        end

      token ->
        token
    end
  end
end
