defmodule Froth.Telegram.Calls do
  @moduledoc """
  High-level API for TDLib private calls on user sessions.

  Typical flow:
  1. `create_call/3` or `accept_call/3`
  2. `route_tgcalls_update/3` on `updateCall` / `updateNewCallSignalingData`
  3. `subscribe_call_audio/2` to receive downlink frames
  4. `feed_pcm_frame/2` or `feed_pcm_file/2` for uplink audio

  Audio frame contract (`{:call_audio, call_id, pcm}`) is raw PCM16LE, mono,
  48kHz. This module is the public Elixir-facing entrypoint; lower-level C node
  transport details stay in `Froth.Telegram.Cnode`.
  """

  alias Froth.Telegram
  alias Froth.Telegram.Cnode

  @default_min_layer 65
  @default_max_layer 92

  # Known versions from the vendored tgcalls codebase.
  @fallback_library_versions [
    "2.7.7",
    "5.0.0",
    "7.0.0",
    "8.0.0",
    "9.0.0",
    "10.0.0",
    "11.0.0",
    "12.0.0",
    "13.0.0"
  ]

  @doc """
  Build a `callProtocol` payload.

  If `:library_versions` / `:max_layer` are not provided, it will try
  `Froth.Telegram.Cnode.tgcalls_status/1` and fall back to static defaults.
  """
  def call_protocol(opts \\ []) do
    status = resolve_tgcalls_status(opts)

    library_versions =
      opts
      |> Keyword.get(:library_versions, status["registered_versions"])
      |> normalize_library_versions()

    max_layer =
      opts
      |> Keyword.get(:max_layer, status["max_layer"])
      |> normalize_max_layer()

    %{
      "@type" => "callProtocol",
      "udp_p2p" => Keyword.get(opts, :udp_p2p, true),
      "udp_reflector" => Keyword.get(opts, :udp_reflector, true),
      "min_layer" => Keyword.get(opts, :min_layer, @default_min_layer),
      "max_layer" => max_layer,
      "library_versions" => library_versions
    }
  end

  @doc """
  Start an outgoing private call.
  """
  def create_call(session_id, user_id, opts \\ [])
      when is_binary(session_id) and is_integer(user_id) do
    protocol = Keyword.get(opts, :protocol, call_protocol(opts))
    timeout = Keyword.get(opts, :timeout, 30_000)

    request = create_call_request(user_id, protocol, opts)
    Telegram.call(session_id, request, timeout)
  end

  @doc """
  Accept an incoming private call.
  """
  def accept_call(session_id, call_id, opts \\ [])
      when is_binary(session_id) and is_integer(call_id) do
    protocol = Keyword.get(opts, :protocol, call_protocol(opts))
    timeout = Keyword.get(opts, :timeout, 30_000)

    request = accept_call_request(call_id, protocol)
    Telegram.call(session_id, request, timeout)
  end

  @doc """
  Send signaling data to TDLib.

  By default, binary data is base64-encoded for TDLib's JSON interface.
  Set `data_is_base64: true` if your payload is already base64 text.
  """
  def send_call_signaling_data(session_id, call_id, data, opts \\ [])
      when is_binary(session_id) and is_integer(call_id) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    request = send_call_signaling_data_request(call_id, data, opts)
    Telegram.call(session_id, request, timeout)
  end

  @doc """
  Discard/hang up a private call.
  """
  def discard_call(session_id, call_id, opts \\ [])
      when is_binary(session_id) and is_integer(call_id) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    request = discard_call_request(call_id, opts)
    Telegram.call(session_id, request, timeout)
  end

  @doc """
  Register a process to receive per-frame PCM chunks for a private call.

  The subscriber receives:
  - `{:call_audio, call_id, pcm_frame}`
  - `{:call_media_event, call_id, event_atom}`
  - `{:call_media_error, call_id, reason_binary}`
  """
  def start_private_media(call_id, pid \\ self()) when is_integer(call_id) and is_pid(pid) do
    Cnode.start_private_media(call_id, pid)
  end

  @doc """
  Alias for `start_private_media/2`.
  """
  def subscribe_call_audio(call_id, pid \\ self()) when is_integer(call_id) and is_pid(pid) do
    Cnode.subscribe_call_audio(call_id, pid)
  end

  @doc """
  Unsubscribe a process from call audio frames.
  """
  def unsubscribe_call_audio(call_id, pid \\ self()) when is_integer(call_id) and is_pid(pid) do
    Cnode.unsubscribe_call_audio(call_id, pid)
  end

  @doc """
  Stop media pumping and clear subscribers for a call.
  """
  def stop_private_media(call_id) when is_integer(call_id) do
    Cnode.stop_private_media(call_id)
  end

  @doc """
  Feed a local WAV/PCM file into the call media pump.

  Supported formats:
  - raw PCM16LE mono 48k (`.pcm` style)
  - WAV PCM16 mono 48k
  """
  def feed_pcm_file(call_id, path) when is_integer(call_id) and is_binary(path) do
    Cnode.feed_pcm_file(call_id, path)
  end

  @doc """
  Feed one raw PCM16LE mono 48k frame/chunk into an active call runtime.

  If a tgcalls runtime is active for the call, data is injected into the
  outgoing media path. If no runtime is active, the frame is mirrored back to
  local subscribers as `{:call_audio, call_id, pcm_frame}`.
  """
  def feed_pcm_frame(call_id, pcm_frame)
      when is_integer(call_id) and is_binary(pcm_frame) do
    Cnode.feed_pcm_frame(call_id, pcm_frame)
  end

  @doc """
  Start a per-call tgcalls runtime from an `updateCall.call` map in `callStateReady`.

  The runtime emits signaling through the C node and consumes incoming signaling
  via `receive_tgcalls_signaling_data/3`.
  """
  def start_tgcalls_call(session_id, call, opts \\ [])
      when is_binary(session_id) and is_map(call) and is_list(opts) do
    pid = Keyword.get(opts, :pid, self())
    status_timeout = Keyword.get(opts, :status_timeout, 2_000)

    with true <- is_pid(pid) or {:error, :invalid_pid},
         {:ok, call_id, ready_state, is_outgoing} <- extract_ready_call(call),
         {:ok, status} when is_map(status) <- Cnode.tgcalls_status(status_timeout),
         :ok <- ensure_tgcalls_engine_available(status),
         {:ok, encryption_key} <- decode_tdlib_bytes(Map.get(ready_state, "encryption_key")),
         true <- byte_size(encryption_key) == 256 or {:error, :invalid_encryption_key},
         {:ok, version} <- select_tgcalls_version(status, ready_state),
         servers <- encode_rtc_servers(Map.get(ready_state, "servers", [])),
         custom_parameters <- normalize_binary(Map.get(ready_state, "custom_parameters", "")) do
      Cnode.start_tgcalls_call(
        call_id,
        session_id,
        version,
        is_outgoing,
        Map.get(ready_state, "allow_p2p", false) == true,
        encryption_key,
        servers,
        custom_parameters,
        pid
      )
    else
      {:error, _} = error -> error
      false -> {:error, :invalid_call_state}
    end
  end

  @doc """
  Stop a per-call tgcalls runtime in the C node.
  """
  def stop_tgcalls_call(call_id) when is_integer(call_id) do
    Cnode.stop_tgcalls_call(call_id)
  end

  @doc """
  Feed incoming TDLib call signaling data into the per-call tgcalls runtime.

  Set `data_is_base64: false` if `data` is already raw bytes.
  """
  def receive_tgcalls_signaling_data(call_id, data, opts \\ [])
      when is_integer(call_id) and is_binary(data) and is_list(opts) do
    payload =
      if Keyword.get(opts, :data_is_base64, true) do
        case Base.decode64(data) do
          {:ok, raw} -> raw
          :error -> data
        end
      else
        data
      end

    Cnode.receive_tgcalls_signaling_data(call_id, payload)
  end

  @doc """
  Route a Telegram update into the tgcalls bridge.

  Handles:
  - `updateCall` (`callStateReady`) -> starts tgcalls runtime (unless `auto_start: false`)
  - `updateNewCallSignalingData` -> forwards signaling bytes
  """
  def route_tgcalls_update(session_id, update, opts \\ [])
      when is_binary(session_id) and is_map(update) and is_list(opts) do
    case update do
      %{
        "@type" => "updateNewCallSignalingData",
        "call_id" => call_id,
        "data" => data
      }
      when is_integer(call_id) and is_binary(data) ->
        receive_tgcalls_signaling_data(call_id, data, data_is_base64: true)

      %{
        "@type" => "updateCall",
        "call" =>
          %{
            "state" => %{"@type" => "callStateReady"}
          } = call
      } ->
        if Keyword.get(opts, :auto_start, true) do
          start_tgcalls_call(session_id, call, opts)
        else
          :ok
        end

      _ ->
        :ignore
    end
  end

  @doc """
  Build a `createCall` request map.
  """
  def create_call_request(user_id, protocol, opts \\ [])
      when is_integer(user_id) and is_map(protocol) do
    request = %{
      "@type" => "createCall",
      "user_id" => user_id,
      "protocol" => protocol
    }

    case Keyword.fetch(opts, :is_video) do
      {:ok, is_video} when is_boolean(is_video) -> Map.put(request, "is_video", is_video)
      _ -> request
    end
  end

  @doc """
  Build an `acceptCall` request map.
  """
  def accept_call_request(call_id, protocol) when is_integer(call_id) and is_map(protocol) do
    %{
      "@type" => "acceptCall",
      "call_id" => call_id,
      "protocol" => protocol
    }
  end

  @doc """
  Build a `sendCallSignalingData` request map.
  """
  def send_call_signaling_data_request(call_id, data, opts \\ []) when is_integer(call_id) do
    %{
      "@type" => "sendCallSignalingData",
      "call_id" => call_id,
      "data" => normalize_signaling_data(data, opts)
    }
  end

  @doc """
  Build a `discardCall` request map.
  """
  def discard_call_request(call_id, opts \\ []) when is_integer(call_id) do
    %{
      "@type" => "discardCall",
      "call_id" => call_id,
      "is_disconnected" => Keyword.get(opts, :is_disconnected, true),
      "duration" => Keyword.get(opts, :duration, 0),
      "connection_id" => Keyword.get(opts, :connection_id, 0)
    }
  end

  defp resolve_tgcalls_status(opts) do
    status_timeout = Keyword.get(opts, :status_timeout, 2_000)

    with {:ok, status} when is_map(status) <- Cnode.tgcalls_status(status_timeout) do
      status
    else
      _ -> %{}
    end
  end

  defp normalize_library_versions(versions) when is_list(versions) do
    versions
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> case do
      [] -> @fallback_library_versions
      list -> list
    end
  end

  defp normalize_library_versions(_), do: @fallback_library_versions

  defp normalize_max_layer(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_layer(_), do: @default_max_layer

  defp ensure_tgcalls_engine_available(status) when is_map(status) do
    engine_available? =
      Map.get(status, "engine_available") == true or
        (is_list(status["registered_versions"]) and status["registered_versions"] != [])

    if engine_available? do
      :ok
    else
      {:error, :tgcalls_engine_unavailable}
    end
  end

  defp extract_ready_call(%{
         "id" => call_id,
         "is_outgoing" => is_outgoing,
         "state" => %{"@type" => "callStateReady"} = ready_state
       })
       when is_integer(call_id) and is_boolean(is_outgoing) do
    {:ok, call_id, ready_state, is_outgoing}
  end

  defp extract_ready_call(_), do: {:error, :call_not_ready}

  defp select_tgcalls_version(status, ready_state) do
    local_versions =
      status
      |> Map.get("registered_versions", [])
      |> normalize_version_list()

    remote_versions =
      ready_state
      |> Map.get("protocol", %{})
      |> Map.get("library_versions", [])
      |> normalize_version_list()

    version =
      Enum.find(remote_versions, &(&1 in local_versions)) ||
        List.first(local_versions) ||
        List.first(remote_versions)

    if is_binary(version) and version != "" do
      {:ok, version}
    else
      {:error, :no_tgcalls_version}
    end
  end

  defp normalize_version_list(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_version_list(_), do: []

  defp encode_rtc_servers(servers) when is_list(servers) do
    Enum.flat_map(servers, fn
      %{
        "id" => id,
        "port" => port,
        "type" => %{"@type" => "callServerTypeWebrtc"} = type
      } = server
      when is_integer(id) and is_integer(port) and port > 0 and port <= 65_535 ->
        [
          {id, normalize_binary(Map.get(server, "ip_address", "")),
           normalize_binary(Map.get(server, "ipv6_address", "")), port,
           normalize_binary(Map.get(type, "username", "")),
           normalize_binary(Map.get(type, "password", "")),
           Map.get(type, "supports_turn", false) == true, false, <<>>}
        ]

      %{
        "id" => id,
        "port" => port,
        "type" => %{"@type" => "callServerTypeTelegramReflector"} = type
      } = server
      when is_integer(id) and is_integer(port) and port > 0 and port <= 65_535 ->
        peer_tag =
          case decode_tdlib_bytes(Map.get(type, "peer_tag", "")) do
            {:ok, bytes} -> bytes
            {:error, _} -> <<>>
          end

        [
          {id, normalize_binary(Map.get(server, "ip_address", "")),
           normalize_binary(Map.get(server, "ipv6_address", "")), port, "", "", true,
           Map.get(type, "is_tcp", false) == true, peer_tag}
        ]

      _ ->
        []
    end)
  end

  defp encode_rtc_servers(_), do: []

  defp decode_tdlib_bytes(data) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:ok, data}
    end
  end

  defp decode_tdlib_bytes(_), do: {:error, :invalid_bytes}

  defp normalize_binary(value) when is_binary(value), do: value
  defp normalize_binary(_), do: ""

  defp normalize_signaling_data(data, opts) when is_binary(data) do
    if Keyword.get(opts, :data_is_base64, false) do
      data
    else
      Base.encode64(data)
    end
  end

  defp normalize_signaling_data(data, opts) when is_list(data) do
    data
    |> :erlang.list_to_binary()
    |> normalize_signaling_data(opts)
  end

  defp normalize_signaling_data(data, _opts), do: data
end
