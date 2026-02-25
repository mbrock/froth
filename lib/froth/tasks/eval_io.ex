defmodule Froth.Tasks.EvalIO do
  @moduledoc """
  An IO device (group leader) that captures output and writes it to
  task_events via Froth.Tasks.append_output. Also buffers contents
  for retrieval at the end of evaluation.
  """

  use GenServer

  def start_link(task_id) when is_binary(task_id) do
    GenServer.start_link(__MODULE__, task_id)
  end

  def contents(pid) do
    GenServer.call(pid, :contents)
  end

  @impl true
  def init(task_id) do
    {:ok, %{task_id: task_id, buf: []}}
  end

  @impl true
  def handle_info({:io_request, from, ref, request}, state) do
    {reply, state} = handle_io(request, state)
    send(from, {:io_reply, ref, reply})
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_call(:contents, _from, state) do
    {:reply, IO.iodata_to_binary(Enum.reverse(state.buf)), state}
  end

  defp handle_io({:put_chars, _encoding, chars}, state) do
    text = IO.chardata_to_string(chars)
    Froth.Tasks.append_output(state.task_id, text)
    {:ok, %{state | buf: [text | state.buf]}}
  end

  defp handle_io({:put_chars, chars}, state) do
    text = IO.chardata_to_string(chars)
    Froth.Tasks.append_output(state.task_id, text)
    {:ok, %{state | buf: [text | state.buf]}}
  end

  defp handle_io({:get_chars, _encoding, _prompt, _count}, state), do: {:eof, state}
  defp handle_io({:get_line, _encoding, _prompt}, state), do: {:eof, state}
  defp handle_io({:get_until, _encoding, _prompt, _mod, _fun, _args}, state), do: {:eof, state}

  defp handle_io({:requests, requests}, state) do
    Enum.reduce(requests, {:ok, state}, fn req, {_, st} -> handle_io(req, st) end)
  end

  defp handle_io(:getopts, state), do: {[binary: true, encoding: :unicode], state}
  defp handle_io({:setopts, _opts}, state), do: {:ok, state}
  defp handle_io(_, state), do: {{:error, :request}, state}
end
