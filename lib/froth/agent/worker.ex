defmodule Froth.Agent.Worker do
  @moduledoc """
  GenServer that executes an agentic cycle: think → act → repeat until done.

  Started with a cycle and config. Runs autonomously until quiescence.
  Delegates all persistence to `Froth.Agent`.
  """

  use GenServer
  require Logger

  alias Froth.Agent
  alias Froth.Agent.{Config, Cycle, TaskBridge, ToolResult, ToolUse}
  alias Froth.ApiKeys
  alias Span
  alias LLM

  @default_tool_timeout_ms 30_000
  @default_tool_timeout_overrides %{}
  @utf8_replacement <<0xEF, 0xBF, 0xBD>>

  @type invocation :: %{
          ref: reference(),
          task: Task.t(),
          tool_use: ToolUse.t(),
          timer_ref: reference(),
          timeout_ms: pos_integer(),
          started_at: integer(),
          span_id: String.t()
        }
  @type batch :: %{
          invocations: [invocation()],
          order: [String.t()],
          results: %{optional(String.t()) => ToolResult.t()},
          ignored_refs: MapSet.t(reference())
        }
  @type phase ::
          :initial
          | :continuing
          | :done
          | {:thinking, Task.t()}
          | {:working, batch()}
          | {:awaiting_user_input, batch()}

  @type t :: %__MODULE__{
          config: Config.t(),
          phase: phase(),
          cycle: Cycle.t(),
          head_id: String.t() | nil,
          seq: non_neg_integer(),
          cycle_span_id: String.t() | nil,
          cycle_start: integer() | nil,
          think_span_id: String.t() | nil,
          think_start: integer() | nil,
          reply_sent?: boolean(),
          saw_tool_use?: boolean(),
          finalized?: boolean(),
          pending_ask_resolutions: %{
            optional(String.t()) => pending_ask_resolution()
          }
        }

  @type pending_ask_resolution ::
          {:tool_result, ToolResult.t()}
          | {:stop, term()}

  defstruct [
    :config,
    :cycle,
    :head_id,
    :seq,
    :cycle_span_id,
    :cycle_start,
    :think_span_id,
    :think_start,
    phase: :initial,
    reply_sent?: false,
    saw_tool_use?: false,
    finalized?: false,
    pending_ask_resolutions: %{}
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

  def resolve_pending_ask(pid, pending_ask_id, resolution)
      when is_pid(pid) and is_binary(pending_ask_id) do
    GenServer.call(
      pid,
      {:resolve_pending_ask, pending_ask_id, resolution},
      :infinity
    )
  end

  @impl true
  def init({cycle, config}) do
    Froth.Repo.allow(config.tool_executor, "worker")

    now = System.monotonic_time()
    head_id = Agent.latest_head_id(cycle)
    seq = Agent.next_event_seq(cycle)
    snapshot = Agent.cycle_snapshot_attrs(config)

    span_id =
      Span.start_span([:froth, :agent, :cycle], config.parent_span_id, %{
        cycle_id: cycle.id,
        model: cycle.model || config.model || snapshot[:model],
        provider:
          cycle.provider || resolved_provider(config) || snapshot[:provider]
      })

    cycle =
      Agent.update_cycle(cycle, %{
        status: :running,
        provider:
          cycle.provider || resolved_provider(config) || snapshot[:provider],
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

    worker =
      %__MODULE__{
        config: config,
        cycle: cycle,
        head_id: head_id,
        seq: seq,
        cycle_span_id: span_id,
        cycle_start: now
      }
      |> append_event(%{
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

    {:ok, worker, {:continue, :think}}
  end

  @impl true
  def handle_continue(:think, worker) do
    {:noreply, start_thinking(worker)}
  end

  @impl true
  def handle_call(
        {:resolve_pending_ask, pending_ask_id, resolution},
        _from,
        worker
      ) do
    with {:ok, resolution} <- normalize_pending_ask_resolution(resolution) do
      case resolve_pending_ask_in_worker(worker, pending_ask_id, resolution) do
        {:stop, reason, worker} ->
          {:stop, reason, :ok, worker}

        {:ok, worker} ->
          reply_for_batch_transition(worker)
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, worker}
    end
  end

  @impl true
  def handle_info(
        {ref, {:ok, response}},
        %{phase: {:thinking, %{ref: ref}}} = worker
      ) do
    Process.demonitor(ref, [:flush])
    response_diagnostics = response_diagnostics(response)

    response_metadata =
      response
      |> Map.drop([:content, :text, :diagnostics])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> maybe_put_stream_diagnostics(response_diagnostics)

    worker = emit_think_stop(worker)
    worker = persist_llm_completion(worker, response, response_metadata)

    worker =
      persist_agent_message(worker, response.content, response_metadata)

    tool_uses = parse_tool_uses(response.content)

    cond do
      tool_uses != [] ->
        maybe_tools_done(
          start_tools(%{worker | saw_tool_use?: true}, tool_uses)
        )

      true ->
        worker =
          %{worker | phase: :done}
          |> maybe_emit_silent_stop(
            response,
            response_metadata,
            response_diagnostics
          )
          |> finalize_cycle(:completed, :normal, %{
            "stop_reason" => response_metadata["stop_reason"],
            "usage" => response_metadata["usage"] || %{}
          })

        {:stop, :normal, %{worker | phase: :done}}
    end
  end

  def handle_info(
        {ref, {:error, reason}},
        %{phase: {:thinking, %{ref: ref}}} = worker
      ) do
    Process.demonitor(ref, [:flush])
    log_llm_error(worker, reason)
    worker = emit_think_stop(worker, %{error: format_reason(reason)})
    {:stop, {:error, reason}, worker}
  end

  def handle_info(
        {ref, {:tool_result, tool_use_id, result}},
        %{
          phase:
            {:working,
             %{invocations: invocations, ignored_refs: ignored_refs}}
        } = worker
      ) do
    case find_invocation_in_list(invocations, ref) do
      %{tool_use: %ToolUse{id: ^tool_use_id}} = invocation ->
        # Materialize first so detection sees the original bytes
        # (otherwise the UTF-8 fixup in sanitize_utf8/1 would clobber
        # invalid sequences in, e.g., a shell-dumped PNG before the
        # block layer ever got to recognize it as binary). After
        # materialize, binary-shaped blocks have body: nil and all
        # text-shaped blocks carry JSON-safe text, so sanitize is
        # effectively only doing its job on non-block tool results
        # (error strings, await data, yield reasons).
        result =
          result |> materialize_result_blocks() |> sanitize_tool_result()

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
        %{phase: {:working, %{ignored_refs: ignored_refs}}} = worker
      ) do
    if MapSet.member?(ignored_refs, ref) do
      {:noreply, worker}
    else
      {:noreply, worker}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{phase: {:working, %{ignored_refs: ignored_refs}}} = worker
      ) do
    cond do
      MapSet.member?(ignored_refs, ref) ->
        {:noreply, worker}

      invocation = find_invocation(worker.phase, ref) ->
        tool_use_id = invocation.tool_use.id
        Logger.error("tool task failed: #{Exception.format_exit(reason)}")
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
        %{phase: {:working, %{ignored_refs: ignored_refs}}} = worker
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
          {:error, timeout_error(invocation.timeout_ms)}
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
    append_message(worker, role, content)
  end

  defp persist_agent_message(worker, content, metadata) do
    append_message(worker, :agent, content, metadata)
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

    raw_messages =
      worker.head_id
      |> Agent.load_messages()

    {request_messages, previous_response_id} =
      llm_request_messages(cycle.provider, raw_messages)

    api_messages =
      Enum.map(request_messages, &Froth.Agent.Message.to_llm_message/1)

    worker =
      %{worker | cycle: cycle}
      |> append_event(%{
        kind: "llm.requested",
        head_id: worker.head_id,
        span_id: think_span_id,
        parent_span_id: worker.cycle_span_id,
        data: %{
          "provider" => cycle.provider,
          "model" => cycle.model,
          "message_count" => length(api_messages),
          "tool_count" => length(worker.config.tools || []),
          "previous_response_id" => previous_response_id,
          "messages" => Enum.map(api_messages, &llm_message_preview/1),
          "tools" => worker.config.tools || []
        }
      })

    cycle_id = cycle.id

    provider =
      worker.config.provider ||
        LLM.resolve_provider_name(nil, worker.config.model)

    opts =
      [
        api_key: ApiKeys.active_key_for_provider(provider),
        system: worker.config.system || "",
        provider: provider,
        model: worker.config.model,
        max_tokens: worker.config.max_tokens,
        tools: worker.config.tools,
        thinking: worker.config.thinking,
        effort: worker.config.effort,
        reasoning_summary: worker.config.reasoning_summary,
        parent_id: think_span_id,
        previous_response_id: previous_response_id
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    task =
      Task.Supervisor.async_nolink(Froth.Agent.TaskSupervisor, fn ->
        LLM.stream_single(
          api_messages,
          fn event ->
            Froth.broadcast("cycle:#{cycle_id}", {:stream, event})
          end,
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

    %{worker | cycle: cycle}
    |> append_event(%{
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

    {invocations, worker} =
      Enum.map_reduce(tool_uses, %{worker | cycle: cycle}, fn %ToolUse{id: id} =
                                                                tool_use,
                                                              worker ->
        started_at = System.monotonic_time()
        span_id = generate_span_id()
        timeout_ms = tool_timeout_ms(worker.config, tool_use)
        worker = emit_tool_started_event(worker, tool_use, span_id)
        parent = self()

        task =
          Task.Supervisor.async_nolink(Froth.Agent.TaskSupervisor, fn ->
            Froth.Repo.allow(parent, "tool task")

            result =
              execute_tool(worker.config.tool_executor, tool_use, context)

            {:tool_result, id, result}
          end)

        invocation = %{
          ref: task.ref,
          task: task,
          tool_use: tool_use,
          timer_ref:
            Process.send_after(self(), {:tool_timeout, task.ref}, timeout_ms),
          timeout_ms: timeout_ms,
          started_at: started_at,
          span_id: span_id
        }

        {invocation, worker}
      end)

    batch = %{
      invocations: invocations,
      order: Enum.map(tool_uses, & &1.id),
      results: %{},
      ignored_refs: MapSet.new()
    }

    %{worker | cycle: cycle, phase: {:working, batch}}
  end

  defp collect_tool_result(
         %{phase: {phase_name, batch}} = worker,
         tool_use_id,
         result
       )
       when phase_name in [:working, :awaiting_user_input] do
    tool_result = tool_result_from_execution(tool_use_id, result)

    {worker, tool_result} =
      maybe_apply_pending_resolution(worker, tool_result)

    batch = put_in(batch.results[tool_use_id], tool_result)
    %{worker | phase: {phase_name, batch}}
  end

  defp maybe_tools_done(worker) do
    case batch_transition(worker) do
      {:noreply, worker} ->
        {:noreply, worker}

      {:continue, worker} ->
        {:noreply, worker, {:continue, :think}}

      {:stop, reason, worker} ->
        {:stop, reason, worker}
    end
  end

  defp reply_for_batch_transition(worker) do
    case batch_transition(worker) do
      {:noreply, worker} ->
        {:reply, :ok, worker}

      {:continue, worker} ->
        {:reply, :ok, worker, {:continue, :think}}

      {:stop, reason, worker} ->
        {:stop, reason, :ok, worker}
    end
  end

  defp resolve_pending_ask_in_worker(worker, _pending_ask_id, {:stop, reason}) do
    {:stop, reason, worker}
  end

  defp resolve_pending_ask_in_worker(
         %{phase: phase} = worker,
         pending_ask_id,
         resolution
       )
       when is_binary(pending_ask_id) do
    case resolve_pending_ask_in_phase(phase, pending_ask_id, resolution) do
      {:ok, phase} ->
        {:ok, %{worker | phase: phase}}

      :not_found ->
        {:ok,
         store_pending_ask_resolution(worker, pending_ask_id, resolution)}
    end
  end

  defp resolve_pending_ask_in_phase(
         {phase_name, batch},
         pending_ask_id,
         {:tool_result, tool_result}
       )
       when phase_name in [:working, :awaiting_user_input] do
    case find_pending_tool_use_id(batch, pending_ask_id) do
      tool_use_id when is_binary(tool_use_id) ->
        updated_tool_result = %{tool_result | tool_use_id: tool_use_id}

        {:ok,
         {phase_name, put_in(batch.results[tool_use_id], updated_tool_result)}}

      _ ->
        :not_found
    end
  end

  defp resolve_pending_ask_in_phase(_phase, _pending_ask_id, _resolution),
    do: :not_found

  defp normalize_pending_ask_resolution(
         {:tool_result, %ToolResult{} = tool_result}
       ) do
    {:ok, {:tool_result, tool_result}}
  end

  defp normalize_pending_ask_resolution({:stop, reason}),
    do: {:ok, {:stop, reason}}

  defp normalize_pending_ask_resolution(_resolution),
    do: {:error, :invalid_pending_ask_resolution}

  defp store_pending_ask_resolution(worker, pending_ask_id, resolution)
       when is_binary(pending_ask_id) do
    put_in(worker.pending_ask_resolutions[pending_ask_id], resolution)
  end

  defp maybe_apply_pending_resolution(worker, %ToolResult{} = tool_result) do
    case pending_ask_id_for_result(tool_result) do
      pending_ask_id when is_binary(pending_ask_id) ->
        case Map.pop(worker.pending_ask_resolutions, pending_ask_id) do
          {{:tool_result, %ToolResult{} = resolved_tool_result},
           pending_ask_resolutions} ->
            {%{worker | pending_ask_resolutions: pending_ask_resolutions},
             %{resolved_tool_result | tool_use_id: tool_result.tool_use_id}}

          {nil, _pending_ask_resolutions} ->
            {worker, tool_result}

          {_other, pending_ask_resolutions} ->
            {%{worker | pending_ask_resolutions: pending_ask_resolutions},
             tool_result}
        end

      _ ->
        {worker, tool_result}
    end
  end

  defp pending_ask_id_for_result(%ToolResult{control_data: control_data})
       when is_map(control_data) do
    control_data["pending_ask_id"]
  end

  defp pending_ask_id_for_result(_tool_result), do: nil

  defp batch_transition(
         %{phase: {phase_name, %{invocations: []} = batch}} = worker
       )
       when phase_name in [:working, :awaiting_user_input] do
    results = ordered_results(batch)
    has_yield = Enum.any?(results, &(&1.control_outcome == "yield"))
    unresolved = Enum.filter(results, &await_user_input_result?/1)

    cond do
      has_yield ->
        worker =
          worker
          |> persist_batch_results(results)
          |> then(fn worker ->
            Enum.reduce(results, %{worker | phase: :done}, fn
              %ToolResult{
                control_outcome: "yield",
                control_data: data,
                tool_use_id: tool_use_id
              },
              acc ->
                emit_control_outcome(
                  acc,
                  "yield",
                  Map.put(data || %{}, "tool_use_id", tool_use_id),
                  span_id: acc.cycle_span_id,
                  parent_span_id: acc.cycle_span_id
                )

              _result, acc ->
                acc
            end)
          end)
          |> finalize_cycle(:completed, :normal, %{
            "control_outcome" => "yield"
          })

        {:stop, :normal, %{worker | phase: :done}}

      unresolved != [] ->
        worker =
          if phase_name == :working do
            Enum.reduce(unresolved, worker, fn
              %ToolResult{control_data: data, tool_use_id: tool_use_id},
              acc ->
                emit_control_outcome(
                  acc,
                  "await_user_input",
                  Map.put(data || %{}, "tool_use_id", tool_use_id),
                  span_id: acc.cycle_span_id,
                  parent_span_id: acc.cycle_span_id
                )
            end)
          else
            worker
          end

        cycle =
          Agent.update_cycle(worker.cycle, %{
            status: :awaiting_user_input,
            finished_at: nil
          })

        {:noreply,
         %{worker | cycle: cycle, phase: {:awaiting_user_input, batch}}}

      true ->
        worker = persist_batch_results(worker, results)
        cycle = Agent.update_cycle(worker.cycle, %{status: :running})
        {:continue, %{worker | cycle: cycle, phase: :continuing}}
    end
  end

  defp batch_transition(worker), do: {:noreply, worker}

  defp ordered_results(%{order: order, results: results})
       when is_list(order) and is_map(results) do
    Enum.flat_map(order, fn tool_use_id ->
      case Map.fetch(results, tool_use_id) do
        {:ok, %ToolResult{} = result} -> [result]
        _ -> []
      end
    end)
  end

  defp ordered_results(_batch), do: []

  defp persist_batch_results(worker, results) when is_list(results) do
    api_results =
      results
      |> Enum.reject(&await_user_input_result?/1)
      |> Enum.map(&ToolResult.to_api/1)

    if api_results == [] do
      worker
    else
      persist_message(worker, :user, api_results)
    end
  end

  defp find_pending_tool_use_id(%{results: results}, pending_ask_id)
       when is_map(results) and is_binary(pending_ask_id) do
    Enum.find_value(results, fn {tool_use_id, result} ->
      if pending_ask_id_for_result(result) == pending_ask_id,
        do: tool_use_id,
        else: nil
    end)
  end

  defp find_pending_tool_use_id(_batch, _pending_ask_id), do: nil

  defp tool_result_from_execution(tool_use_id, result) do
    case result do
      {:await, %{} = data} ->
        ToolResult.new(tool_use_id, nil,
          control_outcome: "await_user_input",
          control_data:
            data
            |> stringify_map()
            |> Map.put_new("reason", await_reason(data))
        )

      {:await, reason} ->
        ToolResult.new(tool_use_id, nil,
          control_outcome: "await_user_input",
          control_data: %{"reason" => format_reason(reason)}
        )

      {:yield, reason} ->
        ToolResult.new(tool_use_id, format_yield_reason(reason),
          yield?: true,
          control_outcome: "yield",
          control_data: %{"reason" => format_reason(reason)}
        )

      {:ok, content} ->
        ToolResult.new(tool_use_id, materialize_if_blocks(content))

      {:error, content} ->
        materialized = materialize_if_blocks(content)

        ToolResult.new(tool_use_id, materialized,
          is_error: true,
          control_outcome: "tool_error",
          control_data: %{"error" => format_reason(materialized)}
        )

      content ->
        ToolResult.new(tool_use_id, materialize_if_blocks(content))
    end
  end

  # Block lists are the new canonical tool-output shape. Materialize
  # once right here — blob creation, head/tail precompute — so
  # downstream uses (API rendering, event persistence, trace view)
  # all see the same shape and we don't re-blob on every call.
  defp materialize_if_blocks([%Froth.Context.Block{} | _] = blocks),
    do: Froth.Context.Blocks.materialize(blocks)

  defp materialize_if_blocks(other), do: other

  # Lift materialization over the tool-result control tuple so both
  # event persistence and `collect_tool_result` observe the same
  # blob-backed shape. Binary block bodies (images, PDFs, etc.) are
  # externalized to blobs here, which keeps raw bytes — and, in
  # particular, NUL bytes that Postgres refuses inside JSON text —
  # out of the event row we persist a few lines later.
  defp materialize_result_blocks({:ok, content}),
    do: {:ok, materialize_if_blocks(content)}

  defp materialize_result_blocks({:error, content}),
    do: {:error, materialize_if_blocks(content)}

  defp materialize_result_blocks(other), do: other

  defp format_yield_reason(reason) when is_binary(reason),
    do: "Yielding: #{reason}"

  defp format_yield_reason(reason),
    do:
      "Yielding: #{inspect(reason, limit: :infinity, printable_limit: :infinity)}"

  defp await_reason(%{"reason" => reason})
       when is_binary(reason) and reason != "", do: reason

  defp await_reason(%{reason: reason})
       when is_binary(reason) and reason != "", do: reason

  defp await_reason(_data), do: "Waiting for user input."

  defp sanitize_tool_result({:ok, content}), do: {:ok, sanitize_utf8(content)}

  defp sanitize_tool_result({:error, reason}),
    do: {:error, sanitize_utf8(reason)}

  defp sanitize_tool_result({:await, data}), do: {:await, sanitize_utf8(data)}

  defp sanitize_tool_result({:yield, reason}),
    do: {:yield, sanitize_utf8(reason)}

  defp sanitize_tool_result(result), do: sanitize_utf8(result)

  # JSON-text safety for values bound for JSONB persistence. Fix up
  # invalid UTF-8 sequences (replace with U+FFFD) and strip any NUL
  # bytes, which Postgres refuses inside JSON text even though NUL is
  # legal UTF-8. Block bodies are *not* passed through here — by the
  # time sanitize runs the blocks have already been materialized, so
  # binary-shaped block bodies are nil and text-shaped block bodies
  # were gated through `Froth.Context.Blocks.json_text_safe?/1`.
  defp sanitize_utf8(value) when is_binary(value) do
    value
    |> ensure_valid_utf8()
    |> strip_nul()
  end

  defp sanitize_utf8(value) when is_list(value),
    do: Enum.map(value, &sanitize_utf8/1)

  defp sanitize_utf8(%Froth.Context.Block{} = block) do
    %Froth.Context.Block{
      block
      | attrs: Enum.map(block.attrs, fn {k, v} -> {k, sanitize_utf8(v)} end),
        children: Enum.map(block.children, &sanitize_utf8/1)
    }
  end

  defp sanitize_utf8(value) when is_map(value) do
    Map.new(value, fn {key, inner} ->
      {sanitize_utf8(key), sanitize_utf8(inner)}
    end)
  end

  defp sanitize_utf8(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&sanitize_utf8/1)
    |> List.to_tuple()
  end

  defp sanitize_utf8(value), do: value

  defp ensure_valid_utf8(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      String.replace_invalid(value, @utf8_replacement)
    end
  end

  defp strip_nul(value) when is_binary(value) do
    if String.contains?(value, <<0>>),
      do: String.replace(value, <<0>>, ""),
      else: value
  end

  defp find_invocation({:working, %{invocations: invocations}}, ref) do
    find_invocation_in_list(invocations, ref)
  end

  defp find_invocation(_, _), do: nil

  defp find_invocation_in_list(invocations, ref) when is_list(invocations) do
    Enum.find(invocations, &(&1.ref == ref))
  end

  defp cancel_invocation_timer(worker, %{timer_ref: timer_ref})
       when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    worker
  end

  defp cancel_invocation_timer(worker, _invocation), do: worker

  defp forget_invocation(
         %{phase: {:working, batch}} = worker,
         invocation,
         ignored_refs
       ) do
    batch =
      batch
      |> Map.update!(
        :invocations,
        &Enum.reject(&1, fn current -> current.ref == invocation.ref end)
      )
      |> Map.put(:ignored_refs, ignored_refs)

    %{worker | phase: {:working, batch}}
  end

  defp timeout_error(tool_timeout_ms)
       when is_integer(tool_timeout_ms) and tool_timeout_ms > 0 do
    "tool timed out after #{tool_timeout_ms}ms"
  end

  defp tool_timeout_ms(%Config{} = config, %ToolUse{name: name})
       when is_binary(name) do
    cond do
      is_integer(config.tool_timeout_ms) and config.tool_timeout_ms > 0 ->
        config.tool_timeout_ms

      is_integer(Map.get(tool_timeout_overrides(), name)) ->
        Map.fetch!(tool_timeout_overrides(), name)

      true ->
        @default_tool_timeout_ms
    end
  end

  defp tool_timeout_ms(%Config{} = config, _tool_use) do
    config.tool_timeout_ms || @default_tool_timeout_ms
  end

  defp tool_timeout_overrides do
    Application.get_env(
      :froth,
      :tool_timeout_overrides,
      @default_tool_timeout_overrides
    )
  end

  defp emit_tool_started_event(worker, %ToolUse{} = tool_use, span_id) do
    append_event(worker, %{
      kind: "tool.started",
      head_id: worker.head_id,
      span_id: span_id,
      parent_span_id: worker.cycle_span_id,
      tool_use_id: tool_use.id,
      data: tool_event_data(worker, tool_use)
    })
  end

  defp emit_tool_result_event(worker, invocation, {:error, reason}) do
    emit_tool_failed_event(worker, invocation, format_tool_error(reason))
  end

  defp emit_tool_result_event(worker, invocation, result) do
    duration_ms = tool_duration_ms(invocation)

    worker =
      append_event(worker, %{
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
    else
      worker
    end
  end

  defp emit_tool_failed_event(worker, invocation, reason) do
    duration_ms = tool_duration_ms(invocation)

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

    append_event(worker, %{
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
  end

  defp emit_tool_timed_out_event(worker, invocation) do
    timeout_ms = invocation.timeout_ms
    duration_ms = tool_duration_ms(invocation)

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

    append_event(worker, %{
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
  end

  defp emit_control_outcome(worker, outcome, data, opts \\ []) do
    span_id = Keyword.get(opts, :span_id, worker.cycle_span_id)
    parent_span_id = Keyword.get(opts, :parent_span_id, worker.cycle_span_id)

    append_event(worker, %{
      kind: "control.outcome",
      head_id: worker.head_id,
      span_id: span_id,
      parent_span_id: parent_span_id,
      tool_use_id: data["tool_use_id"],
      data: Map.put(stringify_map(data), "outcome", outcome)
    })
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

  defp tool_duration_ms(%{started_at: started_at})
       when is_integer(started_at) do
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
  defp tool_result_type({:await, _data}), do: "await"
  defp tool_result_type({:yield, _reason}), do: "yield"
  defp tool_result_type(content) when is_binary(content), do: "text"
  defp tool_result_type(content) when is_list(content), do: "blocks"
  defp tool_result_type(content) when is_map(content), do: "map"

  defp tool_result_type(content) when is_atom(content),
    do: Atom.to_string(content)

  defp tool_result_type(_content), do: "value"

  defp normalize_tool_event_result(
         {:ok, [%Froth.Context.Block{} | _] = blocks}
       ),
       do: %{"blocks" => Enum.map(blocks, &Froth.Context.Block.to_map/1)}

  defp normalize_tool_event_result({:ok, content}), do: content

  defp normalize_tool_event_result({:await, data}),
    do: %{"await" => summarize_value(data)}

  defp normalize_tool_event_result({:yield, reason}),
    do: %{"yield" => format_reason(reason)}

  defp normalize_tool_event_result({:error, reason}),
    do: %{"error" => format_reason(reason)}

  defp normalize_tool_event_result([%Froth.Context.Block{} | _] = blocks),
    do: %{"blocks" => Enum.map(blocks, &Froth.Context.Block.to_map/1)}

  defp normalize_tool_event_result(content), do: content

  defp tool_succeeded?({:error, _reason}), do: false
  defp tool_succeeded?(_result), do: true

  defp format_tool_error(reason) when is_binary(reason), do: reason
  defp format_tool_error(reason), do: inspect(reason)

  defp maybe_emit_silent_stop(worker, response, metadata, diagnostics) do
    if worker.reply_sent? or assistant_visible_reply?(response) do
      worker
    else
      log_empty_llm_response(worker, response, metadata, diagnostics)

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

  defp llm_request_messages(provider, messages)
       when provider in ["openai", "fakeai"] and is_list(messages) do
    case latest_openai_response_boundary(messages) do
      {response_id, tail_messages}
      when is_binary(response_id) and response_id != "" and
             is_list(tail_messages) and
             tail_messages != [] ->
        {tail_messages, response_id}

      _ ->
        {messages, nil}
    end
  end

  defp llm_request_messages(_provider, messages) when is_list(messages),
    do: {messages, nil}

  defp latest_openai_response_boundary(messages) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {%Froth.Agent.Message{role: :agent, metadata: metadata}, index}, _acc ->
        case openai_response_id(metadata) do
          response_id when is_binary(response_id) and response_id != "" ->
            {response_id, index}

          _ ->
            nil
        end

      _, acc ->
        acc
    end)
    |> case do
      {response_id, index} ->
        {response_id, Enum.drop(messages, index + 1)}

      nil ->
        nil
    end
  end

  defp openai_response_id(metadata) when is_map(metadata) do
    metadata["response_id"] || metadata[:response_id] ||
      response_id_from_message_id(metadata)
  end

  defp openai_response_id(_metadata), do: nil

  defp response_id_from_message_id(metadata) when is_map(metadata) do
    case metadata["message_id"] || metadata[:message_id] do
      "resp_" <> _rest = response_id -> response_id
      _ -> nil
    end
  end

  defp response_id_from_message_id(_metadata), do: nil

  defp assistant_output_block?(%{"type" => type})
       when type in ["tool_use", "tool_result", "thinking"],
       do: false

  defp assistant_output_block?(%{"type" => "text", "text" => text})
       when is_binary(text) do
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

  defp response_diagnostics(response) when is_map(response) do
    case Map.get(response, :diagnostics) || Map.get(response, "diagnostics") do
      %{} = diagnostics -> diagnostics
      _ -> %{}
    end
  end

  defp response_diagnostics(_response), do: %{}

  defp maybe_put_stream_diagnostics(metadata, diagnostics)
       when is_map(metadata) do
    case stream_diagnostics_summary(diagnostics) do
      %{} = summary when map_size(summary) > 0 ->
        Map.put(metadata, "stream_diagnostics", summary)

      _ ->
        metadata
    end
  end

  defp stream_diagnostics_summary(diagnostics) when is_map(diagnostics) do
    %{}
    |> maybe_put_summary_value(
      "raw_event_count",
      diagnostics[:raw_event_count] || diagnostics["raw_event_count"]
    )
    |> maybe_put_summary_value(
      "json_decode_error_count",
      diagnostics[:json_decode_error_count] ||
        diagnostics["json_decode_error_count"]
    )
    |> maybe_put_summary_value(
      "saw_done",
      diagnostics[:saw_done] || diagnostics["saw_done"]
    )
    |> maybe_put_summary_value(
      "trailing_buffer_bytes",
      diagnostic_size(
        diagnostics[:trailing_buffer] || diagnostics["trailing_buffer"]
      )
    )
  end

  defp stream_diagnostics_summary(_diagnostics), do: %{}

  defp maybe_put_summary_value(summary, _key, nil), do: summary
  defp maybe_put_summary_value(summary, _key, false), do: summary
  defp maybe_put_summary_value(summary, _key, 0), do: summary

  defp maybe_put_summary_value(summary, key, value),
    do: Map.put(summary, key, value)

  defp diagnostic_size(value) when is_binary(value), do: byte_size(value)
  defp diagnostic_size(_value), do: nil

  defp log_llm_error(worker, {:provider_error, provider, error, diagnostics}) do
    Logger.warning(fn ->
      "LLM provider error: " <>
        inspect(
          %{
            cycle_id: worker.cycle.id,
            head_id: worker.head_id,
            provider: provider,
            model: worker.cycle.model,
            error: error,
            stream_diagnostics: summarize_value(diagnostics)
          },
          pretty: true,
          limit: :infinity,
          printable_limit: :infinity
        )
    end)
  end

  defp log_llm_error(_worker, _reason), do: :ok

  defp log_empty_llm_response(worker, response, metadata, diagnostics) do
    Logger.warning(fn ->
      "LLM returned empty response: " <>
        inspect(
          %{
            cycle_id: worker.cycle.id,
            head_id: worker.head_id,
            provider: worker.cycle.provider,
            model: worker.cycle.model,
            after_tool_execution: worker.saw_tool_use?,
            stop_reason: metadata["stop_reason"],
            usage: metadata["usage"] || %{},
            message_id: metadata["message_id"],
            response: %{
              "text" => Map.get(response, :text) || Map.get(response, "text"),
              "content" =>
                Map.get(response, :content) || Map.get(response, "content") ||
                  []
            },
            stream_diagnostics: summarize_value(diagnostics)
          },
          pretty: true,
          limit: :infinity,
          printable_limit: :infinity
        )
    end)
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

    worker =
      %{worker | cycle: cycle}
      |> append_event(%{
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

    :ok = TaskBridge.sync_cycle_task(cycle, worker.head_id, status, extra)

    %{worker | finalized?: true}
  end

  defp append_message(worker, role, content, metadata \\ nil) do
    {_msg, head_id} =
      Agent.append_message(
        worker.cycle,
        worker.head_id,
        role,
        content,
        metadata,
        worker.seq
      )

    %{worker | head_id: head_id, seq: worker.seq + 1}
  end

  defp append_event(worker, attrs) do
    _event = Agent.append_event(worker.cycle, attrs, worker.seq)
    %{worker | seq: worker.seq + 1}
  end

  defp await_user_input_result?(%ToolResult{
         control_outcome: "await_user_input"
       }),
       do: true

  defp await_user_input_result?(_result), do: false

  defp cycle_error_for(:failed, _reason, extra),
    do: extra["error"] || extra[:error]

  defp cycle_error_for(_status, _reason, _extra), do: nil

  defp phase_done?(:done), do: true
  defp phase_done?(_phase), do: false

  defp phase_label(:initial), do: "initial"
  defp phase_label(:continuing), do: "continuing"
  defp phase_label(:done), do: "done"
  defp phase_label({:thinking, _task}), do: "thinking"
  defp phase_label({:working, _batch}), do: "working"
  defp phase_label({:awaiting_user_input, _batch}), do: "awaiting_user_input"
  defp phase_label(other), do: inspect(other)

  defp cancelled_reason?(:shutdown), do: true
  defp cancelled_reason?({:shutdown, :cancelled}), do: true
  defp cancelled_reason?({:shutdown, _reason}), do: true
  defp cancelled_reason?(_reason), do: false

  defp cleanup_phase({:thinking, task}) do
    if is_pid(task.pid), do: Process.exit(task.pid, :kill)
  end

  defp cleanup_phase({:working, %{invocations: invocations}}) do
    Enum.each(invocations, fn invocation ->
      if is_reference(invocation.timer_ref),
        do: Process.cancel_timer(invocation.timer_ref)

      if is_pid(invocation.task.pid),
        do: Process.exit(invocation.task.pid, :kill)
    end)
  end

  defp cleanup_phase({:awaiting_user_input, _batch}), do: :ok

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

  defp stringify_value(value) when is_list(value),
    do: Enum.map(value, &stringify_value/1)

  defp stringify_value(nil), do: nil
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value

  defp generate_span_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp execute_tool(tool_executor, %ToolUse{} = tool_use, context) do
    case GenServer.call(
           tool_executor,
           {:prepare_tool, tool_use, context},
           :infinity
         ) do
      {:ok, prepared} ->
        outcome = run_prepared_tool(prepared)

        GenServer.call(
          tool_executor,
          {:commit_tool, tool_use, context, prepared, outcome},
          :infinity
        )

      {:error, :unsupported} ->
        GenServer.call(
          tool_executor,
          {:execute, tool_use, context},
          :infinity
        )

      {:error, "unsupported"} ->
        GenServer.call(
          tool_executor,
          {:execute, tool_use, context},
          :infinity
        )

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

  defp normalize_reason({:shutdown, reason}),
    do: "shutdown:#{format_reason(reason)}"

  defp normalize_reason({:error, reason}), do: format_reason(reason)
  defp normalize_reason(other), do: format_reason(other)

  defp format_reason({:provider_error, provider, error, _diagnostics}) do
    [provider, provider_error_detail(error)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(": ")
  end

  defp format_reason(value) when is_binary(value), do: value
  defp format_reason(value) when is_atom(value), do: Atom.to_string(value)
  defp format_reason(value), do: inspect(value)

  defp provider_error_detail(%{"error" => %{} = error}) do
    [map_value(error, "type"), map_value(error, "message")]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(": ")
  end

  defp provider_error_detail(%{} = error) do
    detail =
      [map_value(error, "type"), map_value(error, "message")]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(": ")

    if detail == "", do: inspect(error), else: detail
  end

  defp provider_error_detail(error), do: inspect(error)

  defp map_value(map, key) when is_map(map) do
    case key do
      "type" -> Map.get(map, "type") || Map.get(map, :type)
      "message" -> Map.get(map, "message") || Map.get(map, :message)
      _ -> Map.get(map, key)
    end
  end

  defp resolved_provider(%Config{} = config) do
    cond do
      is_atom(config.provider) and
          config.provider in [:anthropic, :openai, :grok, :gemini] ->
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
