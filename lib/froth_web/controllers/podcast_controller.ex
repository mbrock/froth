defmodule FrothWeb.PodcastController do
  @moduledoc """
  REST API for podcast generation. HATEOAS-compliant.

  Roy Fielding, Chapter 5: "The key abstraction of information in REST
  is a resource." A podcast is a resource. A voice is a resource.
  The links between them are the hypermedia.

  ## Endpoints

      GET  /api/podcasts           — list all podcasts
      POST /api/podcasts           — create a new podcast
      GET  /api/podcasts/:id       — get a specific podcast
      GET  /api/voices             — list available voice clones
      GET  /api                    — the root resource (entry point)
  """
  use FrothWeb, :controller

  import Ecto.Query

  # ── Root ──────────────────────────────────────────────
  # Fielding §5.2.1.1: "The centrality of the representation
  # to REST is what makes the architecture style work."
  # The root resource tells you where everything else is.

  def root(conn, _params) do
    json(conn, %{
      _links: %{
        self: %{href: "/api"},
        podcasts: %{href: "/api/podcasts", title: "Podcast collection"},
        voices: %{href: "/api/voices", title: "Available voice clones"}
      },
      name: "Froth Podcast API",
      description: "Generate podcasts with cloned voices. The wrapper is the problem. The payload was always fine."
    })
  end

  # ── Voices ────────────────────────────────────────────

  def voices(conn, _params) do
    voices = Froth.VoiceClone.all()
    |> Enum.map(fn v ->
      %{
        name: v.name,
        voice_id: v.voice_id,
        character: v.character,
        language: v.language,
        tts_model: v.tts_model,
        _links: %{
          self: %{href: "/api/voices/#{URI.encode(v.name)}"}
        }
      }
    end)

    json(conn, %{
      _links: %{
        self: %{href: "/api/voices"},
        root: %{href: "/api"}
      },
      _embedded: %{voices: voices},
      count: length(voices)
    })
  end

  # ── List Podcasts ─────────────────────────────────────

  def index(conn, params) do
    limit = Map.get(params, "limit", "20") |> String.to_integer() |> min(100)
    offset = Map.get(params, "offset", "0") |> String.to_integer()

    scripts = Froth.Repo.all(
      from s in Froth.Podcast.Script,
        order_by: [desc: s.inserted_at],
        limit: ^limit,
        offset: ^offset,
        select: s
    )

    total = Froth.Repo.aggregate(Froth.Podcast.Script, :count)

    items = Enum.map(scripts, &script_to_resource/1)

    links = %{
      self: %{href: "/api/podcasts?limit=#{limit}&offset=#{offset}"},
      root: %{href: "/api"},
      create: %{href: "/api/podcasts", method: "POST", title: "Create a new podcast"}
    }

    # HATEOAS: next/prev links when applicable
    links = if offset + limit < total do
      Map.put(links, :next, %{href: "/api/podcasts?limit=#{limit}&offset=#{offset + limit}"})
    else
      links
    end

    links = if offset > 0 do
      Map.put(links, :prev, %{href: "/api/podcasts?limit=#{limit}&offset=#{max(0, offset - limit)}"})
    else
      links
    end

    json(conn, %{
      _links: links,
      _embedded: %{podcasts: items},
      total: total
    })
  end

  # ── Show Podcast ──────────────────────────────────────

  def show(conn, %{"id" => id}) do
    case Froth.Repo.get(Froth.Podcast.Script, id) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{
          error: "not_found",
          message: "No podcast with id #{id}.",
          _links: %{
            podcasts: %{href: "/api/podcasts"},
            root: %{href: "/api"}
          }
        })

      script ->
        json(conn, script_to_resource(script))
    end
  end

  # ── Create Podcast ────────────────────────────────────
  # POST /api/podcasts
  #
  # Body:
  #   {
  #     "script": [
  #       {"speaker": "nikolai", "text": "That's the whole thing."},
  #       {"speaker": "destiny", "text": "You just reinvented email."}
  #     ],
  #     "label": "Nikolai on the railgun",
  #     "chat_id": -1003690254489,
  #     "pause_ms": 400,
  #     "language": "English",
  #     "model": "minimax/speech-2.8-hd"
  #   }

  def create(conn, params) do
    with {:ok, script_tuples} <- parse_script(params["script"]),
         {:ok, opts} <- parse_opts(params) do

      chat_id = params["chat_id"] || -1003690254489
      label = params["label"] || "API podcast"

      case Froth.Podcast.generate(script_tuples,
        chat_id: chat_id,
        label: label,
        pause_ms: opts[:pause_ms],
        language: opts[:language],
        model: opts[:model],
        concurrency: opts[:concurrency]
      ) do
        {:ok, batch_id} ->
          # Find the script record that was just created
          script = Froth.Repo.one(
            from s in Froth.Podcast.Script,
              where: s.batch_id == ^batch_id,
              limit: 1
          )

          resource = if script do
            script_to_resource(script)
          else
            %{
              batch_id: batch_id,
              status: "queued",
              label: label,
              _links: %{
                self: %{href: "/api/podcasts?batch=#{batch_id}"},
                collection: %{href: "/api/podcasts"}
              }
            }
          end

          conn
          |> put_status(202)
          |> put_resp_header("location", resource_href(script))
          |> json(resource)

        {:error, reason} ->
          conn
          |> put_status(422)
          |> json(%{
            error: "generation_failed",
            message: inspect(reason),
            _links: %{self: %{href: "/api/podcasts"}, root: %{href: "/api"}}
          })
      end
    else
      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{
          error: "invalid_request",
          message: reason,
          _links: %{
            self: %{href: "/api/podcasts"},
            voices: %{href: "/api/voices", title: "Check available voices"},
            root: %{href: "/api"}
          }
        })
    end
  end

  # ── Private ───────────────────────────────────────────

  defp parse_script(nil), do: {:error, "Missing 'script' field. Expected array of {speaker, text} objects."}
  defp parse_script(script) when not is_list(script), do: {:error, "script must be an array."}
  defp parse_script([]), do: {:error, "script must not be empty."}
  defp parse_script(script) do
    result = Enum.reduce_while(script, {:ok, []}, fn item, {:ok, acc} ->
      speaker = item["speaker"] || item["voice"]
      text = item["text"] || item["line"]

      cond do
        is_nil(speaker) -> {:halt, {:error, "Each segment needs a 'speaker' field."}}
        is_nil(text) -> {:halt, {:error, "Each segment needs a 'text' field."}}
        true ->
          tuple = {String.to_atom(speaker), text}
          {:cont, {:ok, [tuple | acc]}}
      end
    end)

    case result do
      {:ok, tuples} -> {:ok, Enum.reverse(tuples)}
      error -> error
    end
  end

  defp parse_opts(params) do
    {:ok, %{
      pause_ms: (params["pause_ms"] || 300) |> to_integer(),
      language: params["language"] || "English",
      model: params["model"] || "minimax/speech-2.8-hd",
      concurrency: (params["concurrency"] || 6) |> to_integer()
    }}
  end

  defp to_integer(v) when is_integer(v), do: v
  defp to_integer(v) when is_binary(v), do: String.to_integer(v)
  defp to_integer(v) when is_float(v), do: round(v)

  defp script_to_resource(script) do
    %{
      id: script.id,
      batch_id: script.batch_id,
      label: script.label,
      status: script.status,
      chat_id: script.chat_id,
      script: script.script,
      opts: script.opts,
      inserted_at: script.inserted_at,
      updated_at: script.updated_at,
      _links: %{
        self: %{href: "/api/podcasts/#{script.id}"},
        collection: %{href: "/api/podcasts"},
        voices: %{href: "/api/voices"}
      }
    }
  end

  defp resource_href(nil), do: "/api/podcasts"
  defp resource_href(script), do: "/api/podcasts/#{script.id}"
end
