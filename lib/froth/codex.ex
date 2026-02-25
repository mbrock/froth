defmodule Froth.Codex do
  @moduledoc """
  Client for `codex app-server` over stdio JSONL.

  The server speaks a JSON-RPC-like protocol (without `"jsonrpc": "2.0"`).
  Use `request/4` for methods that expect a response, and `notify/3` for
  notifications.

  Notifications are broadcast over Phoenix PubSub on topic `\"codex\"` by default.
  You can override the topic with `start_link(topic: "...")`.

  Consumers receive streamed server notifications as:

      {:codex, :notification, method, params, raw_message, raw_line}

  Protocol problems are broadcast as:

      {:codex, :protocol_error, reason}
  """

  use GenServer
  require Logger

  @type server :: GenServer.server()
  @type method :: String.t()
  @type params :: map()
  @type rpc_error :: %{optional(String.t()) => term()}

  @default_request_timeout 30_000
  @default_topic "codex"

  @request_methods [
    {:thread_start, "thread/start"},
    {:thread_resume, "thread/resume"},
    {:thread_fork, "thread/fork"},
    {:thread_read, "thread/read"},
    {:thread_list, "thread/list"},
    {:thread_loaded_list, "thread/loaded/list"},
    {:thread_archive, "thread/archive"},
    {:thread_unarchive, "thread/unarchive"},
    {:thread_compact_start, "thread/compact/start"},
    {:thread_rollback, "thread/rollback"},
    {:turn_start, "turn/start"},
    {:turn_steer, "turn/steer"},
    {:turn_interrupt, "turn/interrupt"},
    {:review_start, "review/start"},
    {:command_exec, "command/exec"},
    {:model_list, "model/list"},
    {:experimental_feature_list, "experimentalFeature/list"},
    {:collaboration_mode_list, "collaborationMode/list"},
    {:skills_list, "skills/list"},
    {:app_list, "app/list"},
    {:skills_config_write, "skills/config/write"},
    {:mcp_server_oauth_login, "mcpServer/oauth/login"},
    {:tool_request_user_input, "tool/requestUserInput"},
    {:config_mcp_server_reload, "config/mcpServer/reload"},
    {:mcp_server_status_list, "mcpServerStatus/list"},
    {:feedback_upload, "feedback/upload"},
    {:account_read, "account/read"},
    {:config_read, "config/read"},
    {:config_value_write, "config/value/write"},
    {:config_batch_write, "config/batchWrite"},
    {:config_requirements_read, "configRequirements/read"}
  ]

  @doc """
  Start a client process.

  Options:
    - `:name` - GenServer name (defaults to this module)
    - `:executable` - binary to run (default: `codex` on PATH)
    - `:args` - command arguments (default: `["app-server"]`)
    - `:cwd` - optional working directory for the server process
    - `:request_timeout` - default request timeout in ms (default: 30_000)
    - `:pubsub` - PubSub module/name (default: `Froth.PubSub`)
    - `:topic` - PubSub topic for events (default: `"codex"`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Stop the client process."
  @spec stop(server(), timeout()) :: :ok
  def stop(server \\ __MODULE__, timeout \\ 5_000), do: GenServer.stop(server, :normal, timeout)

  @doc """
  Subscribe the current process to Codex events over PubSub.

  By default, subscribes to the topic configured on the server process.
  You can override with `topic: "..."` and/or `pubsub: ...`.
  """
  @spec subscribe(server(), keyword()) :: :ok | {:error, term()}
  def subscribe(server \\ __MODULE__, opts \\ []) when is_list(opts) do
    with {:ok, {pubsub, topic}} <- resolve_pubsub_topic(server, opts),
         :ok <- Phoenix.PubSub.subscribe(pubsub, topic) do
      Logger.info(event: :codex_pubsub_subscribe, pubsub: inspect(pubsub), topic: topic)
      :ok
    end
  end

  @doc """
  Unsubscribe the current process from Codex events over PubSub.

  By default, unsubscribes from the topic configured on the server process.
  You can override with `topic: "..."` and/or `pubsub: ...`.
  """
  @spec unsubscribe(server(), keyword()) :: :ok | {:error, term()}
  def unsubscribe(server \\ __MODULE__, opts \\ []) when is_list(opts) do
    with {:ok, {pubsub, topic}} <- resolve_pubsub_topic(server, opts),
         :ok <- Phoenix.PubSub.unsubscribe(pubsub, topic) do
      Logger.info(event: :codex_pubsub_unsubscribe, pubsub: inspect(pubsub), topic: topic)
      :ok
    end
  end

  @doc """
  Return the configured `{pubsub, topic}` for a running Codex client.
  """
  @spec pubsub_topic(server()) :: {:ok, {term(), String.t()}} | {:error, term()}
  def pubsub_topic(server \\ __MODULE__) do
    try do
      {:ok, GenServer.call(server, :pubsub_topic)}
    catch
      :exit, {:noproc, _} -> {:error, :not_running}
    end
  end

  @doc """
  Send a request and wait for the response.

  Returns:
    - `{:ok, result}` when a JSON-RPC result is received
    - `{:error, rpc_error}` when a JSON-RPC error is received
    - `{:error, :timeout}` when no response arrives in time
  """
  @spec request(server(), method(), params(), keyword()) ::
          {:ok, term()} | {:error, rpc_error() | :timeout | term()}
  def request(server \\ __MODULE__, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout)

    call_timeout =
      case timeout do
        ms when is_integer(ms) and ms > 0 -> ms + 1_000
        _ -> :infinity
      end

    GenServer.call(server, {:request, method, params, timeout}, call_timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  @doc """
  Send a notification (no response expected).
  """
  @spec notify(server(), method(), params()) :: :ok | {:error, term()}
  def notify(server \\ __MODULE__, method, params \\ %{})
      when is_binary(method) and is_map(params) do
    GenServer.call(server, {:notify, method, params})
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
  end

  @doc """
  Send the required initialize request.

  Options:
    - `:capabilities` - map passed as `capabilities`
    - `:timeout` - request timeout
  """
  @spec initialize(server(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def initialize(server \\ __MODULE__, client_info, opts \\ []) when is_map(client_info) do
    params = %{"clientInfo" => deep_stringify_keys(client_info)}

    params =
      case Keyword.get(opts, :capabilities) do
        caps when is_map(caps) -> Map.put(params, "capabilities", deep_stringify_keys(caps))
        _ -> params
      end

    request(server, "initialize", params,
      timeout: Keyword.get(opts, :timeout, @default_request_timeout)
    )
  end

  @doc "Send the `initialized` notification."
  @spec initialized(server()) :: :ok | {:error, term()}
  def initialized(server \\ __MODULE__), do: notify(server, "initialized", %{})

  @doc """
  Convenience handshake: `initialize` followed by `initialized`.
  """
  @spec handshake(server(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handshake(server \\ __MODULE__, client_info, opts \\ []) when is_map(client_info) do
    case initialize(server, client_info, opts) do
      {:ok, result} ->
        case initialized(server) do
          :ok -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  for {fun, rpc_method} <- @request_methods do
    @doc "Call `#{rpc_method}`."
    @spec unquote(fun)(server(), map(), keyword()) :: {:ok, term()} | {:error, term()}
    def unquote(fun)(server \\ __MODULE__, params \\ %{}, opts \\ [])
        when is_map(params) and is_list(opts) do
      request(server, unquote(rpc_method), params, opts)
    end
  end

  @impl true
  def init(opts) do
    executable = resolve_executable(opts)

    args = Keyword.get(opts, :args, ["app-server"])
    request_timeout = Keyword.get(opts, :request_timeout, @default_request_timeout)
    cwd = Keyword.get(opts, :cwd)
    pubsub = Keyword.get(opts, :pubsub, Froth.PubSub)
    topic = Keyword.get(opts, :topic, @default_topic)

    # Ensure bun is on PATH for the codex shebang (#!/usr/bin/env bun)
    bun_bin = Path.join(System.user_home!(), ".bun/bin")
    current_path = System.get_env("PATH", "/usr/bin:/bin")
    env = [{~c"PATH", String.to_charlist("#{bun_bin}:#{current_path}")}]

    port_opts =
      [:binary, :use_stdio, :exit_status, :hide, {:args, args}, {:env, env}] ++
        if(is_binary(cwd) and cwd != "", do: [{:cd, cwd}], else: [])

    try do
      port = Port.open({:spawn_executable, executable}, port_opts)

      Logger.info(
        event: :codex_started,
        executable: executable,
        args: args,
        cwd: cwd,
        request_timeout_ms: request_timeout,
        pubsub: inspect(pubsub),
        topic: topic
      )

      {:ok,
       %{
         port: port,
         executable: executable,
         args: args,
         request_timeout: request_timeout,
         pubsub: pubsub,
         topic: topic,
         next_id: 1,
         pending: %{},
         buffer: ""
       }}
    rescue
      e ->
        Logger.error(
          event: :codex_start_failed,
          executable: executable,
          args: args,
          error: Exception.message(e)
        )

        {:stop, {:port_open_failed, Exception.message(e)}}
    end
  end

  @impl true
  def handle_call(:pubsub_topic, _from, state) do
    {:reply, {state.pubsub, state.topic}, state}
  end

  def handle_call({:notify, method, params}, _from, state) do
    msg = %{"method" => method, "params" => deep_stringify_keys(params)}

    Logger.info(
      event: :codex_notify_send,
      method: method,
      params_preview: preview(params)
    )

    case send_message(state.port, msg) do
      :ok ->
        Logger.debug(event: :codex_notify_sent, method: method)
        {:reply, :ok, state}

      {:error, reason} = error ->
        Logger.warning(event: :codex_notify_failed, method: method, reason: inspect(reason))
        {:reply, error, state}
    end
  end

  def handle_call({:request, method, params, timeout}, from, state) do
    id = state.next_id
    timeout_ms = valid_timeout_ms(timeout, state.request_timeout)

    msg = %{
      "id" => id,
      "method" => method,
      "params" => deep_stringify_keys(params)
    }

    Logger.info(
      event: :codex_request_send,
      id: id,
      method: method,
      timeout_ms: timeout_ms,
      pending_count: map_size(state.pending),
      params_preview: preview(params)
    )

    case send_message(state.port, msg) do
      :ok ->
        timer = Process.send_after(self(), {:request_timeout, id}, timeout_ms)

        pending =
          Map.put(state.pending, id, %{
            from: from,
            timer: timer,
            method: method
          })

        Logger.debug(
          event: :codex_request_queued,
          id: id,
          method: method,
          pending_count: map_size(pending)
        )

        {:noreply, %{state | next_id: id + 1, pending: pending}}

      {:error, reason} = error ->
        Logger.warning(
          event: :codex_request_failed_to_send,
          id: id,
          method: method,
          reason: inspect(reason)
        )

        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    buffer = state.buffer <> data
    {lines, rest} = split_complete_lines(buffer)

    Logger.debug(
      event: :codex_data_chunk,
      bytes: byte_size(data),
      complete_lines: length(lines),
      buffered_bytes: byte_size(rest)
    )

    state = %{state | buffer: rest}
    state = Enum.reduce(lines, state, &handle_line/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning(
      event: :codex_server_exited,
      status: status,
      pending_count: map_size(state.pending)
    )

    state = fail_all_pending(state, {:server_exited, status})
    broadcast_protocol_error(state, {:server_exited, status})
    {:stop, :normal, state}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from, method: method}, pending} ->
        Logger.warning(
          event: :codex_request_timeout,
          id: id,
          method: method,
          pending_count: map_size(pending)
        )

        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Logger.warning(
      event: :codex_terminate,
      pending_count: map_size(state.pending),
      pubsub: inspect(state.pubsub),
      topic: state.topic
    )

    fail_all_pending(state, :terminated)
    :ok
  end

  defp handle_line(raw_line, state) do
    line = raw_line |> String.trim_trailing("\r") |> String.trim()

    if line == "" do
      state
    else
      case Jason.decode(line) do
        {:ok, %{"id" => id} = msg} ->
          Logger.debug(
            event: :codex_response_received,
            id: inspect(id),
            raw_preview: preview(msg)
          )

          handle_response(id, msg, state)

        {:ok, %{"method" => method} = msg} when is_binary(method) ->
          params = Map.get(msg, "params", %{})

          Logger.info(
            event: :codex_notification_received,
            method: method,
            topic: state.topic,
            params_preview: preview(params)
          )

          broadcast_notification(state, method, params, msg, line)
          state

        {:ok, msg} ->
          Logger.warning(event: :codex_unknown_message, message_preview: preview(msg))
          broadcast_protocol_error(state, {:unknown_message, msg})
          state

        {:error, reason} ->
          Logger.warning(
            event: :codex_invalid_json,
            line_preview: String.slice(line, 0, 500),
            reason: inspect(reason)
          )

          broadcast_protocol_error(state, {:invalid_json, line, inspect(reason)})
          state
      end
    end
  end

  defp handle_response(id, msg, state) do
    id = normalize_response_id(id)

    case Map.pop(state.pending, id) do
      {nil, pending} ->
        Logger.warning(
          event: :codex_unexpected_response,
          id: inspect(id),
          response_preview: preview(msg)
        )

        broadcast_protocol_error(state, {:unexpected_response, msg})
        %{state | pending: pending}

      {%{from: from, timer: timer}, pending} ->
        Process.cancel_timer(timer)

        if Map.has_key?(msg, "error") do
          Logger.warning(
            event: :codex_request_error_response,
            id: inspect(id),
            error_preview: preview(msg["error"])
          )
        else
          Logger.info(event: :codex_request_ok_response, id: inspect(id))
        end

        GenServer.reply(from, decode_response(msg))
        %{state | pending: pending}
    end
  end

  defp decode_response(%{"result" => result}), do: {:ok, result}
  defp decode_response(%{"error" => error}), do: {:error, normalize_rpc_error(error)}
  defp decode_response(other), do: {:error, {:invalid_response, other}}

  defp normalize_rpc_error(error) when is_map(error), do: error
  defp normalize_rpc_error(error), do: %{"message" => to_string(error)}

  defp normalize_response_id(id) when is_integer(id), do: id

  defp normalize_response_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _ -> id
    end
  end

  defp normalize_response_id(id), do: id

  defp send_message(port, msg) when is_port(port) and is_map(msg) do
    data = Jason.encode!(msg) <> "\n"

    Logger.debug(
      event: :codex_send_raw,
      bytes: byte_size(data),
      message_preview: String.slice(data, 0, 500)
    )

    case Port.command(port, data) do
      true ->
        :ok

      _ ->
        Logger.warning(event: :codex_send_failed, reason: :port_closed)
        {:error, :port_closed}
    end
  rescue
    ArgumentError ->
      Logger.warning(event: :codex_send_failed, reason: :port_closed)
      {:error, :port_closed}
  end

  defp split_complete_lines(buffer) when is_binary(buffer) do
    parts = :binary.split(buffer, "\n", [:global])

    case parts do
      [] ->
        {[], ""}

      [_single] ->
        {[], buffer}

      _ ->
        rest = List.last(parts)
        lines = Enum.drop(parts, -1)
        {lines, rest}
    end
  end

  defp fail_all_pending(state, reason) do
    if map_size(state.pending) > 0 do
      Logger.warning(
        event: :codex_fail_pending,
        count: map_size(state.pending),
        reason: inspect(reason)
      )
    end

    Enum.each(state.pending, fn {_id, %{from: from, timer: timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending: %{}}
  end

  defp broadcast_notification(state, method, params, raw_message, raw_line) do
    message = {:codex, :notification, method, params, raw_message, raw_line}
    :ok = Froth.broadcast(state.topic, message)
  end

  defp broadcast_protocol_error(state, reason) do
    message = {:codex, :protocol_error, reason}
    :ok = Froth.broadcast(state.topic, message)
  end

  defp deep_stringify_keys(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), deep_stringify_keys(v)} end)
  end

  defp deep_stringify_keys(value) when is_list(value) do
    Enum.map(value, &deep_stringify_keys/1)
  end

  defp deep_stringify_keys(value), do: value

  defp valid_timeout_ms(ms, _fallback) when is_integer(ms) and ms > 0, do: ms
  defp valid_timeout_ms(_, fallback), do: fallback

  defp resolve_pubsub_topic(server, opts) when is_list(opts) do
    with {:ok, {default_pubsub, default_topic}} <- pubsub_topic(server) do
      pubsub = Keyword.get(opts, :pubsub, default_pubsub)
      topic = Keyword.get(opts, :topic, default_topic)
      {:ok, {pubsub, topic}}
    end
  end

  defp preview(value, limit \\ 500) do
    value
    |> inspect(pretty: false, limit: 40, printable_limit: limit)
    |> String.slice(0, limit)
  end

  defp resolve_executable(opts) do
    Keyword.get(opts, :executable) ||
      System.get_env("CODEX_EXECUTABLE") ||
      System.find_executable("codex") ||
      find_fallback_executable() ||
      "codex"
  end

  defp find_fallback_executable do
    home = System.user_home!()

    [
      Path.join(home, ".bun/bin/codex"),
      Path.join(home, ".local/bin/codex")
    ]
    |> Enum.find(&File.exists?/1)
  end
end
