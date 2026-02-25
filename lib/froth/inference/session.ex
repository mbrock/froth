defmodule Froth.Inference.Session do
  @moduledoc """
  Lifecycle/state machine for ongoing language model inference sessions.

  This module owns inference session persistence, tool-loop transitions,
  and stream/tool execution side effects.
  """

  require Logger

  alias Froth.Inference.Prompt
  alias Froth.Inference.StepLog
  alias Froth.Inference.Tools
  alias Froth.Repo
  alias Froth.Inference.InferenceSession
  import Ecto.Query

  def start_inference_session(msg, state) when is_map(msg) and is_map(state) do
    start_inference_session_messages([msg], state)
  end

  def start_inference_session_messages(messages, state)
      when is_list(messages) and messages != [] and is_map(state) do
    messages = sort_messages(messages)
    first = hd(messages)
    last = List.last(messages)

    chat_id = first["chat_id"]
    reply_to = last["id"]

    context_opts =
      case message_unix(first) do
        unix when is_integer(unix) -> [before_unix: unix, telegram_session_id: session_id(state)]
        _ -> [telegram_session_id: session_id(state)]
      end

    context_blocks = Froth.Summarizer.context_blocks(chat_id, context_opts)

    task_overview = Froth.Tasks.context_summary(bot_id(state), chat_id)
    new_messages_section = format_new_messages(messages)

    new_messages_section =
      if task_overview != "" do
        task_overview <> "\n\n" <> new_messages_section
      else
        new_messages_section
      end

    # Inject previous session tool calls recap
    session_recap = previous_session_recap(bot_id(state), chat_id)

    new_messages_section =
      if session_recap != "" do
        session_recap <> "\n\n" <> new_messages_section
      else
        new_messages_section
      end

    user_content = Prompt.initial_user_content(context_blocks, "", new_messages_section)
    api_messages = [%{"role" => "user", "content" => user_content}]

    {:ok, inference_session} =
      %InferenceSession{}
      |> InferenceSession.changeset(%{
        bot_id: bot_id(state),
        chat_id: chat_id,
        reply_to: reply_to,
        api_messages: api_messages,
        status: "streaming"
      })
      |> Repo.insert()

    StepLog.append(inference_session.id, "inference_session_started", %{
      "chat_id" => chat_id,
      "reply_to" => reply_to,
      "sender_id" => get_in(last, ["sender_id", "user_id"]),
      "message_count" => length(messages),
      "message_ids" => Enum.map(messages, & &1["id"])
    })

    start_streaming(inference_session, state)
  end

  def handle_stream_result(
        inference_session_id,
        {:ok, %{content: content, stop_reason: stop_reason} = response},
        state
      ) do
    inference_session = Repo.get!(InferenceSession, inference_session_id)
    tool_uses = Enum.filter(content, &match?(%{"type" => "tool_use"}, &1))
    usage = Map.get(response, :usage, %{})

    Logger.info(
      event: :inference_stream_result,
      inference_session_id: inference_session_id,
      stop_reason: stop_reason,
      tool_use_count: length(tool_uses),
      usage: inspect(usage)
    )

    new_messages =
      inference_session.api_messages ++ [%{"role" => "assistant", "content" => content}]

    StepLog.append_assistant_content(inference_session.id, content)

    if stop_reason == "tool_use" and tool_uses != [] do
      StepLog.append(inference_session.id, "assistant_requested_tools", %{
        "count" => length(tool_uses),
        "names" => Enum.map(tool_uses, &(&1["name"] || "tool"))
      })

      pending_tools = build_pending_tools(inference_session, tool_uses, state)

      inference_session =
        inference_session
        |> InferenceSession.changeset(%{
          api_messages: new_messages,
          pending_tools: pending_tools,
          status: "awaiting_tools"
        })
        |> Repo.update!()

      send_tool_loop_prompt(inference_session, pending_tools, state)

      StepLog.append(inference_session.id, "awaiting_tools", %{
        "pending_count" => Enum.count(pending_tools, &(&1["status"] == "pending")),
        "resolved_count" => Enum.count(pending_tools, &(&1["status"] == "resolved"))
      })

      StepLog.broadcast_loop(inference_session.id)

      check_all_tools_resolved(inference_session_id, state)
    else
      inference_session
      |> InferenceSession.changeset(%{api_messages: new_messages, status: "done"})
      |> Repo.update!()

      StepLog.append(inference_session.id, "assistant_completed", %{
        "stop_reason" => stop_reason || "end_turn"
      })

      StepLog.broadcast_loop(inference_session.id)

      {:noreply, state}
    end
  end

  def handle_stream_result(
        inference_session_id,
        {:error, {:http_error, _, %{"error" => %{"message" => msg}}}},
        state
      ) do
    case Repo.get(InferenceSession, inference_session_id) do
      nil ->
        :ok

      inference_session ->
        send_error(state, inference_session.chat_id, msg)
    end

    Logger.error(event: :api_error, inference_session_id: inference_session_id, error: msg)
    StepLog.append(inference_session_id, "stream_error", %{"error" => msg})
    update_inference_session_status(inference_session_id, "error")
    StepLog.broadcast_loop(inference_session_id)
    {:noreply, state}
  end

  def handle_stream_result(inference_session_id, {:error, err}, state) do
    case Repo.get(InferenceSession, inference_session_id) do
      nil ->
        :ok

      inference_session ->
        send_error(state, inference_session.chat_id, inspect(err))
    end

    Logger.error(
      event: :reply_error,
      inference_session_id: inference_session_id,
      error: inspect(err)
    )

    StepLog.append(inference_session_id, "stream_error", %{"error" => inspect(err, limit: 500)})
    update_inference_session_status(inference_session_id, "error")
    StepLog.broadcast_loop(inference_session_id)
    {:noreply, state}
  end

  def continue_loop(inference_session_id, state) when is_integer(inference_session_id) do
    StepLog.append(inference_session_id, "continue_requested", %{})

    case Repo.get(InferenceSession, inference_session_id) do
      %{status: "awaiting_tools"} = inference_session ->
        case Enum.find(inference_session.pending_tools, &(&1["status"] == "pending")) do
          %{"ref" => ref} when is_binary(ref) ->
            do_resolve_tool(inference_session, ref, "go", state)

          _ ->
            check_all_tools_resolved(inference_session.id, state)
        end

      _ ->
        {:noreply, state}
    end
  end

  def stop_loop(inference_session_id, state) when is_integer(inference_session_id) do
    case Repo.get(InferenceSession, inference_session_id) do
      nil ->
        {:noreply, state}

      inference_session ->
        state = cancel_inference_session_tasks(state, inference_session_id)

        pending_tools =
          Enum.map(inference_session.pending_tools, fn tool ->
            case tool["status"] do
              "pending" ->
                %{
                  tool
                  | "status" => "stopped",
                    "result" => "Stopped by user.",
                    "is_error" => false
                }

              "executing" ->
                %{
                  tool
                  | "status" => "resolved",
                    "result" => "Aborted by user.",
                    "is_error" => true
                }

              _ ->
                tool
            end
          end)

        inference_session
        |> InferenceSession.changeset(%{pending_tools: pending_tools, status: "stopped"})
        |> Repo.update!()

        StepLog.append(inference_session.id, "loop_stopped", %{
          "pending_count" => Enum.count(pending_tools, &(&1["status"] == "pending")),
          "executing_count" => Enum.count(pending_tools, &(&1["status"] == "executing"))
        })

        send_italic(state, inference_session.chat_id, inference_session.reply_to, "stopped")

        StepLog.broadcast_loop(inference_session.id)
        {:noreply, state}
    end
  end

  def abort_tool(ref, state) when is_binary(ref) do
    case Repo.one(
           from(c in InferenceSession,
             where:
               c.bot_id == ^bot_id(state) and c.status == "awaiting_tools" and
                 fragment(
                   "EXISTS (SELECT 1 FROM jsonb_array_elements(?) elem WHERE elem->>'ref' = ? AND elem->>'status' = 'executing')",
                   c.pending_tools,
                   ^ref
                 ),
             limit: 1
           ),
           log: false
         ) do
      nil ->
        {:noreply, state}

      inference_session ->
        tool = Enum.find(inference_session.pending_tools, &(&1["ref"] == ref))
        tool_use_id = tool["tool_use_id"]

        task_entry =
          Enum.find(state.tasks, fn {_tref, val} ->
            match?({:tool_exec, _, ^tool_use_id, _}, val)
          end)

        state =
          case task_entry do
            {tref, {:tool_exec, _, _, pid}} ->
              Process.demonitor(tref, [:flush])
              Process.unlink(pid)
              Process.exit(pid, :kill)
              %{state | tasks: Map.delete(state.tasks, tref)}

            nil ->
              state
          end

        pending_tools =
          Enum.map(inference_session.pending_tools, fn t ->
            if t["ref"] == ref and t["status"] == "executing" do
              %{t | "status" => "resolved", "result" => "Aborted by user.", "is_error" => true}
            else
              t
            end
          end)

        inference_session
        |> InferenceSession.changeset(%{pending_tools: pending_tools})
        |> Repo.update!()

        StepLog.append(inference_session.id, "tool_aborted", %{
          "ref" => ref,
          "tool_use_id" => tool_use_id,
          "name" => tool["name"] || "tool"
        })

        StepLog.broadcast_loop(inference_session.id)

        Froth.broadcast("tool:#{ref}", {:tool_aborted, ref})

        check_all_tools_resolved(inference_session.id, state)
    end
  end

  def resolve_tool(ref, action, state)
      when is_binary(ref) and action in ["go", "skip", "stop"] do
    case find_inference_session_by_ref(ref, state) do
      nil -> {:noreply, state}
      inference_session -> do_resolve_tool(inference_session, ref, action, state)
    end
  end

  def resolve_tool(_, _, state), do: {:noreply, state}

  def handle_tool_result(inference_session_id, tool_use_id, result, is_error, state) do
    case Repo.get(InferenceSession, inference_session_id) do
      nil ->
        {:noreply, state}

      %{status: "stopped"} ->
        {:noreply, state}

      inference_session ->
        pending_tools =
          Enum.map(inference_session.pending_tools, fn tool ->
            if tool["tool_use_id"] == tool_use_id and tool["status"] == "executing" do
              %{tool | "status" => "resolved", "result" => result, "is_error" => is_error}
            else
              tool
            end
          end)

        inference_session
        |> InferenceSession.changeset(%{pending_tools: pending_tools})
        |> Repo.update!()

        StepLog.append(inference_session.id, "tool_resolved", %{
          "tool_use_id" => tool_use_id,
          "is_error" => is_error,
          "result" => result,
          "result_preview" => tool_result_preview(result)
        })

        Logger.info(
          event: :inference_tool_result,
          inference_session_id: inference_session.id,
          tool_use_id: tool_use_id,
          is_error: is_error,
          result_preview: tool_result_preview(result)
        )

        StepLog.broadcast_loop(inference_session.id)
        check_all_tools_resolved(inference_session_id, state)
    end
  end

  def check_all_tools_resolved(inference_session_id, state) do
    inference_session = Repo.get!(InferenceSession, inference_session_id)

    if inference_session.status != "awaiting_tools" do
      {:noreply, state}
    else
      all_resolved =
        Enum.all?(inference_session.pending_tools, &(&1["status"] in ["resolved", "stopped"]))

      if all_resolved do
        any_stopped = Enum.any?(inference_session.pending_tools, &(&1["status"] == "stopped"))

        if any_stopped do
          {:noreply, state}
        else
          tool_results =
            Enum.map(inference_session.pending_tools, fn tool ->
              %{
                "type" => "tool_result",
                "tool_use_id" => tool["tool_use_id"],
                "is_error" => tool["is_error"] || false,
                "content" => tool["result"] || ""
              }
            end)

          queued_messages = inference_session.queued_messages || []
          steering_blocks = steering_message_blocks(queued_messages)
          user_content = tool_results ++ steering_blocks

          new_messages =
            inference_session.api_messages ++ [%{"role" => "user", "content" => user_content}]

          inference_session =
            inference_session
            |> InferenceSession.changeset(%{
              api_messages: new_messages,
              pending_tools: [],
              queued_messages: [],
              status: "streaming"
            })
            |> Repo.update!()

          StepLog.append(inference_session.id, "tool_batch_committed", %{
            "count" => length(tool_results),
            "error_count" => Enum.count(tool_results, &(&1["is_error"] == true)),
            "queued_message_count" => length(queued_messages)
          })

          StepLog.broadcast_loop(inference_session.id)
          state = start_streaming(inference_session, state)
          {:noreply, state}
        end
      else
        maybe_start_next_pending_tool(inference_session, state)
      end
    end
  end

  def cancel_typing(state, inference_session_id) when is_map(state) do
    case Map.pop(state.typing_timers, inference_session_id) do
      {nil, _} ->
        state

      {tref, timers} ->
        :timer.cancel(tref)
        %{state | typing_timers: timers}
    end
  end

  def handle_stream_crash(inference_session_id, reason, state)
      when is_integer(inference_session_id) do
    Logger.error(
      event: :stream_crash,
      inference_session_id: inference_session_id,
      reason: inspect(reason)
    )

    case Repo.get(InferenceSession, inference_session_id) do
      nil ->
        :ok

      inference_session ->
        send_error(
          state,
          inference_session.chat_id,
          "Stream crashed: #{inspect(reason)}"
        )
    end

    StepLog.append(inference_session_id, "stream_crashed", %{
      "reason" => inspect(reason, limit: 500)
    })

    update_inference_session_status(inference_session_id, "error")
    {:noreply, state}
  end

  def handle_tool_crash(inference_session_id, tool_use_id, reason, state)
      when is_integer(inference_session_id) do
    Logger.error(
      event: :tool_crash,
      inference_session_id: inference_session_id,
      reason: inspect(reason)
    )

    StepLog.append(inference_session_id, "tool_crashed", %{
      "tool_use_id" => tool_use_id,
      "reason" => inspect(reason, limit: 500)
    })

    handle_tool_result(
      inference_session_id,
      tool_use_id,
      "Tool crashed: #{inspect(reason)}",
      true,
      state
    )
  end

  defp start_streaming(inference_session, state) do
    StepLog.append(inference_session.id, "stream_started", %{
      "message_count" => length(inference_session.api_messages || [])
    })

    Logger.info(
      event: :inference_stream_start,
      inference_session_id: inference_session.id,
      chat_id: inference_session.chat_id,
      message_count: length(inference_session.api_messages || [])
    )

    send_typing(state, inference_session.chat_id)
    {:ok, tref} = :timer.send_interval(4_000, self(), {:typing, inference_session.chat_id})

    inference_session_id = inference_session.id
    api_messages = inference_session.api_messages
    chat_id = inference_session.chat_id
    config = state.config

    task =
      Task.async(fn ->
        on_event = fn
          {:text_delta, t} = event ->
            StepLog.broadcast_stream_event(inference_session_id, event)
            IO.write(t)

          {:thinking_delta, %{"delta" => t}} = event ->
            StepLog.broadcast_stream_event(inference_session_id, event)
            IO.write([IO.ANSI.faint(), t, IO.ANSI.reset()])

          {:thinking_start, _} = event ->
            StepLog.broadcast_stream_event(inference_session_id, event)
            :ok

          {:thinking_stop, _} = event ->
            StepLog.broadcast_stream_event(inference_session_id, event)
            IO.write("\n---\n")

          {:tool_use_start, _} = event ->
            StepLog.broadcast_stream_event(inference_session_id, event)
            :ok

          {:tool_use_stop, _} = event ->
            StepLog.broadcast_stream_event(inference_session_id, event)
            :ok

          {:usage, _} = event ->
            StepLog.broadcast_stream_event(inference_session_id, event)
            :ok

          _ ->
            :ok
        end

        result =
          Froth.Anthropic.stream_single(
            api_messages,
            on_event,
            system: resolve_system_prompt(chat_id, config),
            model: config.model,
            tools: tool_specs_for_api()
          )

        {:stream_result, inference_session_id, result}
      end)

    StepLog.broadcast_loop(inference_session.id)

    %{
      state
      | tasks: Map.put(state.tasks, task.ref, {:streaming, inference_session.id, task.pid}),
        typing_timers: Map.put(state.typing_timers, inference_session.id, tref)
    }
  end

  defp build_pending_tools(inference_session, tool_uses, state) do
    Enum.map(tool_uses, fn %{"id" => id, "name" => name, "input" => input} ->
      cond do
        name == "send_message" ->
          result =
            case do_send_message(
                   inference_session.chat_id,
                   inference_session.reply_to,
                   input,
                   state
                 ) do
              {:ok, out} -> out
              {:error, msg} -> "error: #{msg}"
            end

          StepLog.append(inference_session.id, "tool_immediate", %{
            "tool_use_id" => id,
            "name" => name,
            "result" => result,
            "text" => if(is_binary(input["text"]), do: input["text"], else: nil),
            "input_preview" => safe_input_preview(input)
          })

          Logger.info(
            event: :inference_tool_immediate,
            inference_session_id: inference_session.id,
            tool_use_id: id,
            tool_name: name,
            is_error: false,
            result_preview: tool_result_preview(result)
          )

          %{
            "tool_use_id" => id,
            "name" => name,
            "input" => input,
            "status" => "resolved",
            "result" => result,
            "is_error" => false
          }

        name in ["elixir_eval", "run_shell", "send_input", "stop_task"] ->
          ref = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

          StepLog.append(inference_session.id, "tool_queued", %{
            "tool_use_id" => id,
            "name" => name,
            "ref" => ref,
            "code" => input["code"],
            "input_preview" => safe_input_preview(input)
          })

          Logger.info(
            event: :inference_tool_queued,
            inference_session_id: inference_session.id,
            tool_use_id: id,
            tool_name: name,
            ref: ref
          )

          %{
            "tool_use_id" => id,
            "name" => name,
            "input" => input,
            "ref" => ref,
            "approval_msg_id" => nil,
            "announce_text" => tool_label(name),
            "status" => "pending",
            "result" => nil,
            "is_error" => false
          }

        true ->
          StepLog.append(inference_session.id, "tool_started", %{
            "tool_use_id" => id,
            "name" => name,
            "auto" => true
          })

          Logger.info(
            event: :inference_tool_auto_start,
            inference_session_id: inference_session.id,
            tool_use_id: id,
            tool_name: name
          )

          {is_error, result} =
            execute_tool(
              name,
              input,
              inference_session.chat_id,
              ref: nil,
              session_id: session_id(state),
              bot_id: bot_id(state)
            )
            |> normalize_tool_execution_result()

          StepLog.append(inference_session.id, "tool_resolved", %{
            "tool_use_id" => id,
            "name" => name,
            "is_error" => is_error,
            "result" => result,
            "result_preview" => tool_result_preview(result)
          })

          Logger.info(
            event: :inference_tool_auto_finish,
            inference_session_id: inference_session.id,
            tool_use_id: id,
            tool_name: name,
            is_error: is_error,
            result_preview: tool_result_preview(result)
          )

          %{
            "tool_use_id" => id,
            "name" => name,
            "input" => input,
            "status" => "resolved",
            "result" => result,
            "is_error" => is_error
          }
      end
    end)
  end

  defp do_resolve_tool(inference_session, _ref, "stop", state) do
    pending_tools =
      Enum.map(inference_session.pending_tools, fn tool ->
        if tool["status"] == "pending" do
          %{tool | "status" => "stopped"}
        else
          tool
        end
      end)

    inference_session
    |> InferenceSession.changeset(%{pending_tools: pending_tools, status: "stopped"})
    |> Repo.update!()

    StepLog.append(inference_session.id, "tools_stopped", %{
      "count" => Enum.count(pending_tools, &(&1["status"] == "stopped"))
    })

    Logger.info(
      event: :inference_tools_stopped,
      inference_session_id: inference_session.id,
      stopped_count: Enum.count(pending_tools, &(&1["status"] == "stopped"))
    )

    send_italic(state, inference_session.chat_id, inference_session.reply_to, "stopped")

    StepLog.broadcast_loop(inference_session.id)
    {:noreply, state}
  end

  defp do_resolve_tool(inference_session, ref, "skip", state) do
    pending_tools =
      Enum.map(inference_session.pending_tools, fn tool ->
        if tool["ref"] == ref and tool["status"] == "pending" do
          %{
            tool
            | "status" => "resolved",
              "result" => "User skipped this tool call.",
              "is_error" => false
          }
        else
          tool
        end
      end)

    inference_session
    |> InferenceSession.changeset(%{pending_tools: pending_tools})
    |> Repo.update!()

    StepLog.append(inference_session.id, "tool_skipped", %{"ref" => ref})

    Logger.info(
      event: :inference_tool_skipped,
      inference_session_id: inference_session.id,
      ref: ref
    )

    StepLog.broadcast_loop(inference_session.id)
    check_all_tools_resolved(inference_session.id, state)
  end

  defp do_resolve_tool(inference_session, ref, "go", state) do
    tool =
      Enum.find(
        inference_session.pending_tools,
        &(&1["ref"] == ref and &1["status"] == "pending")
      )

    if tool do
      pending_tools =
        Enum.map(inference_session.pending_tools, fn t ->
          if t["ref"] == ref, do: %{t | "status" => "executing"}, else: t
        end)

      inference_session
      |> InferenceSession.changeset(%{pending_tools: pending_tools})
      |> Repo.update!()

      inference_session_id = inference_session.id
      tool_use_id = tool["tool_use_id"]
      name = tool["name"]
      input = tool["input"]
      tool_ref = tool["ref"]
      chat_id = inference_session.chat_id

      StepLog.append(inference_session.id, "tool_started", %{
        "ref" => ref,
        "tool_use_id" => tool_use_id,
        "name" => name
      })

      Logger.info(
        event: :inference_tool_manual_start,
        inference_session_id: inference_session.id,
        ref: ref,
        tool_use_id: tool_use_id,
        tool_name: name
      )

      StepLog.broadcast_loop(inference_session.id)

      task =
        Task.async(fn ->
          {is_error, result} =
            execute_tool(
              name,
              input,
              chat_id,
              ref: tool_ref,
              session_id: session_id(state),
              bot_id: bot_id(state)
            )
            |> normalize_tool_execution_result()

          {:tool_result, inference_session_id, tool_use_id, result, is_error}
        end)

      state = %{
        state
        | tasks:
            Map.put(
              state.tasks,
              task.ref,
              {:tool_exec, inference_session.id, tool_use_id, task.pid}
            )
      }

      StepLog.broadcast_loop(inference_session.id)

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  defp find_inference_session_by_ref(ref, state) do
    Repo.one(
      from(c in InferenceSession,
        where:
          c.bot_id == ^bot_id(state) and c.status == "awaiting_tools" and
            fragment(
              "EXISTS (SELECT 1 FROM jsonb_array_elements(?) elem WHERE elem->>'ref' = ? AND elem->>'status' = 'pending')",
              c.pending_tools,
              ^ref
            ),
        limit: 1
      )
    )
  end

  defp update_inference_session_status(inference_session_id, status) do
    case Repo.get(InferenceSession, inference_session_id) do
      nil ->
        :ok

      inference_session ->
        inference_session |> InferenceSession.changeset(%{status: status}) |> Repo.update!()
        StepLog.append(inference_session_id, "status_changed", %{"status" => status})
    end
  end

  defp cancel_inference_session_tasks(state, inference_session_id) do
    {tasks, state} =
      Enum.reduce(state.tasks, {%{}, state}, fn {tref, task_info}, {acc_tasks, acc_state} ->
        case task_info do
          {:streaming, ^inference_session_id, pid} ->
            Process.demonitor(tref, [:flush])
            Process.unlink(pid)
            Process.exit(pid, :kill)
            {acc_tasks, cancel_typing(acc_state, inference_session_id)}

          {:streaming, ^inference_session_id} ->
            Process.demonitor(tref, [:flush])
            {acc_tasks, cancel_typing(acc_state, inference_session_id)}

          {:tool_exec, ^inference_session_id, _tool_use_id, pid} ->
            Process.demonitor(tref, [:flush])
            Process.unlink(pid)
            Process.exit(pid, :kill)
            {acc_tasks, acc_state}

          _ ->
            {Map.put(acc_tasks, tref, task_info), acc_state}
        end
      end)

    %{state | tasks: tasks}
  end

  defp safe_input_preview(input) when is_map(input) do
    case Jason.encode(input) do
      {:ok, json} -> String.slice(json, 0, 1000)
      _ -> inspect(input, limit: 100, printable_limit: 1000)
    end
  end

  defp safe_input_preview(_), do: nil

  defp do_send_message(chat_id, reply_to, input, state) do
    case send_message(state, chat_id, input["text"], reply_to: reply_to) do
      {:ok, _sent} ->
        {:ok, "sent"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp execute_tool(name, input, chat_id, opts) do
    Tools.execute(name, input, chat_id, opts)
  end

  defp send_tool_loop_prompt(inference_session, pending_tools, state) do
    eval_tool =
      Enum.find(
        pending_tools,
        &(&1["status"] == "pending" and &1["name"] == "elixir_eval" and
            is_nil(&1["approval_msg_id"]))
      )

    if eval_tool do
      ref = eval_tool["ref"]
      last_message_id = last_prompt_message_id(inference_session)

      case send_or_edit_eval_prompt(state, inference_session, last_message_id) do
        {:ok, msg_id, action} when is_integer(msg_id) and is_binary(action) ->
          persist_prompt_message_id(inference_session, ref, msg_id, action)

        _ ->
          :ok
      end
    end
  end

  defp persist_prompt_message_id(inference_session, ref, msg_id, action)
       when is_integer(msg_id) and is_binary(action) do
    pending_tools =
      Enum.map(inference_session.pending_tools, fn tool ->
        if tool["ref"] == ref and tool["status"] == "pending" do
          Map.put(tool, "approval_msg_id", msg_id)
        else
          tool
        end
      end)

    inference_session
    |> InferenceSession.changeset(%{pending_tools: pending_tools})
    |> Repo.update!()

    StepLog.append(inference_session.id, "prompt_sent", %{
      "pending_count" => Enum.count(pending_tools, &(&1["status"] == "pending")),
      "mode" => "eval_approval",
      "ref" => ref,
      "message_id" => msg_id,
      "action" => action
    })
  end

  defp last_prompt_message_id(%InferenceSession{tool_steps: steps}) when is_list(steps) do
    steps
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"kind" => "prompt_sent", "data" => %{"message_id" => msg_id}} when is_integer(msg_id) ->
        msg_id

      %{"kind" => "prompt_sent", "data" => %{"message_id" => msg_id}} when is_binary(msg_id) ->
        case Integer.parse(msg_id) do
          {n, ""} -> n
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp last_prompt_message_id(_), do: nil

  defp resolve_system_prompt(chat_id, config) do
    case config.system_prompt_fun do
      prompt_fun when is_function(prompt_fun, 2) ->
        prompt_fun.(chat_id, config)

      prompt_fun when is_function(prompt_fun, 1) ->
        prompt_fun.(chat_id)

      prompt when is_binary(prompt) ->
        prompt

      _ ->
        ""
    end
  end

  defp sort_messages(messages) when is_list(messages) do
    Enum.sort_by(messages, &to_int_or_fallback(&1["id"]))
  end

  defp to_int_or_fallback(v) when is_integer(v), do: v

  defp to_int_or_fallback(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp to_int_or_fallback(_), do: 0

  defp message_unix(%{"date" => v}) when is_integer(v), do: v

  defp message_unix(%{"date" => v}) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp message_unix(_), do: nil

  defp format_new_messages(messages) when is_list(messages) do
    Enum.map_join(messages, "\n\n", fn msg ->
      sender = get_in(msg, ["sender_id", "user_id"]) || "unknown"
      message_id = msg["id"] || "unknown"
      text = get_in(msg, ["content", "text", "text"]) || ""

      """
      <message id=\"#{message_id}\" from=\"#{sender}\">
      #{text}
      </message>
      """
      |> String.trim()
    end)
  end

  defp steering_message_blocks(messages) when is_list(messages) and messages != [] do
    formatted = messages |> sort_messages() |> format_new_messages()

    [
      %{
        "type" => "text",
        "text" =>
          """
          <messages_since_tool_execution_started>
          #{formatted}
          </messages_since_tool_execution_started>

          These messages arrived while you were executing tools. Incorporate them before continuing.
          """
          |> String.trim()
      }
    ]
  end

  defp steering_message_blocks(_), do: []

  defp maybe_start_next_pending_tool(inference_session, state) do
    has_executing =
      Enum.any?(inference_session.pending_tools, fn tool ->
        tool["status"] == "executing"
      end)

    if has_executing do
      {:noreply, state}
    else
      case Enum.find(inference_session.pending_tools, &(&1["status"] == "pending")) do
        %{"ref" => ref} when is_binary(ref) ->
          do_resolve_tool(inference_session, ref, "go", state)

        _ ->
          {:noreply, state}
      end
    end
  end

  defp effect_executor(state) do
    case Map.get(state.config, :effect_executor) do
      module when is_atom(module) ->
        module

      other ->
        raise ArgumentError, "invalid effect_executor in config: #{inspect(other)}"
    end
  end

  defp send_error(state, chat_id, message) do
    effect_executor(state).send_error(state, chat_id, message)
  end

  defp send_italic(state, chat_id, reply_to, text) do
    effect_executor(state).send_italic(state, chat_id, reply_to, text)
  end

  defp send_typing(state, chat_id) do
    effect_executor(state).send_typing(state, chat_id)
  end

  defp send_message(state, chat_id, text, opts) when is_list(opts) do
    effect_executor(state).send_message(state, chat_id, text, opts)
  end

  defp send_or_edit_eval_prompt(state, inference_session, last_message_id) do
    effect_executor(state).send_or_edit_eval_prompt(state, inference_session, last_message_id)
  end

  defp bot_id(state), do: state.config.id
  defp session_id(state), do: state.config.session_id

  defp tool_label(name), do: Tools.label(name)

  defp tool_specs_for_api do
    Tools.specs_for_api()
  end

  # ── Previous session recap ───────────────────────────────────────────

  @recap_sessions_limit 10
  @recap_max_tokens_approx 20000

  defp previous_session_recap(bot_id, chat_id) when is_binary(bot_id) and is_integer(chat_id) do
    # Fetch more sessions than we need, then filter to interesting ones
    sessions =
      Repo.all(
        from(s in InferenceSession,
          where: s.bot_id == ^bot_id and s.chat_id == ^chat_id and s.status == "done",
          order_by: [desc: s.inserted_at],
          limit: 20,
          select: %{id: s.id, inserted_at: s.inserted_at, api_messages: s.api_messages}
        ),
        log: false
      )

    # Filter to sessions that have actual tool work (not just send_message)
    interesting =
      Enum.filter(sessions, fn s ->
        has_real_tools?(s.api_messages)
      end)
      |> Enum.take(@recap_sessions_limit)

    if interesting == [] do
      ""
    else
      sections = Enum.map(interesting, &format_session_recap/1)
      total = Enum.join(sections, "\n\n")

      # Rough token estimate: ~4 chars per token
      if String.length(total) > @recap_max_tokens_approx * 4 do
        # Truncate from oldest, keep newest sessions
        truncate_recap(interesting, @recap_max_tokens_approx * 4)
      else
        total
      end
    end
  end

  defp has_real_tools?(nil), do: false

  defp has_real_tools?(messages) when is_list(messages) do
    Enum.any?(messages, fn msg ->
      case msg do
        %{"role" => "assistant", "content" => content} when is_list(content) ->
          Enum.any?(content, fn block ->
            block["type"] == "tool_use" and block["name"] not in ["send_message"]
          end)

        _ ->
          false
      end
    end)
  end

  defp has_real_tools?(_), do: false

  defp truncate_recap(sessions, max_chars) do
    # Build from newest, stop when we hit the budget
    {sections, _remaining} =
      Enum.reduce(sessions, {[], max_chars}, fn session, {acc, budget} ->
        section = format_session_recap(session)
        len = String.length(section)

        if budget - len > 0 do
          {[section | acc], budget - len}
        else
          {acc, 0}
        end
      end)

    sections |> Enum.reverse() |> Enum.join("\n\n")
  end

  defp format_session_recap(session) do
    messages = session.api_messages || []

    entries =
      Enum.flat_map(messages, fn m ->
        case m do
          %{"role" => "assistant", "content" => content} when is_list(content) ->
            Enum.flat_map(content, fn block ->
              case block do
                %{"type" => "tool_use", "name" => "send_message"} ->
                  # Skip send_message in recap — it's already in the chat log
                  []

                %{"type" => "tool_use", "name" => name, "input" => input} ->
                  snippet = recap_tool_snippet(name, input)
                  [{:call, name, snippet}]

                _ ->
                  []
              end
            end)

          %{"role" => "user", "content" => content} when is_list(content) ->
            Enum.flat_map(content, fn block ->
              case block do
                %{"type" => "tool_result", "content" => result_content, "tool_use_id" => _id} ->
                  result_text = tool_result_recap_text(result_content)

                  # Skip results for send_message (they're always just "sent")
                  if String.trim(result_text) == "sent" do
                    []
                  else
                    [{:result, String.slice(result_text, 0, 500)}]
                  end

                _ ->
                  []
              end
            end)

          _ ->
            []
        end
      end)

    if entries == [] do
      ""
    else
      lines =
        Enum.map(entries, fn
          {:call, name, snippet} -> "\u2192 " <> name <> ": " <> snippet
          {:result, text} -> "  \u2190 " <> String.slice(text, 0, 500)
        end)

      ago = NaiveDateTime.diff(NaiveDateTime.utc_now(), session.inserted_at, :minute)

      "<previous_session id=\"" <>
        Integer.to_string(session.id) <>
        "\" minutes_ago=\"" <>
        Integer.to_string(ago) <>
        "\">\n" <>
        Enum.join(lines, "\n") <>
        "\n</previous_session>"
    end
  end

  defp normalize_tool_execution_result({:ok, out}) do
    {false, normalize_tool_success_content(out)}
  end

  defp normalize_tool_execution_result({:error, msg}) do
    {true, normalize_tool_error_content(msg)}
  end

  defp normalize_tool_execution_result(other) do
    {true, inspect(other, limit: 50, printable_limit: 1000)}
  end

  defp normalize_tool_success_content(out) when is_binary(out), do: out
  defp normalize_tool_success_content(out) when is_list(out), do: out
  defp normalize_tool_success_content(out), do: inspect(out, limit: 50, printable_limit: 2000)

  defp normalize_tool_error_content(msg) when is_binary(msg), do: msg
  defp normalize_tool_error_content(msg), do: inspect(msg, limit: 50, printable_limit: 2000)

  defp tool_result_preview(result) when is_binary(result), do: String.slice(result, 0, 200)

  defp tool_result_preview(result) when is_list(result) do
    result
    |> Enum.map_join(" ", &tool_result_block_preview/1)
    |> String.slice(0, 200)
  end

  defp tool_result_preview(result) do
    result
    |> inspect(limit: 30, printable_limit: 1000)
    |> String.slice(0, 200)
  end

  defp tool_result_block_preview(%{"type" => "text", "text" => text}) when is_binary(text) do
    text |> String.replace(~r/\s+/, " ") |> String.slice(0, 80)
  end

  defp tool_result_block_preview(%{"type" => "image", "source" => source}) when is_map(source) do
    "[image #{source["media_type"] || "unknown"}]"
  end

  defp tool_result_block_preview(%{"type" => "document", "source" => source})
       when is_map(source) do
    "[document #{source["media_type"] || "unknown"}]"
  end

  defp tool_result_block_preview(%{"type" => type}) when is_binary(type), do: "[#{type}]"

  defp tool_result_block_preview(block) do
    inspect(block, limit: 10, printable_limit: 200)
  end

  defp tool_result_recap_text(result_content) when is_binary(result_content), do: result_content

  defp tool_result_recap_text(result_content) when is_list(result_content) do
    Enum.map_join(result_content, "\n", fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        text

      %{"type" => "image", "source" => source} when is_map(source) ->
        "[image #{source["media_type"] || "unknown"}]"

      %{"type" => "document", "source" => source} when is_map(source) ->
        "[document #{source["media_type"] || "unknown"}]"

      %{"type" => type} when is_binary(type) ->
        "[#{type}]"

      other ->
        inspect(other, limit: 10, printable_limit: 200)
    end)
  end

  defp tool_result_recap_text(result_content) do
    inspect(result_content, limit: 30, printable_limit: 2000)
  end

  defp recap_tool_snippet("elixir_eval", input) do
    code = input["code"] || ""

    line =
      code
      |> String.split("\n")
      |> Enum.reject(fn l -> String.trim(l) == "" or String.starts_with?(String.trim(l), "#") end)
      |> List.first() || ""

    String.slice(line, 0, 120)
  end

  defp recap_tool_snippet("run_shell", input), do: String.slice(input["command"] || "", 0, 120)
  defp recap_tool_snippet("search", input), do: "query=" <> inspect(input["query"])
  defp recap_tool_snippet("read_log", input), do: "from=" <> (input["from_date"] || "?")
  defp recap_tool_snippet("look", input), do: "msg=" <> inspect(input["message_id"])

  defp recap_tool_snippet("read_tool_transcript", input),
    do:
      "limit=" <> inspect(input["limit"]) <> " session=" <> inspect(input["inference_session_id"])

  defp recap_tool_snippet("subscribe_task", input), do: "task=" <> (input["task_id"] || "?")
  defp recap_tool_snippet("task_output", input), do: "task=" <> (input["task_id"] || "?")
  defp recap_tool_snippet(_, input), do: inspect(input) |> String.slice(0, 100)
end
