defmodule Froth.Telegram.GroupCalls do
  @moduledoc """
  MVP helpers for Telegram group call (video chat) media using TgCalls.

  Main flow:
  1. Start local group runtime in cnode
  2. Receive `{:group_call_join_payload, group_call_id, audio_source_id, payload}`
  3. Call TDLib `joinVideoChat` with those join parameters
  4. Pass TDLib join response payload back to cnode runtime

  Audio frames are delivered through the existing media subscription contract:
  `{:call_audio, group_call_id, pcm_frame}`.
  """

  alias Froth.Telegram
  alias Froth.Telegram.Cnode

  @doc """
  Start a local TgCalls group runtime in the C node.
  """
  def start_tgcalls_group_call(session_id, group_call_id, pid \\ self())
      when is_binary(session_id) and is_integer(group_call_id) and is_pid(pid) do
    Cnode.start_tgcalls_group_call(group_call_id, session_id, pid)
  end

  @doc """
  Stop a local TgCalls group runtime in the C node.
  """
  def stop_tgcalls_group_call(group_call_id) when is_integer(group_call_id) do
    Cnode.stop_tgcalls_group_call(group_call_id)
  end

  @doc """
  Apply TDLib's join response payload to an active local group runtime.
  """
  def set_tgcalls_group_join_response(group_call_id, payload)
      when is_integer(group_call_id) and is_binary(payload) do
    Cnode.set_tgcalls_group_join_response(group_call_id, payload)
  end

  @doc """
  Build `groupCallJoinParameters` for TDLib.
  """
  def group_call_join_parameters(audio_source_id, payload, opts \\ [])
      when is_integer(audio_source_id) and is_binary(payload) and is_list(opts) do
    %{
      "@type" => "groupCallJoinParameters",
      "audio_source_id" => audio_source_id,
      "payload" => payload,
      "is_muted" => Keyword.get(opts, :is_muted, true),
      "is_my_video_enabled" => Keyword.get(opts, :is_my_video_enabled, false)
    }
  end

  @doc """
  Build a `joinVideoChat` request.
  """
  def join_video_chat_request(group_call_id, audio_source_id, payload, opts \\ [])
      when is_integer(group_call_id) and is_integer(audio_source_id) and is_binary(payload) and
             is_list(opts) do
    participant_id = Keyword.get(opts, :participant_id)

    request = %{
      "@type" => "joinVideoChat",
      "group_call_id" => group_call_id,
      "participant_id" => participant_id,
      "join_parameters" => group_call_join_parameters(audio_source_id, payload, opts),
      "invite_hash" => normalize_binary(Keyword.get(opts, :invite_hash, ""))
    }

    if is_nil(participant_id) or is_map(participant_id) do
      request
    else
      Map.put(request, "participant_id", nil)
    end
  end

  @doc """
  End-to-end MVP join helper.

  Returns `{:ok, map}` on success where `map` includes:
  - `:audio_source_id`
  - `:join_payload`
  - `:join_response_payload`
  - `:tdlib_result`
  """
  def join_video_chat(session_id, group_call_id, opts \\ [])
      when is_binary(session_id) and is_integer(group_call_id) and is_list(opts) do
    pid = Keyword.get(opts, :pid, self())
    timeout = Keyword.get(opts, :timeout, 30_000)

    with true <- is_pid(pid) or {:error, :invalid_pid},
         :ok <- Cnode.start_tgcalls_group_call(group_call_id, session_id, pid),
         {:ok, participant_id} <- resolve_join_participant_id(session_id, group_call_id, opts),
         {:ok, audio_source_id, join_payload} <- await_group_join_payload(group_call_id, timeout),
         request <-
           join_video_chat_request(
             group_call_id,
             audio_source_id,
             join_payload,
             Keyword.put(opts, :participant_id, participant_id)
           ),
         {:ok, tdlib_result} <- Telegram.call(session_id, request, timeout),
         {:ok, join_response_payload} <- extract_join_response_payload(tdlib_result),
         :ok <- Cnode.set_tgcalls_group_join_response(group_call_id, join_response_payload) do
      {:ok,
       %{
         audio_source_id: audio_source_id,
         join_payload: join_payload,
         join_response_payload: join_response_payload,
         tdlib_result: tdlib_result
       }}
    else
      {:error, _} = error ->
        _ = Cnode.stop_tgcalls_group_call(group_call_id)
        error

      false ->
        _ = Cnode.stop_tgcalls_group_call(group_call_id)
        {:error, :invalid_pid}
    end
  end

  defp await_group_join_payload(group_call_id, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_group_join_payload(group_call_id, deadline)
  end

  defp do_await_group_join_payload(group_call_id, deadline_ms) do
    now = System.monotonic_time(:millisecond)
    remaining = max(deadline_ms - now, 0)

    receive do
      {:group_call_join_payload, ^group_call_id, audio_source_id, payload}
      when is_integer(audio_source_id) and is_binary(payload) ->
        {:ok, audio_source_id, payload}

      {:call_media_error, ^group_call_id, reason} when is_binary(reason) ->
        {:error, {:group_runtime_error, reason}}

      _other ->
        do_await_group_join_payload(group_call_id, deadline_ms)
    after
      remaining ->
        {:error, :timeout}
    end
  end

  defp extract_join_response_payload(%{"@type" => "text", "text" => payload})
       when is_binary(payload) do
    {:ok, payload}
  end

  defp extract_join_response_payload(%{"text" => payload}) when is_binary(payload) do
    {:ok, payload}
  end

  defp extract_join_response_payload(%{"@type" => "error"} = error) do
    {:error, {:tdlib_error, Map.get(error, "code"), Map.get(error, "message")}}
  end

  defp extract_join_response_payload(_), do: {:error, :invalid_join_response}

  defp resolve_join_participant_id(session_id, group_call_id, opts)
       when is_binary(session_id) and is_integer(group_call_id) and is_list(opts) do
    case Keyword.get(opts, :participant_id) do
      participant_id when is_map(participant_id) ->
        {:ok, participant_id}

      nil ->
        resolve_default_participant_id(session_id, group_call_id, opts)

      _other ->
        {:error, :invalid_participant_id}
    end
  end

  defp resolve_default_participant_id(session_id, group_call_id, opts)
       when is_binary(session_id) and is_integer(group_call_id) and is_list(opts) do
    with {:ok, chat} <- fetch_group_call_chat(session_id, group_call_id, opts),
         {:ok, participant_id} <- extract_default_participant_id(chat, group_call_id) do
      {:ok, participant_id}
    end
  end

  defp fetch_group_call_chat(session_id, group_call_id, opts)
       when is_binary(session_id) and is_integer(group_call_id) and is_list(opts) do
    case Keyword.get(opts, :chat_id) do
      chat_id when is_integer(chat_id) ->
        with {:ok, chat} <-
               Telegram.call(session_id, %{"@type" => "getChat", "chat_id" => chat_id}),
             true <- group_call_chat?(chat, group_call_id) or {:error, :group_call_chat_mismatch} do
          {:ok, chat}
        end

      _ ->
        find_group_call_chat(session_id, group_call_id)
    end
  end

  defp find_group_call_chat(session_id, group_call_id)
       when is_binary(session_id) and is_integer(group_call_id) do
    with {:ok, %{"chat_ids" => chat_ids}} <-
           Telegram.call(session_id, %{"@type" => "getChats", "limit" => 200}) do
      Enum.reduce_while(chat_ids, {:error, :group_call_chat_not_found}, fn chat_id, _acc ->
        case Telegram.call(session_id, %{"@type" => "getChat", "chat_id" => chat_id}) do
          {:ok, chat} ->
            if group_call_chat?(chat, group_call_id) do
              {:halt, {:ok, chat}}
            else
              {:cont, {:error, :group_call_chat_not_found}}
            end

          _ ->
            {:cont, {:error, :group_call_chat_not_found}}
        end
      end)
    end
  end

  defp group_call_chat?(%{"video_chat" => %{"group_call_id" => group_call_id}}, group_call_id),
    do: true

  defp group_call_chat?(_, _), do: false

  defp extract_default_participant_id(
         %{
           "video_chat" => %{
             "group_call_id" => group_call_id,
             "default_participant_id" => participant_id
           }
         },
         group_call_id
       )
       when is_map(participant_id) do
    {:ok, participant_id}
  end

  defp extract_default_participant_id(_, _), do: {:error, :missing_default_participant_id}

  defp normalize_binary(value) when is_binary(value), do: value
  defp normalize_binary(_), do: ""
end
