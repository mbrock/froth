defmodule Froth.Agent.Worker do
  @moduledoc """
  GenServer that executes an agentic cycle: think → act → repeat until done.

  Started with a cycle and config. Runs autonomously until quiescence.
  Delegates all persistence to `Froth.Agent`.
  """

  use GenServer

  alias Froth.Agent
  alias Froth.Agent.{Config, Cycle, Message, ToolUse, ToolResult}

  @type invocation :: {reference(), ToolUse.t()}
  @type phase ::
          :initial
          | :continuing
          | :done
          | {:thinking, Task.t()}
          | {:working, [invocation()], [ToolResult.t()]}

  @type t :: %__MODULE__{
          config: Config.t(),
          phase: phase(),
          cycle: Cycle.t(),
          head_id: String.t() | nil,
          empty_reply_retries: non_neg_integer(),
          telemetry_start: integer() | nil,
          think_start: integer() | nil
        }

  defstruct [
    :config,
    :cycle,
    :head_id,
    :telemetry_start,
    :think_start,
    phase: :initial,
    empty_reply_retries: 0
  ]

  @max_empty_reply_retries 2

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

    :telemetry.execute(
      [:froth, :agent, :cycle, :start],
      %{system_time: System.system_time()},
      %{cycle_id: cycle.id, model: config.model}
    )

    worker = %__MODULE__{
      config: config,
      cycle: cycle,
      head_id: Agent.latest_head_id(cycle),
      telemetry_start: now
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

    case parse_tool_uses(response.content) do
      [] ->
        if has_visible_response?(response.content) do
          worker = persist_agent_message(worker, response.content, response_metadata)
          {:stop, :normal, %{worker | phase: :done, empty_reply_retries: 0}}
        else
          maybe_retry_empty_response(worker)
        end

      tool_uses ->
        worker =
          worker
          |> persist_agent_message(response.content, response_metadata)
          |> Map.put(:empty_reply_retries, 0)

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
        %{phase: {:working, invocations, _}} = worker
      ) do
    {^ref, %ToolUse{id: ^tool_use_id}} = find_invocation!(invocations, ref)
    Process.demonitor(ref, [:flush])
    maybe_tools_done(collect_tool_result(worker, tool_use_id, result))
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

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, %{phase: {:working, _, _}} = worker) do
    {:noreply, worker}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{phase: {:working, _, _}} = worker) do
    case find_invocation(worker.phase, ref) do
      {^ref, %ToolUse{id: tool_use_id}} ->
        error = "tool task failed: #{Exception.format_exit(reason)}"
        maybe_tools_done(collect_tool_result(worker, tool_use_id, {:error, error}))

      nil ->
        {:noreply, worker}
    end
  end

  def handle_info(_message, worker), do: {:noreply, worker}

  @impl true
  def terminate(reason, worker) do
    :telemetry.execute(
      [:froth, :agent, :cycle, :stop],
      %{duration: System.monotonic_time() - worker.telemetry_start},
      %{cycle_id: worker.cycle.id, reason: normalize_reason(reason), phase: worker.phase}
    )
  end

  defp persist_message(worker, role, content) do
    {_msg, head_id} = Agent.append_message(worker.cycle, worker.head_id, role, content)
    %{worker | head_id: head_id}
  end

  defp persist_agent_message(worker, content, metadata) do
    {_msg, head_id} = Agent.append_message(worker.cycle, worker.head_id, :agent, content, metadata)
    %{worker | head_id: head_id}
  end

  defp start_thinking(worker) do
    now = System.monotonic_time()

    :telemetry.execute(
      [:froth, :agent, :think, :start],
      %{system_time: System.system_time()},
      %{cycle_id: worker.cycle.id}
    )

    api_messages =
      worker.head_id
      |> Agent.load_messages()
      |> Enum.map(&Message.to_api/1)

    cycle_id = worker.cycle.id

    opts =
      [
        system: worker.config.system || "",
        model: worker.config.model,
        tools: worker.config.tools,
        thinking: worker.config.thinking,
        effort: worker.config.effort,
        cycle_id: cycle_id
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    task =
      Task.Supervisor.async_nolink(Froth.Agent.TaskSupervisor, fn ->
        Froth.Anthropic.stream_single(
          api_messages,
          fn event -> Froth.broadcast("cycle:#{cycle_id}", {:stream, event}) end,
          opts
        )
      end)

    %{worker | phase: {:thinking, task}, think_start: now}
  end

  defp emit_think_stop(worker, extra_meta \\ %{}) do
    if worker.think_start do
      :telemetry.execute(
        [:froth, :agent, :think, :stop],
        %{duration: System.monotonic_time() - worker.think_start},
        Map.merge(%{cycle_id: worker.cycle.id}, extra_meta)
      )
    end

    %{worker | think_start: nil}
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

    invocations =
      Enum.map(tool_uses, fn %ToolUse{id: id} = tool_use ->
        task =
          Task.Supervisor.async_nolink(Froth.Agent.TaskSupervisor, fn ->
            result = GenServer.call(worker.config.tool_executor, {:execute, tool_use, context})
            {:tool_result, id, result}
          end)

        {task.ref, tool_use}
      end)

    %{worker | phase: {:working, invocations, []}}
  end

  defp collect_tool_result(
         %{phase: {:working, invocations, results}} = worker,
         tool_use_id,
         result
       ) do
    tool_result =
      case result do
        {:ok, content} ->
          ToolResult.new(tool_use_id, content)

        {:error, content} ->
          ToolResult.new(tool_use_id, content, is_error: true)

        content ->
          ToolResult.new(tool_use_id, content)
      end

    %{worker | phase: {:working, invocations, [tool_result | results]}}
  end

  defp find_invocation!(invocations, ref) do
    List.keyfind(invocations, ref, 0) || raise "unknown invocation ref: #{inspect(ref)}"
  end

  defp maybe_tools_done(%{phase: {:working, invocations, results}} = worker)
       when length(invocations) == length(results) do
    api_results = results |> Enum.reverse() |> Enum.map(&ToolResult.to_api/1)
    worker = persist_message(worker, :user, api_results)
    {:noreply, %{worker | phase: :continuing}, {:continue, :think}}
  end

  defp maybe_tools_done(worker), do: {:noreply, worker}

  defp find_invocation({:working, invocations, _results}, ref) do
    List.keyfind(invocations, ref, 0)
  end

  defp find_invocation(_, _), do: nil

  defp has_visible_response?(content) when is_binary(content) do
    String.trim(content) != ""
  end

  defp has_visible_response?(content) when is_list(content) do
    Enum.any?(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        String.trim(text) != ""

      %{"type" => "tool_use"} ->
        true

      %{"type" => "tool_result"} ->
        true

      _ ->
        false
    end)
  end

  defp has_visible_response?(content) when is_map(content) do
    case content["text"] do
      text when is_binary(text) -> String.trim(text) != ""
      _ -> false
    end
  end

  defp has_visible_response?(_), do: false

  defp maybe_retry_empty_response(worker) do
    retry = worker.empty_reply_retries + 1

    if retry <= @max_empty_reply_retries do
      :telemetry.execute(
        [:froth, :agent, :empty_retry],
        %{retry: retry},
        %{cycle_id: worker.cycle.id}
      )

      {:noreply, %{worker | phase: :continuing, empty_reply_retries: retry}, {:continue, :think}}
    else
      {:stop, :normal, %{worker | phase: :done}}
    end
  end

  defp normalize_reason(:normal), do: :normal
  defp normalize_reason(:shutdown), do: :shutdown
  defp normalize_reason({:shutdown, _}), do: :shutdown
  defp normalize_reason({:error, reason}), do: {:error, reason}
  defp normalize_reason(other), do: {:error, other}
end
