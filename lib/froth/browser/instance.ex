defmodule Froth.Browser.Instance do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Froth.Browser.CDP
  alias Froth.Browser.Chrome
  alias Froth.Telemetry.Span

  @default_launch_timeout_ms 15_000
  @default_command_timeout_ms 10_000
  @default_navigation_timeout_ms 15_000
  @default_poll_interval_ms 100

  def child_spec(opts) do
    browser_id = Keyword.fetch!(opts, :browser_id)

    %{
      id: {__MODULE__, browser_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  def start_link(opts) when is_list(opts) do
    browser_id = Keyword.fetch!(opts, :browser_id)
    GenServer.start_link(__MODULE__, %{browser_id: browser_id, opts: opts}, name: via(browser_id))
  end

  def await_ready(pid, timeout_ms) when is_pid(pid) and is_integer(timeout_ms) do
    GenServer.call(pid, :await_ready, timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :browser_not_running}
    :exit, reason -> {:error, reason}
  end

  def navigate(pid, url, opts \\ []) when is_pid(pid) and is_binary(url) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_navigation_timeout_ms)
    GenServer.call(pid, {:navigate, url, opts}, timeout_ms + 2_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :browser_not_running}
    :exit, reason -> {:error, reason}
  end

  def eval(pid, expression, opts \\ [])
      when is_pid(pid) and is_binary(expression) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_command_timeout_ms)
    GenServer.call(pid, {:eval, expression, opts}, timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :browser_not_running}
    :exit, reason -> {:error, reason}
  end

  def screenshot(pid, opts \\ []) when is_pid(pid) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_command_timeout_ms)
    GenServer.call(pid, {:screenshot, opts}, timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :browser_not_running}
    :exit, reason -> {:error, reason}
  end

  def click(pid, selector, opts \\ [])
      when is_pid(pid) and is_binary(selector) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_command_timeout_ms)
    GenServer.call(pid, {:click, selector, opts}, timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :browser_not_running}
    :exit, reason -> {:error, reason}
  end

  def type(pid, selector, text, opts \\ [])
      when is_pid(pid) and is_binary(selector) and is_binary(text) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_command_timeout_ms)
    GenServer.call(pid, {:type, selector, text, opts}, timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :browser_not_running}
    :exit, reason -> {:error, reason}
  end

  def set_viewport(pid, opts \\ []) when is_pid(pid) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_command_timeout_ms)
    GenServer.call(pid, {:set_viewport, opts}, timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :browser_not_running}
    :exit, reason -> {:error, reason}
  end

  def set_content(pid, html, opts \\ []) when is_pid(pid) and is_binary(html) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_navigation_timeout_ms)
    GenServer.call(pid, {:set_content, html, opts}, timeout_ms + 2_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :browser_not_running}
    :exit, reason -> {:error, reason}
  end

  def info(pid) when is_pid(pid) do
    GenServer.call(pid, :info)
  catch
    :exit, {:noproc, _} -> {:error, :browser_not_running}
    :exit, reason -> {:error, reason}
  end

  def console_logs(pid) when is_pid(pid) do
    GenServer.call(pid, :console_logs)
  catch
    :exit, {:noproc, _} -> {:error, :browser_not_running}
    :exit, reason -> {:error, reason}
  end

  def release(pid) when is_pid(pid) do
    GenServer.call(pid, :release)
  catch
    :exit, {:noproc, _} -> {:error, :browser_not_running}
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(%{browser_id: browser_id, opts: opts}) do
    Process.flag(:trap_exit, true)

    state = %{
      browser_id: browser_id,
      label: Keyword.get(opts, :label, browser_id),
      status: :starting,
      launch_opts: opts,
      ready_waiters: [],
      browser_port: nil,
      os_pid: nil,
      cdp_pid: nil,
      session_id: nil,
      target_id: nil,
      debug_port: nil,
      websocket_url: nil,
      launch_profile: nil,
      launch_metadata: %{},
      user_data_dir: nil,
      artifact_dir: nil,
      recent_logs: [],
      console_logs: []
    }

    {:ok, state, {:continue, :launch}}
  end

  @impl true
  def handle_continue(:launch, state) do
    case launch_browser(state) do
      {:ok, state} ->
        notify_ready_waiters(state.ready_waiters, :ok)
        {:noreply, %{state | ready_waiters: []}}

      {:error, reason, state} ->
        notify_ready_waiters(state.ready_waiters, {:error, reason})
        {:stop, reason, %{state | ready_waiters: []}}
    end
  end

  @impl true
  def handle_call(:await_ready, from, %{status: :starting} = state) do
    {:noreply, %{state | ready_waiters: [from | state.ready_waiters]}}
  end

  def handle_call(:await_ready, _from, %{status: :ready} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await_ready, _from, state) do
    {:reply, {:error, state.status}, state}
  end

  def handle_call(:info, _from, state) do
    info = %{
      browser_id: state.browser_id,
      label: state.label,
      status: state.status,
      os_pid: state.os_pid,
      debug_port: state.debug_port,
      websocket_url: state.websocket_url,
      launch_profile: state.launch_profile,
      launch_metadata: state.launch_metadata,
      session_id: state.session_id,
      target_id: state.target_id,
      user_data_dir: state.user_data_dir,
      artifact_dir: state.artifact_dir
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:console_logs, _from, state) do
    {:reply, {:ok, Enum.reverse(state.console_logs)}, state}
  end

  def handle_call(:release, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call({:navigate, _url, _opts}, _from, %{status: status} = state)
      when status != :ready do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:navigate, url, opts}, _from, state) do
    case do_navigate(state, url, opts) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:eval, _expression, _opts}, _from, %{status: status} = state)
      when status != :ready do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:eval, expression, opts}, _from, state) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_command_timeout_ms)

    reply =
      with {:ok, result} <- runtime_evaluate(state, expression, timeout_ms),
           {:ok, value} <- extract_runtime_value(result) do
        {:ok, value}
      end

    {:reply, reply, state}
  end

  def handle_call({:screenshot, _opts}, _from, %{status: status} = state) when status != :ready do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:screenshot, opts}, _from, state) do
    reply =
      with {:ok, image_data} <- capture_screenshot(state, opts),
           {:ok, path} <- write_screenshot(state, image_data, opts) do
        Span.execute([:froth, :browser, :session, :screenshot], nil, %{
          browser_id: state.browser_id,
          path: path
        })

        {:ok, path}
      end

    {:reply, reply, state}
  end

  def handle_call({:set_viewport, _opts}, _from, %{status: status} = state)
      when status != :ready do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:set_viewport, opts}, _from, state) do
    reply =
      with {:ok, _} <- do_set_viewport(state, opts) do
        :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:set_content, _html, _opts}, _from, %{status: status} = state)
      when status != :ready do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:set_content, html, opts}, _from, state) do
    reply =
      with {:ok, _} <- runtime_evaluate(state, set_content_script(html), content_timeout(opts)),
           :ok <- wait_for_content_ready(state, opts) do
        :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:click, _selector, _opts}, _from, %{status: status} = state)
      when status != :ready do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:click, selector, opts}, _from, state) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_command_timeout_ms)
    reply = perform_dom_action(state, click_script(selector), timeout_ms)
    {:reply, reply, state}
  end

  def handle_call({:type, _selector, _text, _opts}, _from, %{status: status} = state)
      when status != :ready do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:type, selector, text, opts}, _from, state) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_command_timeout_ms)
    reply = perform_dom_action(state, type_script(selector, text), timeout_ms)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:browser_cdp_connected, cdp_pid}, %{cdp_pid: cdp_pid} = state) do
    {:noreply, state}
  end

  def handle_info({:browser_cdp_event, _cdp_pid, %{"method" => "Runtime.consoleAPICalled"} = event}, state) do
    params = event["params"] || %{}
    type = params["type"] || "log"
    args = params["args"] || []
    text = args |> Enum.map(fn
      %{"value" => v} when is_binary(v) -> v
      %{"value" => v} -> inspect(v)
      %{"description" => d} -> d
      %{"type" => "undefined"} -> "undefined"
      other -> inspect(other)
    end) |> Enum.join(" ")
    entry = %{type: type, text: text, timestamp: System.system_time(:millisecond)}
    {:noreply, %{state | console_logs: [entry | state.console_logs]}}
  end

  def handle_info({:browser_cdp_event, _cdp_pid, %{"method" => "Runtime.exceptionThrown"} = event}, state) do
    params = event["params"] || %{}
    exception = get_in(params, ["exceptionDetails", "exception"]) || %{}
    text = exception["description"] || inspect(params)
    entry = %{type: "exception", text: text, timestamp: System.system_time(:millisecond)}
    {:noreply, %{state | console_logs: [entry | state.console_logs]}}
  end

  def handle_info({:browser_cdp_event, _cdp_pid, _event}, state) do
    {:noreply, state}
  end

  def handle_info({:browser_cdp_error, _cdp_pid, reason}, state) do
    {:stop, {:cdp_error, reason}, state}
  end

  def handle_info({:browser_cdp_closed, _cdp_pid, reason}, state) do
    {:stop, {:cdp_closed, reason}, state}
  end

  def handle_info({port, {:data, data}}, %{browser_port: port} = state) do
    logs =
      state.recent_logs
      |> Kernel.++([String.trim(data)])
      |> Enum.take(-30)

    {:noreply, %{state | recent_logs: logs}}
  end

  def handle_info({port, {:exit_status, code}}, %{browser_port: port} = state) do
    Span.execute([:froth, :browser, :instance, :stopped], nil, %{
      browser_id: state.browser_id,
      exit_code: code
    })

    status = if code == 0, do: :stopped, else: :crashed
    notify_ready_waiters(state.ready_waiters, {:error, status})
    {:stop, {:browser_exit, code}, %{state | status: status, ready_waiters: []}}
  end

  def handle_info({:EXIT, pid, reason}, %{cdp_pid: pid} = state) do
    {:stop, {:cdp_exit, reason}, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.cdp_pid) do
      CDP.close(state.cdp_pid)
    end

    stop_browser_process(state.os_pid)

    if is_port(state.browser_port) do
      try do
        Port.close(state.browser_port)
      rescue
        _ -> :ok
      end
    end

    if is_binary(state.user_data_dir) do
      File.rm_rf(state.user_data_dir)
    end

    :ok
  end

  defp launch_browser(state) do
    config = config()
    launch_timeout_ms = Keyword.get(config, :launch_timeout_ms, @default_launch_timeout_ms)
    command_timeout_ms = Keyword.get(config, :command_timeout_ms, @default_command_timeout_ms)
    launch_profile = launch_profile(state.launch_opts, config)
    launch_metadata = Chrome.profile_metadata(launch_profile)

    with {:ok, executable} <- resolve_executable(state.launch_opts),
         {:ok, user_data_dir, artifact_dir} <- prepare_directories(state.browser_id, config),
         {:ok, browser_port, os_pid} <-
           start_port(executable, user_data_dir, state.launch_opts, launch_profile),
         {:ok, %{port: debug_port}} <-
           wait_for_debug_port(user_data_dir, browser_port, launch_timeout_ms),
         {:ok, websocket_url} <- fetch_websocket_url(debug_port, browser_port, launch_timeout_ms),
         {:ok, cdp_pid} <- CDP.start_link(owner: self(), websocket_url: websocket_url),
         :ok <- CDP.await_connected(cdp_pid, command_timeout_ms),
         {:ok, %{targetId: target_id}} <- create_target(cdp_pid, command_timeout_ms),
         {:ok, %{sessionId: session_id}} <- attach_target(cdp_pid, target_id, command_timeout_ms),
         :ok <- enable_domains(cdp_pid, session_id, command_timeout_ms) do
      Span.execute([:froth, :browser, :instance, :started], nil, %{
        browser_id: state.browser_id,
        os_pid: os_pid,
        debug_port: debug_port,
        profile: launch_profile
      })

      {:ok,
       %{
         state
         | status: :ready,
           browser_port: browser_port,
           os_pid: os_pid,
           cdp_pid: cdp_pid,
           target_id: target_id,
           session_id: session_id,
           debug_port: debug_port,
           websocket_url: websocket_url,
           launch_profile: launch_profile,
           launch_metadata: launch_metadata,
           user_data_dir: user_data_dir,
           artifact_dir: artifact_dir
       }}
    else
      {:error, reason} ->
        {:error, reason, %{state | status: :failed}}
    end
  end

  defp resolve_executable(launch_opts) do
    config = config()
    explicit = Keyword.get(launch_opts, :executable, Keyword.get(config, :executable))
    Chrome.find_executable(explicit: explicit)
  end

  defp prepare_directories(browser_id, config) do
    tmp_root =
      Keyword.get(config, :tmp_dir, Path.expand("tmp/browser"))
      |> Path.expand()

    artifact_root =
      Keyword.get(config, :artifact_dir, Path.expand("tmp/browser-artifacts"))
      |> Path.expand()

    user_data_dir = Path.join(tmp_root, browser_id)
    artifact_dir = Path.join(artifact_root, browser_id)

    with :ok <- File.mkdir_p(user_data_dir),
         :ok <- File.mkdir_p(artifact_dir) do
      {:ok, user_data_dir, artifact_dir}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_port(executable, user_data_dir, launch_opts, launch_profile) do
    args =
      Chrome.launch_args(user_data_dir,
        profile: launch_profile,
        extra_args: Keyword.get(launch_opts, :chrome_args, [])
      )

    port =
      Port.open(
        {:spawn_executable, executable},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:args, args}
        ]
      )

    case Keyword.fetch(Port.info(port), :os_pid) do
      {:ok, os_pid} -> {:ok, port, os_pid}
      :error -> {:error, :missing_os_pid}
    end
  end

  defp wait_for_debug_port(user_data_dir, browser_port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    active_port_path = Path.join(user_data_dir, "DevToolsActivePort")
    wait_for_debug_port_file(active_port_path, browser_port, deadline)
  end

  defp wait_for_debug_port_file(active_port_path, browser_port, deadline) do
    case File.read(active_port_path) do
      {:ok, contents} ->
        Chrome.parse_devtools_active_port(contents)

      {:error, _reason} ->
        cond do
          is_nil(Port.info(browser_port)) ->
            {:error, :browser_exited_during_launch}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error, :devtools_port_timeout}

          true ->
            Process.sleep(50)
            wait_for_debug_port_file(active_port_path, browser_port, deadline)
        end
    end
  end

  defp fetch_websocket_url(debug_port, browser_port, timeout_ms) when is_integer(debug_port) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    url = "http://127.0.0.1:#{debug_port}/json/version"
    wait_for_websocket_url(url, browser_port, deadline)
  end

  defp wait_for_websocket_url(url, browser_port, deadline) do
    case Req.get(url, receive_timeout: 1_000, decode_body: true) do
      {:ok, %{status: 200, body: %{"webSocketDebuggerUrl" => websocket_url}}} ->
        {:ok, websocket_url}

      _ ->
        cond do
          is_nil(Port.info(browser_port)) ->
            {:error, :browser_exited_during_launch}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error, :websocket_url_timeout}

          true ->
            Process.sleep(100)
            wait_for_websocket_url(url, browser_port, deadline)
        end
    end
  end

  defp create_target(cdp_pid, timeout_ms) do
    with {:ok, result} <-
           CDP.command(cdp_pid, "Target.createTarget", %{"url" => "about:blank"},
             timeout_ms: timeout_ms
           ),
         %{"targetId" => target_id} <- result do
      {:ok, %{targetId: target_id}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_target_response}
    end
  end

  defp attach_target(cdp_pid, target_id, timeout_ms) do
    with {:ok, result} <-
           CDP.command(
             cdp_pid,
             "Target.attachToTarget",
             %{"targetId" => target_id, "flatten" => true},
             timeout_ms: timeout_ms
           ),
         %{"sessionId" => session_id} <- result do
      {:ok, %{sessionId: session_id}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_attach_response}
    end
  end

  defp enable_domains(cdp_pid, session_id, timeout_ms) do
    with {:ok, _} <-
           CDP.command(cdp_pid, "Page.enable", %{},
             session_id: session_id,
             timeout_ms: timeout_ms
           ),
         {:ok, _} <-
           CDP.command(cdp_pid, "Runtime.enable", %{},
             session_id: session_id,
             timeout_ms: timeout_ms
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_navigate(state, url, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_navigation_timeout_ms)

    with {:ok, result} <-
           CDP.command(
             state.cdp_pid,
             "Page.navigate",
             %{"url" => url},
             session_id: state.session_id,
             timeout_ms: timeout_ms
           ),
         :ok <- navigation_result(result),
         :ok <- wait_for_ready_state(state, timeout_ms) do
      Span.execute([:froth, :browser, :session, :navigated], nil, %{
        browser_id: state.browser_id,
        url: url
      })

      {:ok, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp do_set_viewport(state, opts) do
    width = Keyword.get(opts, :width, 1080)
    height = Keyword.get(opts, :height, 1920)
    scale = Keyword.get(opts, :device_scale_factor, 1)
    mobile = Keyword.get(opts, :mobile, false)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_command_timeout_ms)

    CDP.command(
      state.cdp_pid,
      "Emulation.setDeviceMetricsOverride",
      %{
        "width" => width,
        "height" => height,
        "deviceScaleFactor" => scale,
        "mobile" => mobile
      },
      session_id: state.session_id,
      timeout_ms: timeout_ms
    )
  end

  defp navigation_result(%{"errorText" => error_text})
       when is_binary(error_text) and error_text != "" do
    {:error, error_text}
  end

  defp navigation_result(_result), do: :ok

  defp wait_for_ready_state(state, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_ready_state(state, deadline)
  end

  defp poll_ready_state(state, deadline) do
    case runtime_evaluate(state, "document.readyState", @default_command_timeout_ms) do
      {:ok, result} ->
        case extract_runtime_value(result) do
          {:ok, "complete"} ->
            :ok

          {:ok, _state} ->
            continue_polling(state, deadline)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_polling(state, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :navigation_timeout}
    else
      Process.sleep(@default_poll_interval_ms)
      poll_ready_state(state, deadline)
    end
  end

  defp wait_for_global(state, expression, opts) do
    if Keyword.get(opts, :wait_for_froth_video, false) do
      deadline =
        System.monotonic_time(:millisecond) +
          Keyword.get(opts, :timeout_ms, @default_navigation_timeout_ms)

      poll_global(state, expression, deadline)
    else
      :ok
    end
  end

  defp wait_for_content_ready(state, opts) do
    if Keyword.get(opts, :wait_for_froth_video, false) do
      wait_for_global(
        state,
        "window.FrothVideo && typeof window.FrothVideo.renderAt === 'function'",
        opts
      )
    else
      wait_for_ready_state(state, Keyword.get(opts, :timeout_ms, @default_navigation_timeout_ms))
    end
  end

  defp poll_global(state, expression, deadline) do
    case runtime_evaluate(state, "!!(#{expression})", @default_command_timeout_ms) do
      {:ok, result} ->
        case extract_runtime_value(result) do
          {:ok, true} -> :ok
          {:ok, false} -> continue_global_polling(state, expression, deadline)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_global_polling(state, expression, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :content_boot_timeout}
    else
      Process.sleep(@default_poll_interval_ms)
      poll_global(state, expression, deadline)
    end
  end

  defp runtime_evaluate(state, expression, timeout_ms) do
    CDP.command(
      state.cdp_pid,
      "Runtime.evaluate",
      %{
        "expression" => expression,
        "awaitPromise" => true,
        "returnByValue" => true
      },
      session_id: state.session_id,
      timeout_ms: timeout_ms
    )
  end

  defp extract_runtime_value(%{"exceptionDetails" => details}) do
    {:error, details["text"] || "javascript_exception"}
  end

  defp extract_runtime_value(%{"result" => %{"value" => value}}), do: {:ok, value}
  defp extract_runtime_value(%{"result" => %{"unserializableValue" => value}}), do: {:ok, value}
  defp extract_runtime_value(%{"result" => %{"description" => value}}), do: {:ok, value}
  defp extract_runtime_value(_result), do: {:error, :invalid_runtime_result}

  defp capture_screenshot(state, opts) do
    full_page? = Keyword.get(opts, :full_page, false)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_command_timeout_ms)

    params =
      if full_page? do
        with {:ok, metrics} <-
               CDP.command(
                 state.cdp_pid,
                 "Page.getLayoutMetrics",
                 %{},
                 session_id: state.session_id,
                 timeout_ms: timeout_ms
               ) do
          build_full_page_screenshot_params(metrics)
        else
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, %{"format" => "png"}}
      end

    with {:ok, params} <- params,
         {:ok, result} <-
           CDP.command(
             state.cdp_pid,
             "Page.captureScreenshot",
             params,
             session_id: state.session_id,
             timeout_ms: timeout_ms
           ),
         %{"data" => image_data} <- result do
      {:ok, image_data}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_screenshot_response}
    end
  end

  defp build_full_page_screenshot_params(%{"contentSize" => content_size}) do
    {:ok,
     %{
       "format" => "png",
       "captureBeyondViewport" => true,
       "clip" => %{
         "x" => 0,
         "y" => 0,
         "width" => max(content_size["width"] || 1, 1),
         "height" => max(content_size["height"] || 1, 1),
         "scale" => 1
       }
     }}
  end

  defp build_full_page_screenshot_params(_metrics), do: {:error, :invalid_layout_metrics}

  defp write_screenshot(state, image_data, opts) do
    path =
      case Keyword.get(opts, :path) do
        nil ->
          filename =
            Keyword.get_lazy(opts, :filename, fn ->
              timestamp = System.system_time(:millisecond)
              "#{state.browser_id}-#{timestamp}.png"
            end)

          Path.join(state.artifact_dir, filename)

        explicit_path ->
          explicit_path
      end

    case Base.decode64(image_data) do
      {:ok, binary} ->
        :ok = File.mkdir_p(Path.dirname(path))

        case File.write(path, binary) do
          :ok -> {:ok, path}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :invalid_base64}
    end
  end

  defp set_content_script(html) do
    html = Jason.encode!(html)

    """
    (() => {
      document.open();
      document.write(#{html});
      document.close();
      return true;
    })()
    """
  end

  defp content_timeout(opts) do
    Keyword.get(opts, :timeout_ms, @default_navigation_timeout_ms)
  end

  defp perform_dom_action(state, script, timeout_ms) do
    with {:ok, result} <- runtime_evaluate(state, script, timeout_ms),
         {:ok, value} <- extract_runtime_value(result) do
      case value do
        %{"ok" => true} -> :ok
        %{"error" => error} -> {:error, error}
        _ -> {:error, :invalid_dom_action_result}
      end
    end
  end

  defp click_script(selector) do
    selector = Jason.encode!(selector)

    """
    (() => {
      const el = document.querySelector(#{selector});
      if (!el) return {ok: false, error: "selector_not_found"};
      el.click();
      return {ok: true};
    })()
    """
  end

  defp type_script(selector, text) do
    selector = Jason.encode!(selector)
    text = Jason.encode!(text)

    """
    (() => {
      const el = document.querySelector(#{selector});
      if (!el) return {ok: false, error: "selector_not_found"};

      if ("value" in el) {
        el.focus();
        el.value = #{text};
        el.dispatchEvent(new Event("input", {bubbles: true}));
        el.dispatchEvent(new Event("change", {bubbles: true}));
      } else {
        el.textContent = #{text};
      }

      return {ok: true};
    })()
    """
  end

  defp stop_browser_process(nil), do: :ok

  defp stop_browser_process(os_pid) when is_integer(os_pid) do
    System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp notify_ready_waiters(waiters, reply) do
    Enum.each(waiters, &GenServer.reply(&1, reply))
  end

  defp via(browser_id) do
    {:via, Registry, {Froth.Browser.Registry, browser_id}}
  end

  defp launch_profile(launch_opts, config) do
    launch_opts
    |> Keyword.get(:profile, Keyword.get(config, :profile))
    |> Chrome.normalize_profile()
  end

  defp config do
    Application.get_env(:froth, Froth.Browser, [])
  end
end
