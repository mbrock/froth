defmodule Froth.Agent.Worker do
  @moduledoc """
  GenServer that executes an agentic cycle: think → act → repeat until done.

  Started with a cycle and config. Runs autonomously until quiescence.
  Delegates all persistence to `Froth.Agent`.
  """

  use GenServer

  alias Froth.Agent
  alias Froth.Agent.{Config, Cycle, ToolResult, ToolUse}
  alias Froth.LLM
  alias Froth.Telemetry.Span

  @default_tool_timeout_ms 30_000

  @type invocation :: %{
          ref: reference(),
          task: Task.t(),
          tool_use: ToolUse.t(),
          timer_ref: reference(),
          started_at: integer(),
          span_id: String.t()
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
          think_start: integer() | nil,
          reply_sent?: boolean(),
          saw_tool_use?: boolean(),
          finalized?: boolean()
        }

  defstruct [
    :config,
    :cycle,
    :head_id,
    :cycle_span_id,
    :cycle_start,
    :think_span_id,
    :think_start,
    phase: :initial,
    reply_sent?: false,
    saw_tool_use?: false,
    finalized?: false
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
    head_id = Agent.latest_head_id(cycle)
    snapshot = Agent.cycle_snapshot_attrs(config)

    span_id =
      Span.start_span([:froth, :agent, :cycle], config.parent_span_id, %{
        cycle_id: cycle.id,
        model: cycle.model || config.model || snapshot[:model],
        provider: cycle.provider || resolved_provider(config) || snapshot[:provider]
      })

    cycle =
      Agent.update_cycle(cycle, %{
        status: :running,
        provider: cycle.provider || resolved_provider(config) || snapshot[:provider],
        model: cycle.model || config.model || snapshot[:model],
        root_span_id: span_id,
        parent_span_id: config.parent_span_id,
        config: snapshot[:config],
        system_prompt_hash: snapshot[:system_prompt_hash],
        system_prompt_ref: snapshot[:system_prompt_ref],
        toolset_hash: snapshot[:toolset_hash],
        usage: cycle.usage || snapshot[:usage],
        cost_usd: cycle.cost_usd || snapshot[:cost_usd],
        started_at: DateTime.utc_now(),
        finished_at: nil,
        error: nil
      })

    Agent.append_event(cycle, %{
      kind: "cycle.started",
      head_id: head_id,
      span_id: span_id,
      parent_span_id: config.parent_span_id,
      data: %{
        "status" => "running",
        "provider" => cycle.provider,
        "model" => cycle.model
      }
    })

    worker = %__MODULE__{
      config: config,
      cycle: cycle,
      head_id: head_id,
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

    response_metadata =
      response
      |> Map.drop([:content, :text])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    worker = emit_think_stop(worker)
    worker = persist_llm_completion(worker, response, response_metadata)
    worker = persist_agent_message(worker, response.content, response_metadata)

    case parse_tool_uses(response.content) do
      [] ->
        worker =
          %{worker | phase: :done}
          |> maybe_emit_silent_stop(response, response_metadata)
          |> finalize_cycle(:completed, :normal, %{
            "stop_reason" => response_metadata["stop_reason"],
            "usage" => response_metadata["usage"] || %{}
          })

        {:stop, :normal, %{worker | phase: :done}}

      tool_uses ->
        maybe_tools_done(start_tools(%{worker | saw_tool_use?: true}, tool_uses))
    end
  end

  def handle_info({ref, {:error, reason}}, %{phase: {:thinking, %{ref: ref}}} = worker) do
    Process.demonitor(ref, [:flush])
    worker = emit_think_stop(worker, %{error: format_reason(reason)})
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
    worker = emit_think_stop(worker, %{error: format_reason(reason)})
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
    cleanup_phase(worker.phase)
    worker = maybe_emit_pending_think_stop(worker, reason)
    worker = maybe_finalize_cycle(worker, reason)

    if worker.cycle_start do
      Span.stop_span(
        [:froth, :agent, :cycle],
        worker.cycle_span_id,
        worker.cycle_start,
        %{reason: normalize_reason(reason), phase: phase_label(worker.phase)}
      )
    end
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
    cycle = Agent.update_cycle(worker.cycle, %{status: :running})

    think_span_id =
      Span.start_span([:froth, :agent, :think], worker.cycle_span_id, %{
        cycle_id: cycle.id,
        head_id: worker.head_id,
        model: cycle.model,
        provider: cycle.provider
      })

    api_messages =
      worker.head_id
      |> Agent.load_messages()
      |> Enum.map(&Froth.Agent.Message.to_llm_message/1)

    Agent.append_event(cycle, %{
      kind: "llm.requested",
      head_id: worker.head_id,
      span_id: think_span_id,
      parent_span_id: worker.cycle_span_id,
      data: %{
        "provider" => cycle.provider,
        "model" => cycle.model,
        "message_count" => length(api_messages),
        "tool_count" => length(worker.config.tools || []),
        "messages" => Enum.map(api_messages, &llm_message_preview/1),
        "tools" => worker.config.tools || []
      }
    })

    cycle_id = cycle.id

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

    %{
      worker
      | cycle: cycle,
        phase: {:thinking, task},
        think_span_id: think_span_id,
        think_start: now
    }
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

  defp persist_llm_completion(worker, response, response_metadata) do
    duration_ms = current_duration_ms(worker.think_start)

    cycle =
      Agent.merge_cycle_usage(worker.cycle, response_metadata["usage"] || %{})

    Agent.append_event(cycle, %{
      kind: "llm.completed",
      head_id: worker.head_id,
      span_id: worker.think_span_id,
      parent_span_id: worker.cycle_span_id,
      data: %{
        "provider" => cycle.provider,
        "model" => cycle.model,
        "duration_ms" => duration_ms,
        "stop_reason" => response_metadata["stop_reason"],
        "usage" => response_metadata["usage"] || %{},
        "response" => %{
          "text" => Map.get(response, :text),
          "content" => Map.get(response, :content),
          "metadata" => response_metadata
        }
      }
    })

    %{worker | cycle: cycle}
  end

  defp parse_tool_uses(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%{"type" => "tool_use"}, &1))
    |> Enum.map(&ToolUse.from_api/1)
  end

  defp parse_tool_uses(_), do: []

  defp start_tools(worker, tool_uses) do
    cycle = Agent.update_cycle(worker.cycle, %{status: :waiting_on_tools})

    context =
      %{cycle_id: cycle.id, head_id: worker.head_id}
      |> Map.merge(worker.config.context || %{})

    tool_timeout_ms = worker.config.tool_timeout_ms || @default_tool_timeout_ms

    invocations =
      Enum.map(tool_uses, fn %ToolUse{id: id} = tool_use ->
        started_at = System.monotonic_time()
        span_id = generate_span_id()
        emit_tool_started_event(%{worker | cycle: cycle}, tool_use, span_id)

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
          started_at: started_at,
          span_id: span_id
        }
      end)

    %{worker | cycle: cycle, phase: {:working, invocations, [], MapSet.new()}}
  end

  defp collect_tool_result(
         %{phase: {:working, invocations, results, ignored_refs}} = worker,
         tool_use_id,
         result
       ) do
    tool_result =
      case result do
        {:yield, reason} ->
          ToolResult.new(tool_use_id, format_yield_reason(reason),
            yield?: true,
            control_outcome: "yield",
            control_data: %{"reason" => format_reason(reason)}
          )

        {:ok, content} ->
          ToolResult.new(tool_use_id, content)

        {:error, content} ->
          ToolResult.new(tool_use_id, content,
            is_error: true,
            control_outcome: "tool_error",
            control_data: %{"error" => format_reason(content)}
          )

        content ->
          ToolResult.new(tool_use_id, content)
      end

    %{worker | phase: {:working, invocations, [tool_result | results], ignored_refs}}
  end

  defp maybe_tools_done(%{phase: {:working, [], results, _ignored_refs}} = worker) do
    has_yield = Enum.any?(results, &(&1.control_outcome == "yield"))
    api_results = results |> Enum.reverse() |> Enum.map(&ToolResult.to_api/1)
    worker = persist_message(worker, :user, api_results)

    if has_yield do
      worker =
        Enum.reduce(results, %{worker | phase: :done}, fn
          %ToolResult{control_outcome: "yield", control_data: data, tool_use_id: tool_use_id},
          acc ->
            emit_control_outcome(acc, "yield", Map.put(data || %{}, "tool_use_id", tool_use_id),
              span_id: acc.cycle_span_id,
              parent_span_id: acc.cycle_span_id
            )

          _result, acc ->
            acc
        end)
        |> finalize_cycle(:completed, :normal, %{"control_outcome" => "yield"})

      {:stop, :normal, %{worker | phase: :done}}
    else
      cycle = Agent.update_cycle(worker.cycle, %{status: :running})
      {:noreply, %{worker | cycle: cycle, phase: :continuing}, {:continue, :think}}
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

  defp emit_tool_started_event(worker, %ToolUse{} = tool_use, span_id) do
    Span.execute(
      [:froth, :agent, :tool, :started],
      worker.cycle_span_id,
      Map.put(tool_event_meta(worker, tool_use), :span_id, span_id)
    )

    Agent.append_event(worker.cycle, %{
      kind: "tool.started",
      head_id: worker.head_id,
      span_id: span_id,
      parent_span_id: worker.cycle_span_id,
      tool_use_id: tool_use.id,
      data: tool_event_data(worker, tool_use)
    })

    worker
  end

  defp emit_tool_result_event(worker, invocation, {:error, reason}) do
    emit_tool_failed_event(worker, invocation, format_tool_error(reason))
  end

  defp emit_tool_result_event(worker, invocation, result) do
    duration_ms = tool_duration_ms(invocation)

    Span.execute(
      [:froth, :agent, :tool, :completed],
      worker.cycle_span_id,
      Map.put(
        tool_event_meta(worker, invocation.tool_use, %{result_type: tool_result_type(result)}),
        :span_id,
        invocation.span_id
      ),
      %{duration: tool_duration(invocation)}
    )

    Agent.append_event(worker.cycle, %{
      kind: "tool.completed",
      head_id: worker.head_id,
      span_id: invocation.span_id,
      parent_span_id: worker.cycle_span_id,
      tool_use_id: invocation.tool_use.id,
      data:
        tool_event_data(worker, invocation.tool_use, %{
          "duration_ms" => duration_ms,
          "result_type" => tool_result_type(result),
          "result" => normalize_tool_event_result(result)
        })
    })

    if invocation.tool_use.name == "send_message" and tool_succeeded?(result) do
      worker =
        emit_control_outcome(
          %{worker | reply_sent?: true},
          "reply_sent",
          %{
            "tool_name" => invocation.tool_use.name,
            "tool_use_id" => invocation.tool_use.id
          },
          span_id: invocation.span_id,
          parent_span_id: worker.cycle_span_id
        )

      %{worker | reply_sent?: true}
    else
      worker
    end
  end

  defp emit_tool_failed_event(worker, invocation, reason) do
    duration_ms = tool_duration_ms(invocation)

    Span.execute(
      [:froth, :agent, :tool, :failed],
      worker.cycle_span_id,
      Map.put(
        tool_event_meta(worker, invocation.tool_use, %{error: truncate_tool_detail(reason)}),
        :span_id,
        invocation.span_id
      ),
      %{duration: tool_duration(invocation)}
    )

    worker =
      emit_control_outcome(
        worker,
        "tool_error",
        %{
          "tool_name" => invocation.tool_use.name,
          "tool_use_id" => invocation.tool_use.id,
          "error" => format_tool_error(reason)
        },
        span_id: invocation.span_id,
        parent_span_id: worker.cycle_span_id
      )

    Agent.append_event(worker.cycle, %{
      kind: "tool.failed",
      head_id: worker.head_id,
      span_id: invocation.span_id,
      parent_span_id: worker.cycle_span_id,
      tool_use_id: invocation.tool_use.id,
      data:
        tool_event_data(worker, invocation.tool_use, %{
          "duration_ms" => duration_ms,
          "error" => format_tool_error(reason)
        })
    })

    worker
  end

  defp emit_tool_timed_out_event(worker, invocation) do
    timeout_ms = worker.config.tool_timeout_ms || @default_tool_timeout_ms
    duration_ms = tool_duration_ms(invocation)

    Span.execute(
      [:froth, :agent, :tool, :timed_out],
      worker.cycle_span_id,
      Map.put(
        tool_event_meta(worker, invocation.tool_use, %{timeout_ms: timeout_ms}),
        :span_id,
        invocation.span_id
      ),
      %{duration: tool_duration(invocation)}
    )

    worker =
      emit_control_outcome(
        worker,
        "tool_error",
        %{
          "tool_name" => invocation.tool_use.name,
          "tool_use_id" => invocation.tool_use.id,
          "error" => timeout_error(timeout_ms)
        },
        span_id: invocation.span_id,
        parent_span_id: worker.cycle_span_id
      )

    Agent.append_event(worker.cycle, %{
      kind: "tool.timed_out",
      head_id: worker.head_id,
      span_id: invocation.span_id,
      parent_span_id: worker.cycle_span_id,
      tool_use_id: invocation.tool_use.id,
      data:
        tool_event_data(worker, invocation.tool_use, %{
          "duration_ms" => duration_ms,
          "timeout_ms" => timeout_ms,
          "error" => timeout_error(timeout_ms)
        })
    })

    worker
  end

  defp emit_control_outcome(worker, outcome, data, opts \\ []) do
    Agent.append_event(worker.cycle, %{
      kind: "control.outcome",
      head_id: worker.head_id,
      span_id: Keyword.get(opts, :span_id, worker.cycle_span_id),
      parent_span_id: Keyword.get(opts, :parent_span_id, worker.cycle_span_id),
      tool_use_id: data["tool_use_id"],
      data: Map.put(stringify_map(data), "outcome", outcome)
    })

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

  defp tool_event_data(worker, %ToolUse{} = tool_use, extra \\ %{}) do
    Map.merge(
      %{
        "cycle_id" => worker.cycle.id,
        "head_id" => worker.head_id,
        "tool_name" => tool_use.name,
        "tool_use_id" => tool_use.id,
        "input" => tool_use.input,
        "input_keys" => tool_input_keys(tool_use.input)
      },
      stringify_map(extra)
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

  defp tool_duration_ms(%{started_at: started_at}) when is_integer(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp tool_duration_ms(_invocation), do: 0

  defp current_duration_ms(started_at) when is_integer(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp current_duration_ms(_started_at), do: 0

  defp tool_result_type({:ok, content}), do: tool_result_type(content)
  defp tool_result_type({:yield, _reason}), do: "yield"
  defp tool_result_type(content) when is_binary(content), do: "text"
  defp tool_result_type(content) when is_list(content), do: "blocks"
  defp tool_result_type(content) when is_map(content), do: "map"
  defp tool_result_type(content) when is_atom(content), do: Atom.to_string(content)
  defp tool_result_type(_content), do: "value"

  defp normalize_tool_event_result({:ok, content}), do: content
  defp normalize_tool_event_result({:yield, reason}), do: %{"yield" => format_reason(reason)}
  defp normalize_tool_event_result({:error, reason}), do: %{"error" => format_reason(reason)}
  defp normalize_tool_event_result(content), do: content

  defp tool_succeeded?({:error, _reason}), do: false
  defp tool_succeeded?(_result), do: true

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

  defp maybe_emit_silent_stop(worker, response, metadata) do
    if worker.reply_sent? or assistant_visible_reply?(response) do
      worker
    else
      detail =
        if worker.saw_tool_use? do
          "assistant stopped without sending a reply after tool execution#{stop_reason_suffix(metadata)}"
        else
          "assistant produced no reply content#{stop_reason_suffix(metadata)}"
        end

      emit_control_outcome(
        worker,
        "assistant_stopped_without_reply",
        %{"detail" => detail},
        span_id: worker.think_span_id,
        parent_span_id: worker.cycle_span_id
      )
    end
  end

  defp assistant_visible_reply?(response) when is_map(response) do
    text = Map.get(response, :text) || Map.get(response, "text")
    content = Map.get(response, :content) || Map.get(response, "content")

    cond do
      is_binary(text) and String.trim(text) != "" ->
        true

      is_list(content) ->
        Enum.any?(content, &assistant_output_block?/1)

      true ->
        false
    end
  end

  defp assistant_visible_reply?(_response), do: false

  defp assistant_output_block?(%{"type" => "tool_use"}), do: false
  defp assistant_output_block?(%{"type" => "thinking"}), do: false

  defp assistant_output_block?(%{"type" => "text", "text" => text}) when is_binary(text) do
    String.trim(text) != ""
  end

  defp assistant_output_block?(%{"text" => text}) when is_binary(text) do
    String.trim(text) != ""
  end

  defp assistant_output_block?(%{"type" => _type}), do: true
  defp assistant_output_block?(_block), do: false

  defp stop_reason_suffix(metadata) do
    case metadata["stop_reason"] do
      value when is_binary(value) and value != "" -> " (stop_reason=#{value})"
      _ -> ""
    end
  end

  defp maybe_emit_pending_think_stop(worker, reason) do
    if worker.think_start do
      emit_think_stop(worker, %{error: format_reason(reason)})
    else
      worker
    end
  end

  defp maybe_finalize_cycle(%{finalized?: true} = worker, _reason), do: worker

  defp maybe_finalize_cycle(worker, reason) do
    cond do
      cancelled_reason?(reason) ->
        finalize_cycle(worker, :cancelled, reason, %{})

      reason == :normal and phase_done?(worker.phase) ->
        finalize_cycle(worker, :completed, reason, %{})

      true ->
        error = format_reason(reason)

        worker
        |> emit_control_outcome("cycle_error", %{"error" => error})
        |> finalize_cycle(:failed, reason, %{"error" => error})
    end
  end

  defp finalize_cycle(worker, status, reason, extra) do
    cycle =
      Agent.update_cycle(worker.cycle, %{
        status: status,
        finished_at: DateTime.utc_now(),
        error: cycle_error_for(status, reason, extra)
      })

    kind =
      case status do
        :completed -> "cycle.completed"
        :failed -> "cycle.failed"
        :cancelled -> "cycle.cancelled"
      end

    Agent.append_event(cycle, %{
      kind: kind,
      head_id: worker.head_id,
      span_id: worker.cycle_span_id,
      parent_span_id: cycle.parent_span_id,
      data:
        Map.merge(
          %{
            "reason" => normalize_reason(reason),
            "phase" => phase_label(worker.phase),
            "reply_sent" => worker.reply_sent?
          },
          stringify_map(extra)
        )
    })

    %{worker | cycle: cycle, finalized?: true}
  end

  defp cycle_error_for(:failed, _reason, extra), do: extra["error"] || extra[:error]
  defp cycle_error_for(_status, _reason, _extra), do: nil

  defp phase_done?(:done), do: true
  defp phase_done?(_phase), do: false

  defp phase_label(:initial), do: "initial"
  defp phase_label(:continuing), do: "continuing"
  defp phase_label(:done), do: "done"
  defp phase_label({:thinking, _task}), do: "thinking"
  defp phase_label({:working, _invocations, _results, _ignored_refs}), do: "working"
  defp phase_label(other), do: inspect(other)

  defp cancelled_reason?(:shutdown), do: true
  defp cancelled_reason?({:shutdown, :cancelled}), do: true
  defp cancelled_reason?({:shutdown, _reason}), do: true
  defp cancelled_reason?(_reason), do: false

  defp cleanup_phase({:thinking, task}) do
    if is_pid(task.pid), do: Process.exit(task.pid, :kill)
  end

  defp cleanup_phase({:working, invocations, _results, _ignored_refs}) do
    Enum.each(invocations, fn invocation ->
      if is_reference(invocation.timer_ref), do: Process.cancel_timer(invocation.timer_ref)
      if is_pid(invocation.task.pid), do: Process.exit(invocation.task.pid, :kill)
    end)
  end

  defp cleanup_phase(_phase), do: :ok

  defp llm_message_preview(%{role: role, content: content}) do
    %{
      "role" => to_string(role),
      "content" => summarize_value(content)
    }
  end

  defp llm_message_preview(other), do: %{"message" => inspect(other)}

  defp summarize_value(value) when is_list(value) do
    Enum.map(value, &summarize_value/1)
  end

  defp summarize_value(value) when is_map(value) do
    Map.new(value, fn {key, inner} ->
      {to_string(key), summarize_value(inner)}
    end)
  end

  defp summarize_value(value) when is_binary(value) do
    if String.valid?(value) do
      if String.length(value) > 240 do
        String.slice(value, 0, 240) <> "..."
      else
        value
      end
    else
      inspect(value, limit: 20, printable_limit: 240)
    end
  end

  defp summarize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp summarize_value(value), do: value

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value

  defp generate_span_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

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

  defp normalize_reason(:normal), do: "normal"
  defp normalize_reason(:shutdown), do: "shutdown"
  defp normalize_reason({:shutdown, reason}), do: "shutdown:#{format_reason(reason)}"
  defp normalize_reason({:error, reason}), do: format_reason(reason)
  defp normalize_reason(other), do: format_reason(other)

  defp format_reason(value) when is_binary(value), do: value
  defp format_reason(value) when is_atom(value), do: Atom.to_string(value)
  defp format_reason(value), do: inspect(value)

  defp resolved_provider(%Config{} = config) do
    cond do
      is_atom(config.provider) and config.provider in [:anthropic, :openai, :grok, :gemini] ->
        Atom.to_string(config.provider)

      is_binary(config.provider) and String.trim(config.provider) != "" ->
        String.trim(config.provider)

      true ->
        config.model
        |> LLM.provider_name_for_model()
        |> case do
          nil -> nil
          provider -> Atom.to_string(provider)
        end
    end
  end
end
