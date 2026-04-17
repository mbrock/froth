defmodule Froth.LLM.Fake do
  @moduledoc """
  Test-only fake LLM server addressed by model id.

  A test calls `claim/0` to mint a unique model id like
  `"fakeai-slop-XXXXXX"` and registers the current process as the server
  for that id. The bot/worker/etc. is started using that model. When
  production code calls `Froth.LLM.stream_single/3` (or `stream/3`), the
  request is routed through the normal pipeline; once the model's
  resolved provider is `:fakeai`, `Froth.LLM.stream/3` delegates here
  and we deliver the full `%Froth.LLM.Request{}` to the registered pid
  as a message. The test asserts on the request and replies inline:

      test "something" do
        model = Froth.LLM.Fake.claim()
        bot = start_supervised!({Bot, model: model, ...})
        send(bot, {:telegram_update, ...})

        assert_receive {Froth.LLM.Fake, from, request}, 5_000
        assert [%Froth.LLM.Message{role: :user}] = request.messages

        Froth.LLM.Fake.reply(from, {:ok, %{
          content: [%{"type" => "text", "text" => "hi"}],
          stop_reason: "end_turn"
        }})
      end

  The request result is normalized to the same map shape that real
  providers return (`text`, `content`, `stop_reason`, `usage`, `model`,
  `message_id`, `diagnostics`). Tests only need to spell out fields they
  care about.

  Errors returned via `reply/2` are wrapped in a non-retryable
  `{:fake_llm_error, reason}` tuple so the upstream retry loop in
  `Froth.LLM.stream_with_retries/5` can never engage on them.

  The Registry entry dies with the registering process, so no explicit
  teardown is needed: when the test pid exits, the model id is freed.
  """

  alias Froth.LLM.Request

  @registry __MODULE__.Registry
  @default_timeout :timer.seconds(30)

  @doc """
  Mint a unique fakeai model id and register the current process as the
  server for that id. Returns the model id (a string).

  Must be called from the process that will serve the LLM calls (usually
  the test process). The registration is auto-cleaned when that process
  exits.
  """
  @spec claim() :: String.t()
  def claim do
    model = "fakeai-slop-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    {:ok, _} = Registry.register(@registry, model, nil)
    model
  end

  @doc """
  Called from `Froth.LLM.stream/3` when a request's provider module is
  `Froth.LLM.Providers.Fake`. Delivers the request to the pid
  registered for `request.model` and blocks waiting for the reply.

  The `on_event` callback is carried in the `from` handle so tests can
  invoke it via `emit/2` to simulate streaming deltas before replying.
  """
  @spec stream(Request.t(), (term() -> any())) :: {:ok, map()} | {:error, term()}
  def stream(%Request{model: model} = request, on_event) when is_function(on_event, 1) do
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

  @doc """
  Reply to a fake LLM call received via `assert_receive`.

  The reply is normalized so that a real, retryable error shape can
  never be produced by a fake. `{:ok, map}` is passed through with
  missing fields defaulted; anything else is wrapped as
  `{:error, {:fake_llm_error, reason}}`.

  Accepts either the 3-tuple `from` handle delivered with the call or a
  bare `{pid, ref}` pair, so existing tests that pattern-match just the
  pid/ref still work.
  """
  @spec reply({pid(), reference(), (term() -> any())} | {pid(), reference()}, term()) :: :ok
  def reply({pid, ref, _on_event}, result), do: reply({pid, ref}, result)

  def reply({pid, ref}, result) when is_pid(pid) and is_reference(ref) do
    send(pid, {__MODULE__, :reply, ref, result})
    :ok
  end

  @doc """
  Invoke the stream's `on_event` callback from the test process, to
  simulate streaming deltas (e.g. `{:text_delta, "..."}`) before
  replying.
  """
  @spec emit({pid(), reference(), (term() -> any())}, term()) :: :ok
  def emit({_pid, _ref, on_event}, event) when is_function(on_event, 1) do
    on_event.(event)
    :ok
  end

  @doc false
  def registry_name, do: @registry

  defp normalize_result({:ok, result}, %Request{model: model}) when is_map(result) do
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
    {:error, {:fake_llm_error, reason}}
  end

  defp normalize_result(other, _request) do
    {:error, {:fake_llm_error, {:unexpected_reply, other}}}
  end

  defp random_message_id do
    "msg_fake_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end
end
