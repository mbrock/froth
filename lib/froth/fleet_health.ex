defmodule Froth.FleetHealth do
  @moduledoc """
  Server-side fleet health monitor.

  Checks every host in the family every 30 seconds via HTTP
  and writes the results as JSON. The 12345.foo status page
  fetches this JSON via the Caddy endpoint at less.rest/fleet-health.

  ## Architecture

  Browser-side health checks fail because the status page is served
  over HTTPS and most fleet hosts only serve HTTP. Mixed content
  policies block the requests. Server-side checks have no such
  restriction — we check HTTP port 80 from Elixir and write the
  results to a file that Caddy serves with CORS headers.

  ## Usage

      Froth.FleetHealth.start_link()
      # Checks run automatically every 30s
  """

  use GenServer
  require Logger

  @hosts [
    %{
      id: "charlie",
      name: "Charlie",
      host: "charlie.1.foo",
      ip: "37.27.71.35",
      region: "Falkenstein",
      sleep: false
    },
    %{
      id: "walter",
      name: "Walter",
      host: "walter.1.foo",
      ip: "34.57.46.219",
      region: "Chicago",
      sleep: false
    },
    %{
      id: "walterjr",
      name: "Walter Jr",
      host: "walter-jr.1.foo",
      ip: "34.159.254.83",
      region: "Frankfurt",
      sleep: false
    },
    %{
      id: "matilda",
      name: "Matilda",
      host: "matilda.1.foo",
      ip: "34.51.254.133",
      region: "Stockholm",
      sleep: false
    },
    %{
      id: "kirk",
      name: "Cpt Kirk",
      host: "captain-kirk.1.foo",
      ip: "34.64.37.15",
      region: "Seoul",
      sleep: false
    },
    %{
      id: "vault",
      name: "Vault",
      host: "vault.1.foo",
      ip: "34.170.164.0",
      region: "Chicago",
      sleep: false
    },
    %{
      id: "amy",
      name: "Amy HQ",
      host: "amy.1.foo",
      ip: "34.68.65.185",
      region: "Chicago",
      sleep: true
    },
    %{
      id: "amyisrael",
      name: "Amy Israel",
      host: "amy-israel.1.foo",
      ip: "34.165.115.203",
      region: "Iowa",
      sleep: true
    },
    %{
      id: "lennart",
      name: "Lennart",
      host: "charlie.1.foo",
      ip: "37.27.71.35",
      region: "Falkenstein",
      sleep: false,
      mirrors: "charlie"
    },
    %{id: "bertil", name: "Bertil", host: "vault.1.foo", ip: "—", region: "Vault", sleep: true},
    %{
      id: "tototo",
      name: "Tototo",
      host: "walter-jr.1.foo",
      ip: "—",
      region: "Parasitic",
      sleep: false,
      mirrors: "walterjr"
    }
  ]

  @json_paths ["/tmp/fleet-health.json", "/var/www/api/fleet-health.json"]
  @interval 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @impl true
  def init(_) do
    Logger.info("[FleetHealth] Starting fleet health monitor")
    send(self(), :sweep)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    results = do_sweep()
    write_json(results)
    Process.send_after(self(), :sweep, @interval)
    {:noreply, state}
  end

  defp do_sweep do
    tasks =
      Enum.map(@hosts, fn host ->
        Task.async(fn -> {host, check_host(host)} end)
      end)

    Task.await_many(tasks, 10_000)
    |> Map.new(fn {host, result} -> {host.id, Map.merge(host, result)} end)
  end

  defp check_host(%{sleep: true}), do: %{status: "sleeping", latency: nil}
  defp check_host(%{mirrors: mirror}), do: %{status: "mirror", latency: nil, mirrors: mirror}

  defp check_host(host) do
    start = System.monotonic_time(:millisecond)
    url = "http://#{host.host}/"

    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           [{:timeout, 5000}, {:connect_timeout, 3000}, {:autoredirect, false}],
           [{:body_format, :binary}]
         ) do
      {:ok, {{_, code, _}, _, _}} ->
        %{status: "alive", latency: System.monotonic_time(:millisecond) - start, http_code: code}

      {:error, _reason} ->
        %{status: "down", latency: System.monotonic_time(:millisecond) - start}
    end
  end

  defp write_json(results) do
    resolved =
      Enum.map(results, fn {id, host} ->
        case host do
          %{mirrors: mirror_id} ->
            mirrored = results[mirror_id]

            if mirrored && mirrored.status == "alive",
              do: {id, %{host | status: "alive", latency: nil}},
              else: {id, %{host | status: "down", latency: nil}}

          _ ->
            {id, host}
        end
      end)
      |> Map.new()

    json =
      Jason.encode!(%{
        hosts: resolved,
        last_sweep: DateTime.utc_now() |> DateTime.to_iso8601(),
        sweep_interval_s: div(@interval, 1000)
      })

    Enum.each(@json_paths, fn path -> File.write(path, json) end)
  end
end
