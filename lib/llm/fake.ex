defmodule LLM.Fake do
  @moduledoc """
  Test-only fake LLM server addressed by model id.

  A test calls `claim/0` to mint a unique model id like
  `"fakeai-slop-XXXXXX"` and registers the current process as the server
  for that id. The bot/worker/etc. is started using that model. When
  production code calls `LLM.stream_single/3` (or `stream/3`), the
  request is routed through the normal pipeline; once the model's
  resolved provider is `:fakeai`, `LLM.stream/3` delegates here
  and we deliver the full `%LLM.Request{}` to the registered pid
  as a message. The test asserts on the request and replies inline.
  """

  alias LLM.Request

  @registry __MODULE__.Registry
  @default_timeout :timer.seconds(30)

  @spec claim() :: String.t()
  def claim do
    model =
      "fakeai-slop-" <>
        Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    {:ok, _} = Registry.register(@registry, model, nil)
    model
  end

  @spec stream(Request.t(), (term() -> any())) ::
          {:ok, map()} | {:error, term()}
  def stream(%Request{model: model} = request, on_event)
      when is_function(on_event, 1) do
    case Registry.lookup(@registry, model) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        from = {self(), ref, on_event}
        send(pid, {__MODULE__, from, request})

        receive do
          {__MODULE__, :reply, ^ref, result} ->
            Process.demonitor(ref, [:flush])
            normalize_result(result, request)

          {:DOWN, ^ref, :process, ^pid, reason} ->
            {:error, {:fake_llm_server_down, model, reason}}
        after
          @default_timeout ->
            Process.demonitor(ref, [:flush])
            {:error, {:fake_llm_timeout, model}}
        end

      [] ->
        {:error, {:unknown_fake_model, model}}
    end
  end

  @spec reply(
          {pid(), reference(), (term() -> any())} | {pid(), reference()},
          term()
        ) :: :ok
  def reply({pid, ref, _on_event}, result), do: reply({pid, ref}, result)

  def reply({pid, ref}, result) when is_pid(pid) and is_reference(ref) do
    send(pid, {__MODULE__, :reply, ref, result})
    :ok
  end

  @spec emit({pid(), reference(), (term() -> any())}, term()) :: :ok
  def emit({_pid, _ref, on_event}, event) when is_function(on_event, 1) do
    on_event.(event)
    :ok
  end

  def registry_name, do: @registry

  defp normalize_result({:ok, result}, %Request{model: model})
       when is_map(result) do
    {:ok,
     result
     |> Map.put_new(:text, "")
     |> Map.put_new(:content, [])
     |> Map.put_new(:stop_reason, "end_turn")
     |> Map.put_new(:usage, %{})
     |> Map.put_new(:model, model)
     |> Map.put_new(:message_id, random_message_id())
     |> Map.put_new(:diagnostics, [])}
  end

  defp normalize_result({:error, reason}, _request) do
    {:error, {:error, reason}}
  end

  defp normalize_result(other, _request) do
    {:error, {:error, {:unexpected_reply, other}}}
  end

  defp random_message_id do
    "msg_fake_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end
end
