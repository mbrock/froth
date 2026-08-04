defmodule Froth.PreliminarySummarizer do
  @moduledoc """
  Periodically advances an amendable summary of the current UTC day when the
  unsummarized Telegram context grows beyond a configured character budget.
  """

  use GenServer

  require Logger

  alias Froth.Summarizer

  @default_chat_id -1_003_690_254_489
  @default_interval_ms 300_000
  @default_startup_delay_ms 30_000
  @default_char_threshold 200_000
  @tick :check_preliminary_summary

  defstruct [
    :chat_id,
    :interval_ms,
    :char_threshold,
    :timer_ref,
    :task_ref,
    :task_pid
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    opts = Keyword.merge(Application.get_env(:froth, __MODULE__, []), opts)

    if enabled?(opts) do
      state = %__MODULE__{
        chat_id: integer_opt(opts, :chat_id, @default_chat_id),
        interval_ms: integer_opt(opts, :interval_ms, @default_interval_ms),
        char_threshold:
          integer_opt(opts, :char_threshold, @default_char_threshold)
      }

      startup_delay_ms =
        integer_opt(opts, :startup_delay_ms, @default_startup_delay_ms)

      {:ok, schedule(state, startup_delay_ms)}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(@tick, %{task_ref: nil} = state) do
    task =
      Task.Supervisor.async_nolink(Froth.TaskSupervisor, fn ->
        Summarizer.maybe_summarize_preliminary(state.chat_id,
          char_threshold: state.char_threshold
        )
      end)

    {:noreply,
     %{state | task_ref: task.ref, task_pid: task.pid, timer_ref: nil}}
  end

  def handle_info(@tick, state),
    do: {:noreply, schedule(state, state.interval_ms)}

  def handle_info({ref, {:ok, summary}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])

    if summary do
      Logger.info(
        "Preliminary summary advanced through " <>
          DateTime.to_iso8601(DateTime.from_unix!(summary.to_date))
      )
    end

    {:noreply,
     state
     |> Map.merge(%{task_ref: nil, task_pid: nil})
     |> schedule(state.interval_ms)}
  end

  def handle_info({ref, {:error, reason}}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    Logger.error("Preliminary summary failed: #{inspect(reason)}")

    {:noreply,
     state
     |> Map.merge(%{task_ref: nil, task_pid: nil})
     |> schedule(state.interval_ms)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{task_ref: ref} = state
      ) do
    Logger.error("Preliminary summary worker exited: #{inspect(reason)}")

    {:noreply,
     state
     |> Map.merge(%{task_ref: nil, task_pid: nil})
     |> schedule(state.interval_ms)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(state, delay_ms) do
    if is_reference(state.timer_ref),
      do: Process.cancel_timer(state.timer_ref)

    %{state | timer_ref: Process.send_after(self(), @tick, max(delay_ms, 0))}
  end

  defp enabled?(opts) do
    case Keyword.get(opts, :enabled, true) do
      value when value in [true, "1", "true", "yes", "on"] -> true
      _ -> false
    end
  end

  defp integer_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      value when is_binary(value) -> parse_integer(value, default)
      _ -> default
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> default
    end
  end
end
