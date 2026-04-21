defmodule Froth.Follow.Projector do
  @moduledoc false

  alias Froth.Follow.Entry

  @telegram_noise_updates MapSet.new([
                            "authorizationStateWaitTdlibParameters",
                            "ok",
                            "updateAuthorizationState",
                            "updateConnectionState",
                            "updateDefaultReactionType",
                            "updateNewChat",
                            "updateOption",
                            "updateSupergroup",
                            "updateSupergroupFullInfo",
                            "updateUser"
                          ])

  @spec from_live([atom()], map(), map(), keyword()) :: Entry.t()
  def from_live(event_name, measurements, metadata, opts \\ [])
      when is_list(event_name) and is_map(measurements) and is_map(metadata) do
    event = Enum.map_join(event_name, ".", &Atom.to_string/1)

    build_entry(%{
      id: Keyword.get(opts, :id, System.unique_integer([:positive])),
      at: Keyword.get(opts, :at, DateTime.utc_now()),
      event: event,
      measurements: measurements,
      metadata: metadata,
      span_id: metadata[:span_id],
      parent_id: metadata[:parent_id]
    })
  end

  @spec from_row(map()) :: Entry.t()
  def from_row(%{} = row) do
    build_entry(%{
      id: row[:id] || row["id"] || System.unique_integer([:positive]),
      at: row[:inserted_at] || row["inserted_at"],
      event: row[:event] || row["event"] || "froth.unknown",
      measurements: row[:measurements] || row["measurements"] || %{},
      metadata: row[:metadata] || row["metadata"] || %{},
      span_id: row[:span_id] || row["span_id"],
      parent_id: row[:parent_id] || row["parent_id"]
    })
  end

  defp build_entry(%{
         id: id,
         at: at,
         event: event,
         measurements: measurements,
         metadata: metadata,
         span_id: span_id,
         parent_id: parent_id
       }) do
    parts =
      event
      |> String.split(".")
      |> Enum.reject(&(&1 == ""))

    measurements = stringify_keys(measurements)
    metadata = stringify_keys(metadata)
    span_id = stringify_or_nil(span_id || metadata["span_id"])
    parent_id = stringify_or_nil(parent_id || metadata["parent_id"])
    duration_ms = duration_ms(measurements)
    cycle_id = stringify_or_nil(metadata["cycle_id"])
    tool_use_id = stringify_or_nil(metadata["tool_use_id"])
    message_id = stringify_or_nil(metadata["message_id"])

    %{
      family: family,
      kind: kind,
      scope: scope,
      summary: summary,
      detail: detail,
      level: level,
      hidden: hidden
    } = classify(parts, measurements, metadata, duration_ms)

    %Entry{
      id: id,
      at: at,
      event: event,
      family: family,
      kind: kind,
      level: level,
      scope: scope || fallback_scope(cycle_id, span_id),
      summary: summary,
      detail: detail,
      duration_ms: duration_ms,
      cycle_id: cycle_id,
      span_id: span_id,
      parent_id: parent_id,
      tool_use_id: tool_use_id,
      message_id: message_id,
      measurements: measurements,
      metadata: metadata,
      hidden: hidden
    }
  end

  defp classify(["froth", "agent", "cycle", "start"], _m, metadata, _d) do
    %{
      family: "cycle",
      kind: "start",
      scope: short_id(metadata["cycle_id"]),
      summary: "started",
      detail:
        join_detail([
          metadata["model"] && "model=#{metadata["model"]}",
          metadata["provider"] && "provider=#{metadata["provider"]}"
        ]),
      level: :info,
      hidden: false
    }
  end

  defp classify(["froth", "agent", "cycle", "started"], _m, metadata, _d) do
    %{
      family: "cycle",
      kind: "started",
      scope: short_id(metadata["cycle_id"]),
      summary: "started",
      detail:
        join_detail([
          metadata["status"] && "status=#{metadata["status"]}",
          metadata["model"] && "model=#{metadata["model"]}",
          metadata["provider"] && "provider=#{metadata["provider"]}"
        ]),
      level: :info,
      hidden: true
    }
  end

  defp classify(
         ["froth", "agent", "cycle", "stop"],
         _m,
         metadata,
         duration_ms
       ) do
    reason = normalize_string(metadata["reason"])
    phase = normalize_string(metadata["phase"])

    {summary, level} =
      cond do
        reason in ["normal", ":normal"] and phase in ["done", ":done"] ->
          {"completed", :info}

        reason == "yield" ->
          {"yielded", :info}

        reason in [
          "assistant_stopped_without_reply",
          ":assistant_stopped_without_reply"
        ] ->
          {"stopped without reply", :warn}

        reason in [nil, ""] ->
          {"stopped", :info}

        true ->
          {"failed", :error}
      end

    detail =
      join_detail([
        duration_ms && "#{duration_ms}ms",
        reason not in [nil, "", "normal", ":normal", "yield"] &&
          "reason=#{reason}",
        phase not in [nil, "", "done", ":done"] && "phase=#{phase}"
      ])

    %{
      family: "cycle",
      kind: "stop",
      scope: short_id(metadata["cycle_id"]),
      summary: summary,
      detail: detail,
      level: level,
      hidden: false
    }
  end

  defp classify(["froth", "agent", "cycle", kind], _m, metadata, _duration_ms)
       when kind in ["completed", "failed", "cancelled"] do
    summary =
      case kind do
        "completed" -> "completed"
        "failed" -> "failed"
        "cancelled" -> "cancelled"
      end

    detail =
      join_detail([
        metadata["phase"] && "phase=#{metadata["phase"]}",
        metadata["reply_sent"] && "reply_sent=true",
        metadata["stop_reason"] && "stop_reason=#{metadata["stop_reason"]}",
        metadata["error"] && "error=#{truncate(metadata["error"], 120)}"
      ])

    %{
      family: "cycle",
      kind: kind,
      scope: short_id(metadata["cycle_id"]),
      summary: summary,
      detail: detail,
      level: if(kind == "failed", do: :error, else: :info),
      hidden: true
    }
  end

  defp classify(["froth", "agent", "think", "start"], _m, metadata, _d) do
    %{
      family: "think",
      kind: "start",
      scope: short_id(metadata["cycle_id"]),
      summary: "thinking started",
      detail: nil,
      level: :info,
      hidden: false
    }
  end

  defp classify(
         ["froth", "agent", "think", "stop"],
         _m,
         metadata,
         duration_ms
       ) do
    error = normalize_string(metadata["error"])

    %{
      family: "think",
      kind: "stop",
      scope: short_id(metadata["cycle_id"]),
      summary:
        if(error in [nil, ""],
          do: "thinking completed",
          else: "thinking failed"
        ),
      detail:
        join_detail([
          duration_ms && "#{duration_ms}ms",
          error && "error=#{truncate(error, 120)}"
        ]),
      level: if(error in [nil, ""], do: :info, else: :error),
      hidden: false
    }
  end

  defp classify(["froth", "agent", "tool", kind], _m, metadata, duration_ms)
       when kind in ["started", "completed", "failed", "timed_out"] do
    tool_name = metadata["tool_name"] || "tool"

    {summary, level} =
      case kind do
        "started" -> {"started", :info}
        "completed" -> {"completed", :info}
        "failed" -> {"failed", :error}
        "timed_out" -> {"timed out", :error}
      end

    detail =
      join_detail([
        duration_ms && "#{duration_ms}ms",
        metadata["result_type"] && "result=#{metadata["result_type"]}",
        metadata["timeout_ms"] && "timeout=#{metadata["timeout_ms"]}ms",
        metadata["error"] && "error=#{truncate(metadata["error"], 120)}",
        metadata["tool_use_id"] && "call=#{short_id(metadata["tool_use_id"])}",
        metadata["cycle_id"] && "cycle=#{short_id(metadata["cycle_id"])}"
      ])

    %{
      family: "tool",
      kind: kind,
      scope: tool_name,
      summary: summary,
      detail: detail,
      level: level,
      hidden: is_binary(metadata["kind"])
    }
  end

  defp classify(
         ["froth", "agent", "control", "outcome"],
         _m,
         metadata,
         _duration_ms
       ) do
    outcome = normalize_string(metadata["outcome"])
    tool_name = metadata["tool_name"]

    {summary, detail, level} =
      case outcome do
        "reply_sent" ->
          {"reply sent", join_detail([tool_name && "tool=#{tool_name}"]),
           :info}

        "yield" ->
          {"yielded", join_detail([metadata["reason"]]), :info}

        "await_user_input" ->
          {"waiting for answer", join_detail([metadata["reason"]]), :info}

        "waiting_on_subscription" ->
          {"waiting on subscription", join_detail([metadata["reason"]]),
           :info}

        "assistant_stopped_without_reply" ->
          {"stopped without reply", join_detail([metadata["detail"]]), :warn}

        "tool_error" ->
          {"tool error",
           join_detail([
             tool_name && "tool=#{tool_name}",
             metadata["error"] && truncate(metadata["error"], 120)
           ]), :error}

        "cycle_error" ->
          {"cycle error",
           join_detail([
             metadata["error"] && truncate(metadata["error"], 120)
           ]), :error}

        value when is_binary(value) and value != "" ->
          {humanize(value),
           join_detail([
             metadata["reason"],
             metadata["error"],
             metadata["detail"]
           ]), :info}

        _ ->
          {"outcome",
           join_detail([
             metadata["reason"],
             metadata["error"],
             metadata["detail"]
           ]), :info}
      end

    detail =
      join_detail([
        detail,
        metadata["tool_use_id"] && "call=#{short_id(metadata["tool_use_id"])}"
      ])

    %{
      family: "control",
      kind: outcome || "outcome",
      scope: short_id(metadata["cycle_id"]),
      summary: summary,
      detail: detail,
      level: level,
      hidden: false
    }
  end

  defp classify(["froth", "agent", "llm", kind], _m, metadata, duration_ms)
       when kind in ["requested", "completed"] do
    usage = nested_map(metadata["usage"])
    input_tokens = usage["input_tokens"] || metadata["input_tokens"]
    output_tokens = usage["output_tokens"] || metadata["output_tokens"]

    {summary, detail} =
      case kind do
        "requested" ->
          {"request queued",
           join_detail([
             metadata["model"] && "model=#{metadata["model"]}",
             metadata["message_count"] &&
               "messages=#{metadata["message_count"]}",
             metadata["tool_count"] && "tools=#{metadata["tool_count"]}"
           ])}

        "completed" ->
          {"response completed",
           join_detail([
             duration_ms && "#{duration_ms}ms",
             metadata["model"] && "model=#{metadata["model"]}",
             input_tokens && "in=#{input_tokens}",
             output_tokens && "out=#{output_tokens}",
             metadata["stop_reason"] && "stop=#{metadata["stop_reason"]}"
           ])}
      end

    %{
      family: "llm",
      kind: kind,
      scope: provider_label(metadata["provider"] || "llm", metadata["model"]),
      summary: summary,
      detail: detail,
      level: :info,
      hidden: true
    }
  end

  defp classify(
         ["froth", "agent", "message", "appended"],
         _m,
         metadata,
         _duration_ms
       ) do
    role = metadata["role"] || "message"
    preview = metadata["text_preview"]

    %{
      family: "message",
      kind: "appended",
      scope: role,
      summary: "message appended",
      detail:
        join_detail([
          metadata["content_kind"] && "kind=#{metadata["content_kind"]}",
          preview && "text=#{truncate(preview, 120)}"
        ]),
      level: :debug,
      hidden: true
    }
  end

  defp classify(
         ["froth", provider, "request", kind],
         _m,
         metadata,
         duration_ms
       )
       when provider in ["anthropic", "openai", "grok", "gemini"] and
              kind in ["start", "stop", "exception"] do
    model = metadata["model"]
    usage = nested_map(metadata["usage"])
    input_tokens = usage["input_tokens"] || metadata["input_tokens"]
    output_tokens = usage["output_tokens"] || metadata["output_tokens"]
    stop_reason = metadata["stop_reason"]

    {summary, level} =
      case kind do
        "start" -> {"request started", :info}
        "stop" -> {"response completed", :info}
        "exception" -> {"request failed", :error}
      end

    detail =
      join_detail([
        duration_ms && "#{duration_ms}ms",
        model && "model=#{model}",
        input_tokens && "in=#{input_tokens}",
        output_tokens && "out=#{output_tokens}",
        stop_reason && "stop=#{stop_reason}",
        metadata["error"] && "error=#{truncate(metadata["error"], 120)}"
      ])

    %{
      family: "llm",
      kind: kind,
      scope: provider_label(provider, model),
      summary: summary,
      detail: detail,
      level: level,
      hidden: false
    }
  end

  defp classify(["froth", "telegram", "bot", "update"], _m, metadata, _d) do
    action = metadata["action"]
    update_type = metadata["update_type"]
    text = metadata["text"]
    bot_id = metadata["bot_id"]

    hidden =
      action == "ignore" and
        (MapSet.member?(@telegram_noise_updates, to_string(update_type || "")) or
           is_nil(update_type))

    summary =
      cond do
        action == "mention" -> "mention received"
        action == "reply" -> "reply received"
        action == "command" -> "command received"
        action == "ignore" -> "update ignored"
        true -> normalize_string(action) || "update"
      end

    %{
      family: "telegram",
      kind: "update",
      scope: bot_id || "telegram",
      summary: summary,
      detail:
        join_detail([
          update_type && "type=#{update_type}",
          text && "text=#{truncate(text, 120)}",
          metadata["chat_id"] && "chat=#{metadata["chat_id"]}"
        ]),
      level: if(action == "ignore", do: :debug, else: :info),
      hidden: hidden
    }
  end

  defp classify(
         ["froth", "telegram", "bot", "cycle", kind],
         _m,
         metadata,
         duration_ms
       )
       when kind in ["start", "stop"] do
    reason = normalize_string(metadata["reason"])

    %{
      family: "telegram",
      kind: "cycle_#{kind}",
      scope: metadata["bot_id"] || "telegram",
      summary:
        case kind do
          "start" ->
            "bot cycle started"

          "stop" when reason in [nil, "", "normal", ":normal"] ->
            "bot cycle completed"

          "stop" ->
            "bot cycle stopped"
        end,
      detail:
        join_detail([
          metadata["cycle_id"] && "cycle=#{short_id(metadata["cycle_id"])}",
          duration_ms && "#{duration_ms}ms",
          reason not in [nil, "", "normal", ":normal"] && "reason=#{reason}"
        ]),
      level:
        if(kind == "stop" and reason not in [nil, "", "normal", ":normal"],
          do: :warn,
          else: :info
        ),
      hidden: false
    }
  end

  defp classify(["froth", "telegram", "session", kind], _m, metadata, _d) do
    hidden = kind in ["set_tdlib_params", "sync_auth", "connected"]

    %{
      family: "telegram",
      kind: kind,
      scope: metadata["session"] || "telegram",
      summary: "session #{humanize(kind)}",
      detail:
        join_detail([
          metadata["error"] && "error=#{truncate(metadata["error"], 120)}"
        ]),
      level:
        if(kind in ["register_failed", "send_failed", "unexpected"],
          do: :warn,
          else: :info
        ),
      hidden: hidden
    }
  end

  defp classify(["froth", "telegram", "cnode", kind], _m, metadata, _d) do
    hidden =
      kind in ["output", "connect_retry", "register", "node_up", "launching"]

    data = metadata["data"] || metadata["message"]

    %{
      family: "telegram",
      kind: kind,
      scope: "cnode",
      summary: "cnode #{humanize(kind)}",
      detail: data && truncate(safe_string(data), 120),
      level:
        if(kind in ["unexpected", "exited", "node_down"],
          do: :warn,
          else: :info
        ),
      hidden: hidden
    }
  end

  defp classify(
         ["froth", "browser", "instance", kind],
         _m,
         metadata,
         _duration_ms
       ) do
    browser_id = short_browser_id(metadata["browser_id"])
    exit_code = integer_or_nil(metadata["exit_code"])

    {summary, level} =
      case kind do
        "started" ->
          {"browser started", :info}

        "stopped" ->
          {"browser stopped",
           if(exit_code in [nil, 0], do: :info, else: :warn)}

        _ ->
          {"browser #{humanize(kind)}",
           level_for_parts(["froth", "browser", "instance", kind])}
      end

    %{
      family: "browser",
      kind: kind,
      scope: browser_id || "browser",
      summary: summary,
      detail:
        join_detail([
          metadata["profile"] && "profile=#{metadata["profile"]}",
          metadata["debug_port"] && "port=#{metadata["debug_port"]}",
          metadata["os_pid"] && "pid=#{metadata["os_pid"]}",
          is_integer(exit_code) && "exit=#{exit_code}"
        ]),
      level: level,
      hidden: false
    }
  end

  defp classify(
         ["froth", "browser", "session", kind],
         _m,
         metadata,
         _duration_ms
       ) do
    browser_id = short_browser_id(metadata["browser_id"])

    {summary, detail} =
      case kind do
        "screenshot" ->
          {"captured screenshot",
           metadata["path"] && display_path_tail(metadata["path"])}

        "navigated" ->
          {"navigated", metadata["url"] && display_url(metadata["url"])}

        _ ->
          {"session #{humanize(kind)}",
           join_detail([
             metadata["url"] && "url=#{display_url(metadata["url"])}",
             metadata["path"] && "path=#{display_path_tail(metadata["path"])}"
           ])}
      end

    %{
      family: "browser",
      kind: kind,
      scope: browser_id || "browser",
      summary: summary,
      detail: detail,
      level: :info,
      hidden: kind in ["navigated", "screenshot"]
    }
  end

  defp classify(["froth", "browser", "cdp", kind], _m, metadata, _duration_ms) do
    method = browser_method_scope(metadata["method"])
    session_id = short_id(metadata["session_id"])

    {summary, detail} =
      case kind do
        "request" ->
          {"cdp #{method || "request"}",
           join_detail([
             metadata["id"] && "id=#{metadata["id"]}",
             session_id && "session=#{session_id}"
           ])}

        "event" ->
          {"cdp #{method || "event"}",
           join_detail([session_id && "session=#{session_id}"])}

        _ ->
          {"cdp #{humanize(kind)}",
           join_detail([
             method && "method=#{method}",
             session_id && "session=#{session_id}"
           ])}
      end

    %{
      family: "browser",
      kind: kind,
      scope: method || session_id || "cdp",
      summary: summary,
      detail: detail,
      level: :debug,
      hidden: true
    }
  end

  defp classify(["froth", "tasks", kind], _m, metadata, duration_ms) do
    task_id = metadata["task_id"] || metadata["id"]
    exit_code = integer_or_nil(metadata["exit_code"])

    %{
      family: "task",
      kind: kind,
      scope: short_id(task_id) || "task",
      summary: humanize(kind),
      detail:
        join_detail([
          duration_ms && "#{duration_ms}ms",
          metadata["type"] && "type=#{metadata["type"]}",
          metadata["status"] && "status=#{metadata["status"]}",
          is_integer(exit_code) && "exit=#{exit_code}",
          metadata["error"] && "error=#{truncate(metadata["error"], 120)}"
        ]),
      level:
        if(
          kind in ["failed", "stopped", "eval_crashed", "video_crashed"] or
            (is_integer(exit_code) and exit_code != 0),
          do: :error,
          else: :info
        ),
      hidden: false
    }
  end

  defp classify(["froth", "http", "sse" | rest], _m, _metadata, _d) do
    %{
      family: "transport",
      kind: Enum.join(rest, "."),
      scope: "sse",
      summary: "sse #{humanize(List.last(rest) || "event")}",
      detail: nil,
      level: :debug,
      hidden: true
    }
  end

  defp classify(["froth", "http", "request", kind], _m, metadata, duration_ms) do
    %{
      family: "transport",
      kind: kind,
      scope: "http",
      summary: "http #{humanize(kind)}",
      detail:
        join_detail([
          duration_ms && "#{duration_ms}ms",
          metadata["status"] && "status=#{metadata["status"]}",
          metadata["method"] && "method=#{metadata["method"]}"
        ]),
      level: if(kind == "exception", do: :error, else: :debug),
      hidden: true
    }
  end

  defp classify(["froth", "llm", "edit"], _m, metadata, _d) do
    %{
      family: "llm",
      kind: "edit",
      scope: metadata["provider"] || "llm",
      summary: "stream edit",
      detail:
        join_detail([
          metadata["op"] && "op=#{metadata["op"]}",
          metadata["resource_id"] && "resource=#{metadata["resource_id"]}"
        ]),
      level: :debug,
      hidden: true
    }
  end

  defp classify(["froth", "codex", kind], _m, metadata, duration_ms) do
    {summary, level} =
      case kind do
        "pubsub_subscribe" -> {"subscribed", :debug}
        "pubsub_unsubscribe" -> {"unsubscribed", :debug}
        "started" -> {"session started", :info}
        "start_failed" -> {"start failed", :error}
        "notify_send" -> {"notification queued", :debug}
        "notify_sent" -> {"notification sent", :debug}
        "notify_failed" -> {"notification failed", :error}
        "request_send" -> {"request sent", :info}
        "request_queued" -> {"request queued", :info}
        "request_failed_to_send" -> {"request failed to send", :error}
        "data_chunk" -> {"streaming data", :debug}
        "server_exited" -> {"server exited", :error}
        "request_timeout" -> {"request timed out", :error}
        "terminate" -> {"session terminated", :warn}
        "response_received" -> {"response received", :info}
        "notification_received" -> {"notification received", :debug}
        "unknown_message" -> {"unknown message", :warn}
        "invalid_json" -> {"invalid json", :error}
        "unexpected_response" -> {"unexpected response", :warn}
        "request_error_response" -> {"request error response", :error}
        "request_ok_response" -> {"request ok response", :info}
        "send_raw" -> {"raw message sent", :debug}
        "send_failed" -> {"send failed", :error}
        "fail_pending" -> {"failed pending requests", :warn}
        "task_started" -> {"task started", :info}
        "session_codex_exit" -> {"session exited", :warn}
        "notification_failed" -> {"notification failed", :error}
        "events_load_failed" -> {"events load failed", :error}
        "events_list_failed" -> {"events list failed", :error}
        "events_upsert_failed" -> {"events upsert failed", :error}
        "raw_events_list_failed" -> {"raw events list failed", :error}
        "raw_events_append_failed" -> {"raw events append failed", :error}
        _ -> {humanize(kind), level_for_parts(["froth", "codex", kind])}
      end

    detail =
      join_detail([
        duration_ms && "#{duration_ms}ms",
        metadata["method"] &&
          "method=#{browser_method_scope(metadata["method"])}",
        metadata["topic"] && "topic=#{codex_topic_scope(metadata["topic"])}",
        metadata["id"] && "id=#{metadata["id"]}",
        metadata["pending_count"] && "pending=#{metadata["pending_count"]}",
        metadata["timeout_ms"] && "timeout=#{metadata["timeout_ms"]}ms",
        metadata["bytes"] && "bytes=#{metadata["bytes"]}",
        metadata["complete_lines"] && "lines=#{metadata["complete_lines"]}",
        metadata["buffered_bytes"] && "buffered=#{metadata["buffered_bytes"]}",
        metadata["status"] && "status=#{metadata["status"]}",
        metadata["task_id"] && "task=#{short_id(metadata["task_id"])}",
        metadata["cwd"] && "cwd=#{path_label(metadata["cwd"])}",
        metadata["executable"] && "exec=#{path_label(metadata["executable"])}",
        metadata["params_preview"] &&
          "params=#{truncate(safe_string(metadata["params_preview"]), 120)}",
        metadata["raw_preview"] &&
          "reply=#{truncate(safe_string(metadata["raw_preview"]), 120)}",
        metadata["response_preview"] &&
          "reply=#{truncate(safe_string(metadata["response_preview"]), 120)}",
        metadata["error_preview"] &&
          "error=#{truncate(safe_string(metadata["error_preview"]), 120)}",
        metadata["message_preview"] &&
          "message=#{truncate(safe_string(metadata["message_preview"]), 120)}",
        metadata["line_preview"] &&
          "line=#{truncate(safe_string(metadata["line_preview"]), 120)}",
        metadata["reason"] &&
          "reason=#{truncate(safe_string(metadata["reason"]), 120)}",
        metadata["error"] &&
          "error=#{truncate(safe_string(metadata["error"]), 120)}"
      ])

    %{
      family: "codex",
      kind: kind,
      scope: codex_scope(metadata),
      summary: summary,
      detail: detail,
      level: level,
      hidden: codex_hidden?(kind)
    }
  end

  defp classify(parts, _m, metadata, duration_ms) do
    family = family_for_parts(parts)
    kind = List.last(parts) || "event"
    exit_code = integer_or_nil(metadata["exit_code"])

    %{
      family: family,
      kind: kind,
      scope:
        metadata["bot_id"] || metadata["model"] ||
          short_id(metadata["cycle_id"]),
      summary: humanize(kind),
      detail:
        join_detail([
          duration_ms && "#{duration_ms}ms",
          is_integer(exit_code) && "exit=#{exit_code}"
        ]),
      level: exit_level(exit_code) || level_for_parts(parts),
      hidden: hidden_by_default?(parts, metadata)
    }
  end

  defp family_for_parts(["froth", "agent", "tool" | _]), do: "tool"
  defp family_for_parts(["froth", "agent", "cycle" | _]), do: "cycle"
  defp family_for_parts(["froth", "agent", "think" | _]), do: "think"
  defp family_for_parts(["froth", "agent", "control" | _]), do: "control"
  defp family_for_parts(["froth", "agent", "llm" | _]), do: "llm"
  defp family_for_parts(["froth", "agent", "message" | _]), do: "message"
  defp family_for_parts(["froth", "tasks" | _]), do: "task"
  defp family_for_parts(["froth", "codex" | _]), do: "codex"
  defp family_for_parts(["froth", "browser" | _]), do: "browser"
  defp family_for_parts(["froth", "telegram" | _]), do: "telegram"
  defp family_for_parts(["froth", "http" | _]), do: "transport"

  defp family_for_parts(["froth", provider, "request" | _])
       when provider in ["anthropic", "openai", "grok", "gemini"], do: "llm"

  defp family_for_parts(["froth", family | _]), do: family
  defp family_for_parts(_), do: "event"

  defp level_for_parts(parts) do
    case List.last(parts) do
      "exception" -> :error
      "failed" -> :error
      "timed_out" -> :error
      "unexpected" -> :warn
      "exited" -> :warn
      _ -> :info
    end
  end

  defp hidden_by_default?(["froth", "llm", "edit"], _metadata), do: true

  defp hidden_by_default?(["froth", "browser", "cdp" | _], _metadata),
    do: true

  defp hidden_by_default?(["froth", "codex", "data_chunk"], _metadata),
    do: true

  defp hidden_by_default?(
         ["froth", "codex", "notification_received"],
         _metadata
       ), do: true

  defp hidden_by_default?(["froth", "codex", "send_raw"], _metadata), do: true
  defp hidden_by_default?(["froth", "http", "sse" | _], _metadata), do: true

  defp hidden_by_default?(["froth", "http", "request" | _], _metadata),
    do: true

  defp hidden_by_default?(
         ["froth", "telegram", "cnode", "output"],
         _metadata
       ), do: true

  defp hidden_by_default?(["froth", "telegram", "bot", "update"], metadata) do
    metadata["action"] == "ignore" and
      MapSet.member?(
        @telegram_noise_updates,
        safe_string(metadata["update_type"] || "")
      )
  end

  defp hidden_by_default?(_, _metadata), do: false

  defp provider_label(provider, nil), do: normalize_string(provider)

  defp provider_label(provider, model),
    do: "#{safe_string(provider)}:#{safe_string(model)}"

  defp codex_scope(metadata) do
    browser_method_scope(metadata["method"]) ||
      codex_topic_scope(metadata["topic"]) ||
      short_id(metadata["task_id"]) ||
      (metadata["id"] && "req:#{metadata["id"]}") ||
      "codex"
  end

  defp codex_hidden?(kind) do
    kind in [
      "data_chunk",
      "notification_received",
      "send_raw",
      "pubsub_subscribe",
      "pubsub_unsubscribe",
      "notify_send",
      "notify_sent"
    ]
  end

  defp fallback_scope(cycle_id, span_id),
    do: short_id(cycle_id) || short_id(span_id)

  defp duration_ms(measurements) do
    cond do
      is_integer(measurements["duration_ms"]) ->
        measurements["duration_ms"]

      is_integer(measurements["duration"]) ->
        System.convert_time_unit(
          measurements["duration"],
          :native,
          :millisecond
        )

      true ->
        nil
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {safe_string(key), stringify_value(value)}
    end)
  end

  defp stringify_keys(_), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)

  defp stringify_value(value) when is_list(value),
    do: Enum.map(value, &stringify_value/1)

  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value

  defp nested_map(value) when is_map(value), do: stringify_keys(value)
  defp nested_map(_), do: %{}

  defp integer_or_nil(value) when is_integer(value), do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp integer_or_nil(_value), do: nil

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(value), do: safe_string(value)

  defp stringify_or_nil(nil), do: nil
  defp stringify_or_nil(value) when is_binary(value), do: value
  defp stringify_or_nil(value), do: safe_string(value)

  defp short_id(nil), do: nil

  defp short_id(value) do
    value
    |> safe_string()
    |> String.slice(0, 8)
  end

  defp safe_string(value) when is_binary(value), do: value

  defp safe_string(value) do
    try do
      to_string(value)
    rescue
      Protocol.UndefinedError ->
        inspect(value, limit: 8, printable_limit: 160)

      ArgumentError ->
        inspect(value, limit: 8, printable_limit: 160)
    end
  end

  defp short_browser_id(nil), do: nil

  defp short_browser_id(value) do
    value
    |> safe_string()
    |> String.split(":", parts: 2)
    |> List.last()
    |> short_id()
  end

  defp browser_method_scope(nil), do: nil

  defp browser_method_scope(value) do
    value
    |> safe_string()
    |> tail_segments("/", 2)
  end

  defp codex_topic_scope(nil), do: nil

  defp codex_topic_scope(value) do
    value
    |> safe_string()
    |> tail_segments(":", 1)
  end

  defp tail_segments(value, separator, count)
       when is_binary(value) and is_integer(count) and count > 0 do
    value
    |> String.split(separator, trim: true)
    |> Enum.take(-count)
    |> Enum.join(separator)
  end

  defp path_label(nil), do: nil

  defp path_label(value) do
    value
    |> safe_string()
    |> Path.basename()
  end

  defp display_path_tail(nil), do: nil

  defp display_path_tail(value) do
    value
    |> safe_string()
    |> Path.split()
    |> Enum.take(-2)
    |> Path.join()
  end

  defp display_url(nil), do: nil

  defp display_url(value) do
    uri = URI.parse(safe_string(value))

    cond do
      is_binary(uri.host) and is_binary(uri.path) and
          uri.path not in ["", "/"] ->
        uri.host <> uri.path

      is_binary(uri.host) ->
        uri.host

      is_binary(uri.path) and uri.path != "" ->
        uri.path

      true ->
        safe_string(value)
    end
  end

  defp humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
  end

  defp exit_level(code) when is_integer(code) and code != 0, do: :error
  defp exit_level(_code), do: nil

  defp join_detail(parts) do
    parts
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil_or_empty/1)
    |> case do
      [] -> nil
      kept -> Enum.join(kept, " ")
    end
  end

  defp is_nil_or_empty(nil), do: true
  defp is_nil_or_empty(false), do: true
  defp is_nil_or_empty(""), do: true
  defp is_nil_or_empty(_), do: false

  defp truncate(nil, _max), do: nil
  defp truncate(value, _max), do: safe_string(value)
end
