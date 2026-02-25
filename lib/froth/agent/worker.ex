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
          head_id: String.t() | nil
        }

  defstruct [:config, :cycle, :head_id, phase: :initial]

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
    worker = %__MODULE__{
      config: config,
      cycle: cycle,
      head_id: Agent.latest_head_id(cycle)
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
    worker = persist_message(worker, :agent, response.content)

    case parse_tool_uses(response.content) do
      [] -> {:stop, :normal, %{worker | phase: :done}}
      tool_uses -> maybe_tools_done(start_tools(worker, tool_uses))
    end
  end

  def handle_info({ref, {:error, reason}}, %{phase: {:thinking, %{ref: ref}}} = worker) do
    Process.demonitor(ref, [:flush])
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

  defp persist_message(worker, role, content) do
    {_msg, head_id} = Agent.append_message(worker.cycle, worker.head_id, role, content)
    %{worker | head_id: head_id}
  end

  defp start_thinking(worker) do
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
        effort: worker.config.effort
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    task =
      Task.Supervisor.async(Froth.Agent.TaskSupervisor, fn ->
        Froth.Anthropic.stream_single(
          api_messages,
          fn event -> Froth.broadcast("cycle:#{cycle_id}", {:stream, event}) end,
          opts
        )
      end)

    %{worker | phase: {:thinking, task}}
  end

  defp parse_tool_uses(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%{"type" => "tool_use"}, &1))
    |> Enum.map(&ToolUse.from_api/1)
  end

  defp parse_tool_uses(_), do: []

  defp start_tools(worker, tool_uses) do
    context = %{cycle_id: worker.cycle.id, head_id: worker.head_id}

    invocations =
      Enum.map(tool_uses, fn %ToolUse{id: id} = tool_use ->
        task =
          Task.Supervisor.async(Froth.Agent.TaskSupervisor, fn ->
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
    %{worker | phase: {:working, invocations, [ToolResult.new(tool_use_id, result) | results]}}
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
end
