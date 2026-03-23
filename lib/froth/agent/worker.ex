defmodule Froth.Agent.Worker do
  @moduledoc """
  GenServer that executes an agentic cycle: think → act → repeat until done.

  Started with a cycle and config. Runs autonomously until quiescence.
  Delegates all persistence to `Froth.Agent`.
  """

  use GenServer

  alias Froth.Agent
  alias Froth.Agent.{Config, Cycle, Message, ToolUse, ToolResult}
  alias Froth.LLM
  alias Froth.Telemetry.Span

  @default_tool_timeout_ms 30_000

  @type invocation :: %{
          ref: reference(),
          task: Task.t(),
          tool_use: ToolUse.t(),
          timer_ref: reference(),
          started_at: integer()
        }
  @type phase ::
          :initial
          | :continuing
          | :done
          | {:thinking, Task.t()}
          | {:working, [invocation()], [ToolResult.t()], MapSet.t(reference())}

  @type t :: %__MODULE__{
          config: Config.t(),
          phase: phase(),
          cycle: Cycle.t(),
          head_id: String.t() | nil,
          cycle_span_id: String.t() | nil,
          cycle_start: integer() | nil,
          think_span_id: String.t() | nil,
          think_start: integer() | nil
        }

  defstruct [
    :config,
    :cycle,
    :head_id,
    :cycle_span_id,
    :cycle_start,
    :think_span_id,
    :think_start,
    phase: :initial
  ]

  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary
    }
  end

  def start_link({%Cycle{} = cycle, %Config{} = config}) do
    GenServer.start_link(__MODULE__, {cycle, config})
  end

  @impl true
  def init({cycle, config}) do
    now = System.monotonic_time()

    span_id =
      Span.start_span([:froth, :agent, :cycle], nil, %{
        cycle_id: cycle.id,
        model: config.model,
        provider: config.provider || LLM.provider_name_for_model(config.model)
      })

    worker = %__MODULE__{
      config: config,
      cycle: cycle,
      head_id: Agent.latest_head_id(cycle),
      cycle_span_id: span_id,
      cycle_start: now
    }

    {:ok, worker, {:continue, :think}}
  end

  @impl true
  def handle_continue(:think, worker) do
    {:noreply, start_thinking(worker)}
  end

  @impl true
  def handle_info({ref, {:ok, response}}, %{phase: {:thinking, %{ref: ref}}} = worker) do
    Process.demonitor(ref, [:flush])
    worker = emit_think_stop(worker)

    response_metadata =
      response
      |> Map.drop([:content, :text])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    worker = persist_agent_message(worker, response.content, response_metadata)

    case parse_tool_uses(response.content) do
      [] ->
        {:stop, :normal, %{worker | phase: :done}}

      tool_uses ->
        maybe_tools_done(start_tools(worker, tool_uses))
    end
  end

  def handle_info({ref, {:error, reason}}, %{phase: {:thinking, %{ref: ref}}} = worker) do
    Process.demonitor(ref, [:flush])
    worker = emit_think_stop(worker, %{error: reason})
    {:stop, {:error, reason}, worker}
  end

  def handle_info(
        {ref, {:tool_result, tool_use_id, result}},
        %{phase: {:working, invocations, _, ignored_refs}} = worker
      ) do
    case find_invocation_in_list(invocations, ref) do
      %{tool_use: %ToolUse{id: ^tool_use_id}} = invocation ->
        worker = emit_tool_result_event(worker, invocation, result)

        worker
        |> cancel_invocation_timer(invocation)
        |> forget_invocation(invocation, MapSet.put(ignored_refs, ref))
        |> collect_tool_result(tool_use_id, result)
        |> maybe_tools_done()

      nil ->
        {:noreply, worker}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, :normal},
        %{phase: {:thinking, %{ref: ref}}} = worker
      ) do
    {:noreply, worker}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{phase: {:thinking, %{ref: ref}}} = worker
      ) do
    worker = emit_think_stop(worker, %{error: reason})
    {:stop, {:error, reason}, worker}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, :normal},
        %{phase: {:working, _invocations, _results, ignored_refs}} = worker
      ) do
    if MapSet.member?(ignored_refs, ref) do
      {:noreply, worker}
    else
      {:noreply, worker}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{phase: {:working, _invocations, _results, ignored_refs}} = worker
      ) do
    cond do
      MapSet.member?(ignored_refs, ref) ->
        {:noreply, worker}

      invocation = find_invocation(worker.phase, ref) ->
        tool_use_id = invocation.tool_use.id
        error = "tool task failed: #{Exception.format_exit(reason)}"
        worker = emit_tool_failed_event(worker, invocation, error)

        worker
        |> cancel_invocation_timer(invocation)
        |> forget_invocation(invocation, MapSet.put(ignored_refs, ref))
        |> collect_tool_result(tool_use_id, {:error, error})
        |> maybe_tools_done()

      true ->
        {:noreply, worker}
    end
  end

  def handle_info(
        {:tool_timeout, ref},
        %{phase: {:working, _invocations, _results, ignored_refs}} = worker
      ) do
    cond do
      MapSet.member?(ignored_refs, ref) ->
        {:noreply, worker}

      invocation = find_invocation(worker.phase, ref) ->
        Process.exit(invocation.task.pid, :kill)
        worker = emit_tool_timed_out_event(worker, invocation)

        worker
        |> forget_invocation(invocation, MapSet.put(ignored_refs, ref))
        |> collect_tool_result(
          invocation.tool_use.id,
          {:error, timeout_error(worker.config.tool_timeout_ms || @default_tool_timeout_ms)}
        )
        |> maybe_tools_done()

      true ->
        {:noreply, worker}
    end
  end

  def handle_info(_message, worker), do: {:noreply, worker}

  @impl true
  def terminate(reason, worker) do
    Span.stop_span(
      [:froth, :agent, :cycle],
      worker.cycle_span_id,
      worker.cycle_start,
      %{reason: normalize_reason(reason), phase: worker.phase}
    )
  end

  defp persist_message(worker, role, content) do
    {_msg, head_id} = Agent.append_message(worker.cycle, worker.head_id, role, content)
    %{worker | head_id: head_id}
  end

  defp persist_agent_message(worker, content, metadata) do
    {_msg, head_id} =
      Agent.append_message(worker.cycle, worker.head_id, :agent, content, metadata)

    %{worker | head_id: head_id}
  end

  defp start_thinking(worker) do
    now = System.monotonic_time()
    think_span_id = Span.start_span([:froth, :agent, :think], worker.cycle_span_id, %{})

    api_messages =
      worker.head_id
      |> Agent.load_messages()
      |> Enum.map(&Message.to_llm_message/1)

    cycle_id = worker.cycle.id

    opts =
      [
        system: worker.config.system || "",
        provider: worker.config.provider,
        model: worker.config.model,
        tools: worker.config.tools,
        thinking: worker.config.thinking,
        effort: worker.config.effort,
        parent_id: think_span_id
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    task =
      Task.Supervisor.async_nolink(Froth.Agent.TaskSupervisor, fn ->
        LLM.stream_single(
          api_messages,
          fn event -> Froth.broadcast("cycle:#{cycle_id}", {:stream, event}) end,
          opts
        )
      end)

    %{worker | phase: {:thinking, task}, think_span_id: think_span_id, think_start: now}
  end

  defp emit_think_stop(worker, extra_meta \\ %{}) do
    if worker.think_start do
      Span.stop_span(
        [:froth, :agent, :think],
        worker.think_span_id,
        worker.think_start,
        extra_meta
      )
    end

    %{worker | think_start: nil, think_span_id: nil}
  end

  defp parse_tool_uses(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%{"type" => "tool_use"}, &1))
    |> Enum.map(&ToolUse.from_api/1)
  end

  defp parse_tool_uses(_), do: []

  defp start_tools(worker, tool_uses) do
    context =
      %{cycle_id: worker.cycle.id, head_id: worker.head_id}
      |> Map.merge(worker.config.context || %{})

    tool_timeout_ms = worker.config.tool_timeout_ms || @default_tool_timeout_ms

    invocations =
      Enum.map(tool_uses, fn %ToolUse{id: id} = tool_use ->
        started_at = System.monotonic_time()
        emit_tool_started_event(worker, tool_use)

        task =
          Task.Supervisor.async_nolink(Froth.Agent.TaskSupervisor, fn ->
            result = execute_tool(worker.config.tool_executor, tool_use, context)
            {:tool_result, id, result}
          end)

        %{
          ref: task.ref,
          task: task,
          tool_use: tool_use,
          timer_ref: Process.send_after(self(), {:tool_timeout, task.ref}, tool_timeout_ms),
          started_at: started_at
        }
      end)

    %{worker | phase: {:working, invocations, [], MapSet.new()}}
  end

  defp collect_tool_result(
         %{phase: {:working, invocations, results, ignored_refs}} = worker,
         tool_use_id,
         result
       ) do
    tool_result =
      case result do
        {:yield, reason} ->
          ToolResult.new(tool_use_id, format_yield_reason(reason), yield?: true)

        {:ok, content} ->
          ToolResult.new(tool_use_id, content)

        {:error, content} ->
          ToolResult.new(tool_use_id, content, is_error: true)

        content ->
          ToolResult.new(tool_use_id, content)
      end

    %{worker | phase: {:working, invocations, [tool_result | results], ignored_refs}}
  end

  defp maybe_tools_done(%{phase: {:working, [], results, _ignored_refs}} = worker) do
    has_yield = Enum.any?(results, & &1.yield?)
    api_results = results |> Enum.reverse() |> Enum.map(&ToolResult.to_api/1)
    worker = persist_message(worker, :user, api_results)

    if has_yield do
      {:stop, :normal, %{worker | phase: :done}}
    else
      {:noreply, %{worker | phase: :continuing}, {:continue, :think}}
    end
  end

  defp maybe_tools_done(worker), do: {:noreply, worker}

  defp format_yield_reason(reason) when is_binary(reason), do: "Yielding: #{reason}"

  defp format_yield_reason(reason),
    do: "Yielding: #{inspect(reason, limit: :infinity, printable_limit: :infinity)}"

  defp find_invocation({:working, invocations, _results, _ignored_refs}, ref) do
    find_invocation_in_list(invocations, ref)
  end

  defp find_invocation(_, _), do: nil

  defp find_invocation_in_list(invocations, ref) when is_list(invocations) do
    Enum.find(invocations, &(&1.ref == ref))
  end

  defp cancel_invocation_timer(worker, %{timer_ref: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    worker
  end

  defp cancel_invocation_timer(worker, _invocation), do: worker

  defp forget_invocation(
         %{phase: {:working, invocations, results, _ignored_refs}} = worker,
         invocation,
         ignored_refs
       ) do
    remaining = Enum.reject(invocations, &(&1.ref == invocation.ref))
    %{worker | phase: {:working, remaining, results, ignored_refs}}
  end

  defp timeout_error(tool_timeout_ms) when is_integer(tool_timeout_ms) and tool_timeout_ms > 0 do
    "tool timed out after #{tool_timeout_ms}ms"
  end

  defp emit_tool_started_event(worker, %ToolUse{} = tool_use) do
    Span.execute(
      [:froth, :agent, :tool, :started],
      worker.cycle_span_id,
      tool_event_meta(worker, tool_use)
    )

    worker
  end

  defp emit_tool_result_event(worker, invocation, {:error, reason}) do
    emit_tool_failed_event(worker, invocation, format_tool_error(reason))
  end

  defp emit_tool_result_event(worker, invocation, result) do
    Span.execute(
      [:froth, :agent, :tool, :completed],
      worker.cycle_span_id,
      tool_event_meta(worker, invocation.tool_use, %{result_type: tool_result_type(result)}),
      %{duration: tool_duration(invocation)}
    )

    worker
  end

  defp emit_tool_failed_event(worker, invocation, reason) do
    Span.execute(
      [:froth, :agent, :tool, :failed],
      worker.cycle_span_id,
      tool_event_meta(worker, invocation.tool_use, %{error: truncate_tool_detail(reason)}),
      %{duration: tool_duration(invocation)}
    )

    worker
  end

  defp emit_tool_timed_out_event(worker, invocation) do
    timeout_ms = worker.config.tool_timeout_ms || @default_tool_timeout_ms

    Span.execute(
      [:froth, :agent, :tool, :timed_out],
      worker.cycle_span_id,
      tool_event_meta(worker, invocation.tool_use, %{timeout_ms: timeout_ms}),
      %{duration: tool_duration(invocation)}
    )

    worker
  end

  defp tool_event_meta(worker, %ToolUse{} = tool_use, extra_meta \\ %{}) do
    Map.merge(
      %{
        cycle_id: worker.cycle.id,
        head_id: worker.head_id,
        tool_use_id: tool_use.id,
        tool_name: tool_use.name,
        input_keys: tool_input_keys(tool_use.input)
      },
      extra_meta
    )
  end

  defp tool_input_keys(input) when is_map(input) do
    input
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp tool_input_keys(_), do: []

  defp tool_duration(%{started_at: started_at}) when is_integer(started_at) do
    System.monotonic_time() - started_at
  end

  defp tool_duration(_), do: 0

  defp tool_result_type({:ok, content}), do: tool_result_type(content)
  defp tool_result_type(content) when is_binary(content), do: :text
  defp tool_result_type(content) when is_list(content), do: :blocks
  defp tool_result_type(content) when is_map(content), do: :map
  defp tool_result_type(content) when is_atom(content), do: content
  defp tool_result_type(_content), do: :value

  defp format_tool_error(reason) when is_binary(reason), do: reason
  defp format_tool_error(reason), do: inspect(reason)

  defp truncate_tool_detail(detail) when is_binary(detail) do
    if String.length(detail) > 240 do
      String.slice(detail, 0, 240) <> "..."
    else
      detail
    end
  end

  defp truncate_tool_detail(detail), do: detail

  defp execute_tool(tool_executor, %ToolUse{} = tool_use, context) do
    case GenServer.call(tool_executor, {:prepare_tool, tool_use, context}, :infinity) do
      {:ok, prepared} ->
        outcome = run_prepared_tool(prepared)

        GenServer.call(
          tool_executor,
          {:commit_tool, tool_use, context, prepared, outcome},
          :infinity
        )

      {:error, :unsupported} ->
        GenServer.call(tool_executor, {:execute, tool_use, context}, :infinity)

      {:error, "unsupported"} ->
        GenServer.call(tool_executor, {:execute, tool_use, context}, :infinity)

      {:error, _} = error ->
        error

      other ->
        other
    end
  end

  defp run_prepared_tool(%{execute: {module, function, args}})
       when is_atom(module) and is_atom(function) and is_list(args) do
    apply(module, function, args)
  end

  defp run_prepared_tool(_prepared), do: {:error, "invalid prepared tool"}

  defp normalize_reason(:normal), do: :normal
  defp normalize_reason(:shutdown), do: :shutdown
  defp normalize_reason({:shutdown, _}), do: :shutdown
  defp normalize_reason({:error, reason}), do: {:error, reason}
  defp normalize_reason(other), do: {:error, other}
end
