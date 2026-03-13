defmodule Froth.RegionalNews do
  @moduledoc """
  Geo-located regional news via Grok.

  Keeps a shared in-flight resource per cache key so multiple HTTP clients can
  attach to the same generation, replay buffered chunks, and continue from the
  current point in the stream.
  """

  use GenServer
  require Logger

  @cache_ttl_ms 3_600_000
  @await_timeout_ms 75_000
  @stream_message :regional_news_stream
  @task_chunk_message :regional_news_task_chunk
  @task_done_message :regional_news_task_done
  @task_error_message :regional_news_task_error
  @geoip_url "http://ip-api.com/json"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Attach `subscriber` to the shared stream for an IP address.

  Returns the current buffered snapshot and whether generation has already
  completed.
  """
  def open_stream(ip, subscriber \\ self()) when is_binary(ip) and is_pid(subscriber) do
    with {:ok, location} <- geolocate(ip) do
      cache_key = cache_key(location)
      GenServer.call(__MODULE__, {:open_stream, cache_key, location, subscriber}, :infinity)
    end
  end

  @doc "Detach `subscriber` from a shared regional news stream."
  def detach(cache_key, subscriber \\ self())
      when is_binary(cache_key) and is_pid(subscriber) do
    GenServer.call(__MODULE__, {:detach, cache_key, subscriber})
  end

  @doc "Clear cached and in-flight streams. Mainly used in tests."
  def reset do
    GenServer.call(__MODULE__, :reset, :infinity)
  end

  @doc "Get regional news for an IP address. Returns {:ok, markdown, location} or {:error, reason}."
  def get_news(ip) when is_binary(ip) do
    with {:ok, stream} <- open_stream(ip, self()) do
      text = IO.iodata_to_binary(stream.chunks)

      if stream.done? do
        {:ok, text, stream.location}
      else
        await_news(stream.cache_key, text, stream.location)
      end
    end
  end

  @impl true
  def init(_) do
    {:ok, %{resources: %{}}}
  end

  @impl true
  def handle_call({:open_stream, cache_key, location, subscriber}, _from, state) do
    state = prune_expired(state)

    case Map.get(state.resources, cache_key) do
      nil ->
        case start_resource(state, cache_key, location, subscriber) do
          {:ok, resource, state} ->
            {:reply, {:ok, snapshot(resource)}, state}

          {:error, reason, state} ->
            {:reply, {:error, reason}, state}
        end

      %{status: :running} = resource ->
        resource = add_subscriber(resource, subscriber)
        state = put_resource(state, cache_key, resource)
        {:reply, {:ok, snapshot(resource)}, state}

      %{status: :done} = resource ->
        {:reply, {:ok, snapshot(resource)}, state}
    end
  end

  @impl true
  def handle_call({:detach, cache_key, subscriber}, _from, state) do
    state =
      update_resource(state, cache_key, fn resource ->
        remove_subscriber(resource, subscriber)
      end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    Enum.each(state.resources, fn {_cache_key, resource} ->
      maybe_stop_task(resource)
      demonitor_task(resource)
      demonitor_subscribers(resource)
    end)

    {:reply, :ok, %{state | resources: %{}}}
  end

  @impl true
  def handle_info({@task_chunk_message, cache_key, chunk}, state) do
    chunk = IO.iodata_to_binary(chunk)

    if chunk == "" do
      {:noreply, state}
    else
      state =
        update_resource(state, cache_key, fn resource ->
          resource = %{resource | chunks_rev: [chunk | resource.chunks_rev]}
          notify_subscribers(resource.subscribers, {@stream_message, cache_key, {:chunk, chunk}})
          resource
        end)

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({@task_done_message, cache_key}, state) do
    state =
      update_resource(state, cache_key, fn resource ->
        notify_subscribers(resource.subscribers, {@stream_message, cache_key, :done})

        resource
        |> demonitor_task()
        |> demonitor_subscribers()
        |> Map.put(:status, :done)
        |> Map.put(:expires_at, System.monotonic_time(:millisecond) + @cache_ttl_ms)
      end)

    {:noreply, state}
  end

  @impl true
  def handle_info({@task_error_message, cache_key, reason}, state) do
    state =
      case Map.get(state.resources, cache_key) do
        nil ->
          state

        resource ->
          notify_subscribers(resource.subscribers, {@stream_message, cache_key, {:error, reason}})

          resource
          |> demonitor_task()
          |> demonitor_subscribers()

          %{state | resources: Map.delete(state.resources, cache_key)}
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case find_task_resource(state.resources, ref) do
      {cache_key, resource} ->
        if resource.status == :running do
          error = "regional news stream exited: #{inspect(reason)}"
          notify_subscribers(resource.subscribers, {@stream_message, cache_key, {:error, error}})

          resource
          |> demonitor_task()
          |> demonitor_subscribers()
        end

        {:noreply, %{state | resources: Map.delete(state.resources, cache_key)}}

      nil ->
        state =
          case find_subscriber_resource(state.resources, pid, ref) do
            {cache_key, _resource} ->
              update_resource(state, cache_key, fn resource ->
                %{resource | subscribers: Map.delete(resource.subscribers, pid)}
              end)

            nil ->
              state
          end

        {:noreply, state}
    end
  end

  defp await_news(cache_key, acc, location) do
    receive do
      {@stream_message, ^cache_key, {:chunk, chunk}} ->
        await_news(cache_key, acc <> chunk, location)

      {@stream_message, ^cache_key, :done} ->
        {:ok, acc, location}

      {@stream_message, ^cache_key, {:error, reason}} ->
        {:error, reason}
    after
      @await_timeout_ms ->
        detach(cache_key)
        {:error, "timed out waiting for regional news"}
    end
  end

  defp start_resource(state, cache_key, location, subscriber) do
    case Task.Supervisor.start_child(Froth.TaskSupervisor, fn ->
           run_stream(cache_key, location)
         end) do
      {:ok, pid} ->
        resource =
          %{
            cache_key: cache_key,
            location: location,
            chunks_rev: [],
            status: :running,
            expires_at: nil,
            task_pid: pid,
            task_ref: Process.monitor(pid),
            subscribers: %{}
          }
          |> add_subscriber(subscriber)

        {:ok, resource, put_resource(state, cache_key, resource)}

      {:error, reason} ->
        {:error, "failed to start regional news stream: #{inspect(reason)}", state}
    end
  end

  defp run_stream(cache_key, location) do
    case query_grok(location, fn chunk ->
           send(__MODULE__, {@task_chunk_message, cache_key, chunk})
         end) do
      :ok ->
        send(__MODULE__, {@task_done_message, cache_key})

      {:error, reason} ->
        send(__MODULE__, {@task_error_message, cache_key, reason})
    end
  end

  defp snapshot(resource) do
    %{
      cache_key: resource.cache_key,
      location: resource.location,
      header: header_for(resource.location),
      chunks: Enum.reverse(resource.chunks_rev),
      done?: resource.status == :done
    }
  end

  defp header_for(location) do
    "Regional News for #{location_label(location)}\nGenerated by Grok via Froth\n\n"
  end

  defp location_label(location) do
    [location.city, location.region, location.country]
    |> Enum.filter(&present_string?/1)
    |> Enum.join(", ")
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp cache_key(location) do
    country_part =
      if present_string?(location.country_code), do: location.country_code, else: location.country

    [country_part, location.region, location.city]
    |> Enum.map(&normalize_key_part/1)
    |> Enum.join("|")
  end

  defp normalize_key_part(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_key_part(_value), do: ""

  defp prune_expired(state) do
    now = System.monotonic_time(:millisecond)

    resources =
      state.resources
      |> Enum.reject(fn {_cache_key, resource} ->
        resource.status == :done and is_integer(resource.expires_at) and
          resource.expires_at <= now
      end)
      |> Map.new()

    %{state | resources: resources}
  end

  defp update_resource(state, cache_key, fun) do
    case Map.get(state.resources, cache_key) do
      nil ->
        state

      resource ->
        put_resource(state, cache_key, fun.(resource))
    end
  end

  defp put_resource(state, cache_key, resource) do
    %{state | resources: Map.put(state.resources, cache_key, resource)}
  end

  defp add_subscriber(resource, subscriber) do
    case Map.has_key?(resource.subscribers, subscriber) do
      true ->
        resource

      false ->
        ref = Process.monitor(subscriber)
        %{resource | subscribers: Map.put(resource.subscribers, subscriber, ref)}
    end
  end

  defp remove_subscriber(resource, subscriber) do
    case Map.pop(resource.subscribers, subscriber) do
      {nil, _subscribers} ->
        resource

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        %{resource | subscribers: subscribers}
    end
  end

  defp demonitor_task(%{task_ref: nil} = resource), do: resource

  defp demonitor_task(resource) do
    Process.demonitor(resource.task_ref, [:flush])
    %{resource | task_ref: nil, task_pid: nil}
  end

  defp demonitor_subscribers(resource) do
    Enum.each(resource.subscribers, fn {_pid, ref} ->
      Process.demonitor(ref, [:flush])
    end)

    %{resource | subscribers: %{}}
  end

  defp maybe_stop_task(%{task_pid: nil}), do: :ok

  defp maybe_stop_task(%{task_pid: pid}) do
    Process.exit(pid, :kill)
    :ok
  end

  defp notify_subscribers(subscribers, message) do
    Enum.each(subscribers, fn {pid, _ref} ->
      send(pid, message)
    end)
  end

  defp find_task_resource(resources, ref) do
    Enum.find(resources, fn {_cache_key, resource} ->
      resource.task_ref == ref
    end)
  end

  defp find_subscriber_resource(resources, pid, ref) do
    Enum.find(resources, fn {_cache_key, resource} ->
      Map.get(resource.subscribers, pid) == ref
    end)
  end

  defp geolocate(ip) do
    case Application.get_env(:froth, :regional_news_geolocate_fun) do
      fun when is_function(fun, 1) ->
        fun.(ip)

      _ ->
        if fallback_to_server_geo?(ip) do
          Logger.info("regional news falling back to server geolocation for ip=#{inspect(ip)}")
          geolocate_via_http(nil)
        else
          geolocate_via_http(ip)
        end
    end
  end

  defp geolocate_via_http(ip) do
    case geoip_request(geoip_url(ip)) do
      {:ok, %{status: 200, body: %{"status" => "success"} = body}} ->
        {:ok,
         %{
           country: body["country"],
           country_code: body["countryCode"],
           region: body["regionName"],
           city: body["city"],
           lat: body["lat"],
           lon: body["lon"]
         }}

      {:ok, %{status: 200, body: %{"status" => "fail"} = body}} ->
        {:error, "geolocation failed: #{format_geoip_failure(body)}"}

      {:ok, %{status: status, body: body}} ->
        {:error, "geolocation request failed: status #{status} #{inspect(body)}"}

      {:error, reason} ->
        {:error, "geolocation request failed: #{inspect(reason)}"}
    end
  end

  defp geoip_request(url) do
    case Application.get_env(:froth, :regional_news_geoip_fun) do
      fun when is_function(fun, 1) ->
        fun.(url)

      _ ->
        Req.get(url, receive_timeout: 5_000, decode_body: true)
    end
  end

  defp geoip_url(nil),
    do: "#{@geoip_url}?fields=status,country,countryCode,regionName,city,lat,lon"

  defp geoip_url(""), do: geoip_url(nil)

  defp geoip_url(ip) do
    "#{@geoip_url}/#{ip}?fields=status,country,countryCode,regionName,city,lat,lon"
  end

  defp format_geoip_failure(%{"message" => msg}) when is_binary(msg) and msg != "", do: msg
  defp format_geoip_failure(body), do: inspect(body)

  defp fallback_to_server_geo?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(String.trim(ip))) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {10, _, _, _}} -> true
      {:ok, {172, second, _, _}} when second in 16..31 -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {169, 254, _, _}} -> true
      {:ok, {100, second, _, _}} when second in 64..127 -> true
      {:ok, {192, 0, 2, _}} -> true
      {:ok, {198, 51, 100, _}} -> true
      {:ok, {203, 0, 113, _}} -> true
      {:ok, {0, _, _, _}} -> true
      {:ok, {224, _, _, _}} -> true
      {:ok, {first, _, _, _}} when first > 224 -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 0}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {first, _, _, _, _, _, _, _}} when first in 0xFC00..0xFDFF -> true
      {:ok, {first, _, _, _, _, _, _, _}} when first in 0xFE80..0xFEBF -> true
      {:ok, {0x2001, 0x0DB8, _, _, _, _, _, _}} -> true
      _ -> false
    end
  end

  defp fallback_to_server_geo?(_ip), do: true

  defp query_grok(location, on_chunk) when is_function(on_chunk, 1) do
    case Application.get_env(:froth, :regional_news_query_fun) do
      fun when is_function(fun, 2) ->
        fun.(location, on_chunk)

      _ ->
        query_grok_via_grok(location, on_chunk)
    end
  end

  defp query_grok_via_grok(location, on_chunk) when is_function(on_chunk, 1) do
    %{country: country, region: region, city: city} = location
    streamed_key = {__MODULE__, :streamed_deltas}

    query = """
    Produce a comprehensive intelligence briefing on #{city}, #{region}, #{country}.
    Cover the last 24 hours. Include political developments, security situation,
    economic indicators, infrastructure events, notable incidents, and any
    developing situations of strategic interest. Search thoroughly with multiple
    queries across different source types. Cross-reference and assess reliability.
    """

    system = """
    You are a diplomatic cable author in the style of the cables published by
    WikiLeaks. Write in English regardless of the region. Use the format:
    SUBJECT line, followed by numbered paragraphs. Classify information by
    source reliability. Use diplomatic cable conventions: COMMENT paragraphs
    for analysis, ACTION REQUEST for recommendations. Reference specific sources
    as footnotes. Be thorough, blunt, and analytically precise. No euphemism.
    The reader is a senior official who needs to understand the situation in
    this region in five minutes.
    """

    Process.put(streamed_key, [])

    result =
      case Froth.Grok.stream_single(
             [%{"role" => "user", "content" => query}],
             fn
               {:text_delta, delta} when is_binary(delta) ->
                 Process.put(streamed_key, [delta | Process.get(streamed_key, [])])
                 on_chunk.(delta)

               _event ->
                 :ok
             end,
             system: system,
             model: "grok-4-1-fast-reasoning",
             tools: [%{"type" => "x_search"}, %{"type" => "web_search"}],
             effort: "low"
           ) do
        {:ok, %{text: text}} when is_binary(text) ->
          maybe_emit_tail(text, streamed_key, on_chunk)

        {:ok, result} ->
          text = extract_text_from_result(result)

          cond do
            text != "" ->
              maybe_emit_tail(text, streamed_key, on_chunk)

            Process.get(streamed_key, []) != [] ->
              :ok

            true ->
              {:error, "empty response"}
          end

        {:error, reason} ->
          {:error, "grok: #{inspect(reason)}"}
      end

    Process.delete(streamed_key)
    result
  end

  defp maybe_emit_tail(text, streamed_key, on_chunk) when is_binary(text) do
    streamed_text =
      streamed_key
      |> Process.get([])
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    cond do
      text == "" and streamed_text == "" ->
        {:error, "empty response"}

      text == "" ->
        :ok

      streamed_text == "" ->
        on_chunk.(text)
        :ok

      String.starts_with?(text, streamed_text) and byte_size(text) > byte_size(streamed_text) ->
        suffix =
          binary_part(text, byte_size(streamed_text), byte_size(text) - byte_size(streamed_text))

        on_chunk.(suffix)
        :ok

      true ->
        :ok
    end
  end

  defp extract_text_from_result(%{content: content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      text when is_binary(text) -> [text]
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      %{type: "text", text: text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join()
  end

  defp extract_text_from_result(%{text: text}) when is_binary(text), do: text
  defp extract_text_from_result(%{"text" => text}) when is_binary(text), do: text
  defp extract_text_from_result(_), do: ""
end
