defmodule Froth.LogTranslator do
  @moduledoc """
  Log translator for OTP reports.
  Progress/lifecycle reports → compact. Crashes → readable with stacktraces.
  """

  @behaviour Logger.Translator

  @impl true
  def translate(_min_level, _level, :report, {:logger, %{label: label} = report}) do
    case label do
      {:gen_server, :terminate} -> genserver_terminate(report)
      {:gen_event, :terminate} -> gen_event_terminate(report)
      {:gen_statem, :terminate} -> gen_statem_terminate(report)
      _ -> :skip
    end
  end

  def translate(min_level, _level, :report, {{:proc_lib, :crash}, data}) do
    crash_report(min_level, data)
  end

  def translate(_min_level, _level, :report, {{:supervisor, :progress}, data}) do
    supervisor_progress(data)
  end

  def translate(_min_level, _level, :report, {{:supervisor, _}, data}) do
    supervisor_error(data)
  end

  def translate(
        _min_level,
        _level,
        :report,
        {{:application_controller, :progress}, [application: app, started_at: node]}
      ) do
    {:ok, "app #{app} started at #{inspect(node)}"}
  end

  def translate(
        _min_level,
        _level,
        :report,
        {{:application_controller, :exit}, [application: app, exited: reason, type: _type]}
      ) do
    {:ok, "app #{app} exited: #{Exception.format_exit(reason)}"}
  end

  def translate(
        _min_level,
        :info,
        :report,
        {:std_info, [application: app, exited: reason, type: _type]}
      ) do
    {:ok, "app #{app} exited: #{Exception.format_exit(reason)}"}
  end

  def translate(
        _min_level,
        :error,
        :report,
        {{Task.Supervisor, :terminating},
         %{name: name, starter: starter, function: function, reason: reason}}
      ) do
    {reason, _} = format_reason(reason)

    msg = [
      "Task #{inspect(name)} started from #{inspect(starter)} terminating\n",
      "  function: #{inspect(function)}\n",
      "  ",
      format_exit_readable(reason)
    ]

    {:ok, msg, [crash_reason: reason] ++ registered_name(name)}
  end

  def translate(min_level, :error, :report, {{:error_logger, :error_report}, data}),
    do: translate(min_level, :error, :report, {{:supervisor, :error}, data})

  def translate(min_level, :error, :report, {:supervisor_report, data}),
    do: translate(min_level, :error, :report, {{:supervisor, :error}, data})

  def translate(min_level, :error, :report, {:crash_report, data}),
    do: translate(min_level, :error, :report, {{:proc_lib, :crash}, data})

  def translate(_min_level, :info, :report, {:progress, [{:supervisor, _} | _] = data}),
    do: supervisor_progress(data)

  def translate(_min_level, :info, :report, {:progress, [application: app, started_at: node]}),
    do: {:ok, "app #{app} started at #{inspect(node)}"}

  def translate(_min_level, _level, _kind, _message), do: :none

  ## Supervisor progress — compact

  defp supervisor_progress(supervisor: sup, started: [{:pid, pid}, {:id, id} | _]) do
    {:ok, "#{sup_name(sup)} started #{inspect(id)} as #{inspect(pid)}"}
  end

  defp supervisor_progress(supervisor: sup, started: [{:pid, pid} | _]) do
    {:ok, "#{sup_name(sup)} started #{inspect(pid)}"}
  end

  defp supervisor_progress(_), do: :none

  ## Supervisor error — one line with reason

  defp supervisor_error(
         supervisor: sup,
         errorContext: ctx,
         reason: reason,
         offender: [{:pid, pid}, {:id, id} | _]
       ) do
    {:ok,
     "#{sup_name(sup)} child #{inspect(id)} (#{inspect(pid)}) #{sup_context(ctx)}: #{Exception.format_exit(reason)}"}
  end

  defp supervisor_error(
         supervisor: sup,
         errorContext: ctx,
         reason: reason,
         offender: [{:nb_children, n}, {:id, id} | _]
       ) do
    {:ok,
     "#{sup_name(sup)} #{n} children #{inspect(id)} #{sup_context(ctx)}: #{Exception.format_exit(reason)}"}
  end

  defp supervisor_error(
         supervisor: sup,
         errorContext: ctx,
         reason: reason,
         offender: [{:pid, pid} | _]
       ) do
    {:ok,
     "#{sup_name(sup)} child #{inspect(pid)} #{sup_context(ctx)}: #{Exception.format_exit(reason)}"}
  end

  defp supervisor_error(_), do: :none

  ## GenServer terminate — readable

  defp genserver_terminate(
         %{name: name, reason: reason, last_message: last, state: state} = report
       ) do
    {reason, stack} = format_reason(reason)
    metadata = [crash_reason: reason] ++ registered_name(name)

    label_line =
      case report do
        %{process_label: l} when l != :undefined -> ["  label: #{inspect(l)}\n"]
        _ -> []
      end

    msg = [
      "GenServer #{inspect(name)} terminating\n",
      format_exit_readable(reason, stack),
      label_line,
      "  last message: #{inspect(last, pretty: true, width: 80, limit: 10)}\n",
      "  state: #{inspect(state, pretty: true, width: 80, limit: 5)}"
    ]

    {:ok, msg, metadata}
  end

  ## GenEvent terminate

  defp gen_event_terminate(%{handler: handler, name: name, reason: reason}) do
    reason =
      case reason do
        {:EXIT, why} -> why
        _ -> reason
      end

    {reason, stack} = format_reason(reason)
    metadata = [crash_reason: reason] ++ registered_name(name)

    msg = [
      ":gen_event #{inspect(handler)} in #{inspect(name)} terminating\n",
      format_exit_readable(reason, stack)
    ]

    {:ok, msg, metadata}
  end

  ## GenStatem terminate

  defp gen_statem_terminate(%{name: name, reason: {kind, reason, stack}}) do
    {reason, stack} = exit_reason(kind, reason, stack)
    {reason, stack} = format_reason({reason, stack})
    metadata = [crash_reason: reason] ++ registered_name(name)

    msg = [
      ":gen_statem #{inspect(name)} terminating\n",
      format_exit_readable(reason, stack)
    ]

    {:ok, msg, metadata}
  end

  ## Crash report — readable

  defp crash_report(min_level, [[{:initial_call, _} | _] = crashed, linked]) do
    do_crash_report(min_level, crashed, linked)
  end

  defp crash_report(min_level, [crashed, linked]) do
    do_crash_report(min_level, crashed, linked)
  end

  defp crash_report(_, _), do: :none

  defp do_crash_report(_min_level, crashed, _linked) do
    {pid, crashed} = Keyword.pop_first(crashed, :pid)
    {name, crashed} = Keyword.pop_first(crashed, :registered_name)
    {{kind, reason, stack}, _} = Keyword.pop_first(crashed, :error_info)

    reason = Exception.normalize(kind, reason, stack)
    metadata = [{:crash_reason, exit_reason(kind, reason, stack)} | registered_name(name)]

    msg = [
      "Process #{crash_name(pid, name)} terminating\n",
      "  ",
      Exception.format_banner(kind, reason, stack),
      "\n",
      format_stacktrace(stack)
    ]

    {:ok, msg, metadata}
  end

  ## Formatting helpers

  defp format_exit_readable(reason), do: format_exit_readable(reason, [])

  defp format_exit_readable(reason, stack) when is_list(stack) and stack != [] do
    ["  ", Exception.format_banner(:error, reason, stack), "\n", format_stacktrace(stack)]
  end

  defp format_exit_readable({reason, stack}, _) when is_list(stack) and stack != [] do
    ["  ", Exception.format_banner(:error, reason, stack), "\n", format_stacktrace(stack)]
  end

  defp format_exit_readable(reason, _) do
    ["  reason: ", Exception.format_exit(reason)]
  end

  defp format_stacktrace([]), do: []

  defp format_stacktrace(stack) do
    Enum.map(stack, fn entry ->
      ["    ", Exception.format_stacktrace_entry(entry), "\n"]
    end)
  end

  defp sup_name({:local, name}), do: inspect(name)
  defp sup_name({:global, name}), do: inspect(name)
  defp sup_name({:via, _mod, name}), do: inspect(name)
  defp sup_name({pid, mod}), do: "#{inspect(mod)} (#{inspect(pid)})"
  defp sup_name(other), do: inspect(other)

  defp sup_context(:start_error), do: "failed to start"
  defp sup_context(:child_terminated), do: "terminated"
  defp sup_context(:shutdown), do: "caused shutdown"
  defp sup_context(:shutdown_error), do: "shutdown error"

  defp crash_name(pid, []), do: inspect(pid)
  defp crash_name(pid, name), do: "#{inspect(name)} (#{inspect(pid)})"

  defp registered_name(name) when is_atom(name), do: [registered_name: name]
  defp registered_name(_), do: []

  defp format_reason({maybe_exception, [_ | _] = maybe_stacktrace} = reason) do
    try do
      Enum.each(maybe_stacktrace, &Exception.format_stacktrace_entry/1)
    catch
      :error, _ -> {reason, []}
    else
      _ ->
        reason =
          if is_exception(maybe_exception) do
            maybe_exception
          else
            case Exception.normalize(:error, maybe_exception, maybe_stacktrace) do
              %ErlangError{} -> maybe_exception
              exception -> exception
            end
          end

        {reason, maybe_stacktrace}
    end
  end

  defp format_reason(reason), do: {reason, []}

  defp exit_reason(:exit, reason, stack), do: {reason, stack}
  defp exit_reason(:error, reason, stack), do: {reason, stack}
  defp exit_reason(:throw, value, stack), do: {{:nocatch, value}, stack}
end
