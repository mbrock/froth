defmodule Froth.Agent.FailureIntervention do
  @moduledoc false

  alias Froth.Agent
  alias Froth.Agent.{Cycle, Surface, ToolUse}
  alias Froth.Agent.CycleRuntime.{Context, View}
  alias Froth.Agent.Message, as: AgentMessage
  alias Froth.ApiKeys
  alias LLM.Message, as: LLMMessage
  alias LLM
  alias Froth.Repo
  alias Froth.Telegram.Bot.Config, as: BotConfig
  alias Froth.Telegram.{BotAdapter, MessageIdSync, PendingAsk, PendingAsks}

  @default_reason "Waiting for a human failure intervention."
  @carry_on_answer "__failure_intervention_carry_on__"
  @stop_answer "__failure_intervention_stop__"
  @digit_buttons [
    "1\ufe0f\u20e3",
    "2\ufe0f\u20e3",
    "3\ufe0f\u20e3",
    "4\ufe0f\u20e3"
  ]
  @max_interventions 4
  @max_transcript_chars 8_000
  @max_field_chars 420
  @max_intervention_chars 180

  def carry_on_answer, do: @carry_on_answer
  def stop_answer, do: @stop_answer

  def failure_intervention?(%PendingAsk{config: config})
      when is_map(config) do
    config["kind"] == "failure_intervention"
  end

  def failure_intervention?(_pending_ask), do: false

  def reply_required?(%PendingAsk{} = pending_ask) do
    failure_intervention?(pending_ask) and
      get_in(pending_ask.config, ["require_reply"]) == true
  end

  def reply_required?(_pending_ask), do: false

  def carry_on_answer?(@carry_on_answer), do: true
  def carry_on_answer?(_answer), do: false

  def stop_answer?(@stop_answer), do: true
  def stop_answer?(_answer), do: false

  def maybe_intervene(
        {:error, [%Froth.Context.Block{} | _] = blocks},
        ctx,
        tool_call
      ) do
    # Same trick for the block-list flavor of structured errors: the
    # report builder wants a plain string to quote from. The LLM
    # still sees the full block-rendered output in tool_result.content.
    materialized = Froth.Context.Blocks.materialize(blocks)
    text = Froth.Context.BlockHTML.live_to_string(materialized)
    maybe_intervene({:error, text}, ctx, tool_call)
  end

  def maybe_intervene(
        {:error, error_text},
        %Context{} = ctx,
        %ToolUse{} = tool_call
      )
      when is_binary(error_text) do
    if should_intervene?(ctx, tool_call) do
      rpt = build_report_ctx(ctx, tool_call, error_text)
      report = build_report(rpt)
      {:ok, pending_ask, sent, message_text} = post_report(rpt, report)

      %{
        result: {:await, await_payload(pending_ask, report)},
        sent_message: %{sent: sent, text: message_text},
        awaiting_user_input: true
      }
    else
      {:error, error_text}
    end
  end

  def maybe_intervene(result, _ctx, _tool_call), do: result

  def resolution_config(answer, opts \\ [])
      when is_binary(answer) and is_list(opts) do
    kind =
      cond do
        stop_answer?(answer) -> "stop"
        carry_on_answer?(answer) -> "carry_on"
        Keyword.get(opts, :custom?, false) -> "custom"
        true -> "intervention"
      end

    %{
      "resolution" =>
        %{}
        |> maybe_put("kind", kind)
        |> maybe_put("index", normalize_resolution_index(opts[:index]))
        |> maybe_put("source", resolution_source(opts[:source]))
        |> maybe_put("actor_label", normalize_label(opts[:actor_label]))
        |> maybe_put(
          "actor_id",
          normalize_resolution_actor_id(opts[:actor_id])
        )
    }
  end

  def maybe_finalize_message(%PendingAsk{} = pending_ask, session_id)
      when is_binary(session_id) do
    if failure_intervention?(pending_ask) and
         is_integer(pending_ask.message_id) do
      updated_text =
        pending_ask.question <> "\n\n" <> decision_line(pending_ask)

      BotAdapter.edit_message_text(
        session_id,
        pending_ask.chat_id,
        pending_ask.message_id,
        updated_text,
        reply_markup: %{"@type" => "replyMarkupInlineKeyboard", "rows" => []}
      )
    else
      :ok
    end
  end

  def maybe_finalize_message(_pending_ask, _session_id), do: :ok

  def resume_tool_result(%PendingAsk{} = pending_ask) do
    answer = pending_ask.answer || ""

    cond do
      stop_answer?(answer) ->
        :stop

      carry_on_answer?(answer) ->
        %{
          "type" => "tool_result",
          "tool_use_id" => pending_ask.tool_use_id,
          "content" => original_error(pending_ask),
          "is_error" => true
        }

      true ->
        %{
          "type" => "tool_result",
          "tool_use_id" => pending_ask.tool_use_id,
          "content" => resume_note(pending_ask),
          "is_error" => true
        }
    end
  end

  defp should_intervene?(
         %Context{
           cycle_id: cycle_id,
           bot_config: %BotConfig{id: bot_id, session_id: session_id},
           surface: %Surface{chat_id: chat_id}
         },
         %ToolUse{id: tool_use_id, name: name}
       )
       when is_binary(cycle_id) and is_binary(tool_use_id) and
              is_binary(session_id) and
              is_binary(bot_id) and is_integer(chat_id) do
    enabled?() and supported_tool?(name)
  end

  defp should_intervene?(_ctx, _tool_call), do: false

  defp enabled? do
    Application.get_env(:froth, __MODULE__, [])
    |> Keyword.get(:enabled, false)
  end

  defp supported_tool?(name) when is_binary(name) do
    configured =
      Application.get_env(:froth, __MODULE__, [])
      |> Keyword.get(:tool_names, ["run_shell", "elixir_eval"])

    name in configured
  end

  defp supported_tool?(_name), do: false

  defp build_report_ctx(%Context{} = ctx, %ToolUse{} = tool_call, error_text) do
    %Cycle{} = cycle = Repo.get!(Cycle, ctx.cycle_id)
    messages = Agent.list_messages(cycle)

    %{
      cycle: cycle,
      ctx: ctx,
      tool_call: tool_call,
      messages: messages,
      transcript: render_transcript(messages),
      error_text: error_text,
      initial_intention: initial_intention(messages),
      reply_to: reply_target(ctx, tool_call)
    }
  end

  defp build_report(rpt) when is_map(rpt) do
    {:ok, report} = llm_report(rpt)
    report
  end

  defp llm_report(rpt) when is_map(rpt) do
    prompt = report_prompt(rpt)
    model = report_model(rpt)
    provider = LLM.provider_name_for_model(model)

    response =
      LLM.stream_single(
        [LLMMessage.user(prompt)],
        fn _event -> :ok end,
        model: model,
        provider: provider,
        api_key: ApiKeys.active_key_for_provider(provider),
        max_tokens: 16_384,
        tools: [deliver_failure_report_spec()],
        system: report_system_prompt()
      )

    with {:ok, %{content: content}} <- response,
         %{"input" => input} <- deliver_failure_report_tool_use(content) do
      {:ok, normalize_report(input, rpt)}
    end
  end

  # Prefer an explicitly-configured diagnostic model if the bot sets one;
  # otherwise fall back to whatever model the cycle itself is running on.
  # That way failure intervention works out of the box for every bot,
  # and you can still opt into a cheaper / differently-tuned report
  # model via `Bot.Config{failure_report_model: "..."}`.
  defp report_model(%{
         ctx: %Context{bot_config: %BotConfig{failure_report_model: model}}
       })
       when is_binary(model) and model != "",
       do: model

  defp report_model(%{ctx: %Context{bot_config: %BotConfig{model: model}}})
       when is_binary(model) and model != "",
       do: model

  defp post_report(rpt, report) when is_map(rpt) and is_map(report) do
    %Context{
      bot_config: %BotConfig{id: bot_id} = bc,
      surface: %Surface{session_id: session_id, chat_id: chat_id}
    } = rpt.ctx

    %ToolUse{id: tool_use_id} = rpt.tool_call

    message_text = render_report_message(report)
    reply_markup = report_reply_markup(report, rpt.ctx)

    case BotAdapter.send_message(session_id, chat_id, message_text,
           reply_to: rpt.reply_to,
           reply_markup: reply_markup
         ) do
      {:ok, sent} ->
        with {:ok, message_id} <- sent_message_id(sent),
             pending_ask_id =
               MessageIdSync.resolve(bot_id, chat_id, message_id),
             {:ok, pending_ask} <-
               PendingAsks.create(%{
                 cycle_id: rpt.cycle.id,
                 bot_id: bot_id,
                 chat_id: chat_id,
                 message_id: pending_ask_id,
                 tool_use_id: tool_use_id,
                 question: message_text,
                 alternatives: interventions(report),
                 config: report_config(rpt, report, bc)
               }) do
          pending_ask =
            maybe_refresh_pending_ask_message_id(
              pending_ask,
              bot_id,
              chat_id,
              message_id
            )

          {:ok, pending_ask, sent, message_text}
        end

      error ->
        error
    end
  end

  defp await_payload(%PendingAsk{} = pending_ask, report)
       when is_map(report) do
    %{
      "kind" => "failure_intervention",
      "reason" => @default_reason,
      "pending_ask_id" => pending_ask.id,
      "question_message_id" => pending_ask.message_id,
      "designation" => report["designation"]
    }
  end

  defp report_config(rpt, report, %BotConfig{} = bc) do
    %Context{tool_specs: tool_specs, cycle: cycle} = rpt.ctx
    %ToolUse{name: tool_name} = rpt.tool_call

    %{}
    |> Map.put("kind", "failure_intervention")
    |> Map.put("require_reply", true)
    |> maybe_put("system", rpt.ctx.system_prompt)
    |> maybe_put("model", bc.model)
    |> maybe_put("tools", tool_specs || [])
    |> maybe_put("thinking", stringify_map(bc.thinking || %{}))
    |> maybe_put("effort", bc.effort)
    |> maybe_put("tool_name", tool_name)
    |> maybe_put("provider", cycle && cycle.provider)
    |> maybe_put("original_error", rpt.error_text)
    |> Map.put("report", stringify_map(report))
  end

  defp report_system_prompt do
    """
    Diagnose a failed agent tool call. Focus on whether the agent seems stuck, disoriented,
    confabulating, careless, obstinate, or ordinary. Call deliver_failure_report exactly once.

    Keep every field terse and concrete.
    - intention: the task the agent was trying to complete
    - situation: what has happened so far
    - invocation: the exact action that triggered the failure
    - expectation: what the agent expected to happen
    - irritation: brief prose with the most salient error details verbatim
    - designation: a concise adjectival phrase
    - intervention: zero to four short steering suggestions for a human
    """
    |> String.trim()
  end

  defp report_prompt(rpt) when is_map(rpt) do
    %ToolUse{name: name, input: input} = rpt.tool_call

    """
    Assess this failed cycle and call deliver_failure_report once.

    Intention guess:
    #{rpt.initial_intention}

    Failed tool:
    #{name}

    Tool invocation:
    #{format_invocation(name, input)}

    Error:
    #{rpt.error_text}

    Cycle transcript:
    #{rpt.transcript}
    """
    |> String.trim()
  end

  defp deliver_failure_report_spec do
    %{
      "name" => "deliver_failure_report",
      "description" =>
        "Submit a terse characterization of the failure and possible interventions.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "intention" => %{"type" => "string"},
          "situation" => %{"type" => "string"},
          "invocation" => %{"type" => "string"},
          "expectation" => %{"type" => "string"},
          "irritation" => %{"type" => "string"},
          "designation" => %{"type" => "string"},
          "intervention" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "maxItems" => @max_interventions
          }
        },
        "required" => [
          "intention",
          "situation",
          "invocation",
          "expectation",
          "irritation",
          "designation"
        ],
        "additionalProperties" => false
      }
    }
  end

  defp deliver_failure_report_tool_use(content) when is_list(content) do
    Enum.find(content, fn
      %{
        "type" => "tool_use",
        "name" => "deliver_failure_report",
        "input" => %{}
      } ->
        true

      _ ->
        false
    end)
  end

  defp deliver_failure_report_tool_use(_content), do: nil

  # The `deliver_failure_report` tool schema declares intention, situation,
  # invocation, expectation, irritation, and designation as required
  # string fields, so a well-formed LLM call will supply all of them. We
  # only cap per-field length so Telegram rendering stays sane; any
  # missing required field will just come through as nil and render
  # blank, which is a louder signal than substituting a canned fallback.
  defp normalize_report(input, _rpt) when is_map(input) do
    %{
      "intention" => cap_field(input["intention"]),
      "situation" => cap_field(input["situation"]),
      "invocation" => cap_field(input["invocation"]),
      "expectation" => cap_field(input["expectation"]),
      "irritation" => cap_field(input["irritation"]),
      "designation" => cap_field(input["designation"]),
      "intervention" =>
        input |> Map.get("intervention", []) |> normalize_interventions()
    }
  end

  defp render_report_message(report) when is_map(report) do
    fields = [
      {"Intention", report["intention"]},
      {"Situation", report["situation"]},
      {"Invocation", report["invocation"]},
      {"Expectation", report["expectation"]},
      {"Irritation", report["irritation"]},
      {"Designation", report["designation"]}
    ]

    interventions_block =
      case interventions(report) do
        [] ->
          nil

        items ->
          numbered =
            items
            |> Enum.with_index(1)
            |> Enum.map_join("\n", fn {item, index} -> "#{index}. #{item}" end)

          "Interventions\n#{numbered}"
      end

    [
      "Failure intervention",
      nil,
      Enum.map_join(fields, "\n\n", fn {label, value} ->
        "#{label}\n#{value}"
      end),
      interventions_block
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp report_reply_markup(report, %Context{} = ctx) when is_map(report) do
    intervention_buttons =
      report
      |> interventions()
      |> Enum.with_index()
      |> Enum.map(fn {_text, index} ->
        %{
          "@type" => "inlineKeyboardButton",
          "text" => Enum.at(@digit_buttons, index),
          "type" => %{
            "@type" => "inlineKeyboardButtonTypeCallback",
            "data" => Base.encode64("ask:#{index}")
          }
        }
      end)

    second_row =
      [
        %{
          "@type" => "inlineKeyboardButton",
          "text" => "\u{1F918}",
          "type" => %{
            "@type" => "inlineKeyboardButtonTypeCallback",
            "data" => Base.encode64("askcarry:0")
          }
        },
        maybe_open_button(ctx),
        %{
          "@type" => "inlineKeyboardButton",
          "text" => "\u{1F645}",
          "type" => %{
            "@type" => "inlineKeyboardButtonTypeCallback",
            "data" => Base.encode64("askstop:0")
          }
        }
      ]
      |> Enum.reject(&is_nil/1)

    rows =
      []
      |> maybe_put_row(intervention_buttons)
      |> maybe_put_row(second_row)

    %{"@type" => "replyMarkupInlineKeyboard", "rows" => rows}
  end

  defp maybe_open_button(%Context{
         cycle_id: cycle_id,
         bot_config: %BotConfig{id: bot_id, bot_username: bot_username}
       })
       when is_binary(bot_id) and bot_id != "" and is_binary(bot_username) and
              bot_username != "" and
              is_binary(cycle_id) and cycle_id != "" do
    %{
      "@type" => "inlineKeyboardButton",
      "text" => "\u{1F50D}",
      "type" => %{
        "@type" => "inlineKeyboardButtonTypeUrl",
        "url" =>
          "https://t.me/#{bot_username}/tool?startapp=cycle_#{bot_id}_#{cycle_id}"
      }
    }
  end

  defp maybe_open_button(_ctx), do: nil

  defp maybe_put_row(rows, []), do: rows
  defp maybe_put_row(rows, row) when is_list(row), do: rows ++ [row]

  defp sent_message_id(%{"id" => id}) when is_integer(id), do: {:ok, id}

  defp sent_message_id(%{"id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_message_id}
    end
  end

  defp sent_message_id(_sent), do: {:error, :invalid_message_id}

  defp maybe_refresh_pending_ask_message_id(
         pending_ask,
         bot_id,
         chat_id,
         original_message_id
       )
       when is_map(pending_ask) and is_binary(bot_id) and is_integer(chat_id) and
              is_integer(original_message_id) do
    resolved_message_id =
      MessageIdSync.resolve(bot_id, chat_id, original_message_id)

    if is_integer(resolved_message_id) and
         resolved_message_id != pending_ask.message_id do
      PendingAsks.sync_message_id(
        bot_id,
        chat_id,
        pending_ask.message_id,
        resolved_message_id
      )

      %{pending_ask | message_id: resolved_message_id}
    else
      pending_ask
    end
  end

  defp maybe_refresh_pending_ask_message_id(
         pending_ask,
         _bot_id,
         _chat_id,
         _original_message_id
       ),
       do: pending_ask

  defp interventions(report) when is_map(report) do
    normalize_interventions(report["intervention"])
  end

  defp normalize_interventions(interventions) when is_list(interventions) do
    interventions
    |> Enum.map(&normalize_intervention_text/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@max_interventions)
  end

  defp normalize_interventions(intervention) when is_binary(intervention) do
    normalize_interventions([intervention])
  end

  defp normalize_interventions(_interventions), do: []

  defp normalize_intervention_text(text) when is_binary(text) do
    text
    |> String.trim()
    |> truncate(@max_intervention_chars)
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_intervention_text(_text), do: nil

  defp render_transcript(messages) when is_list(messages) do
    messages
    |> Enum.map(&render_transcript_message/1)
    |> Enum.join("\n\n")
    |> truncate_tail(@max_transcript_chars)
  end

  defp render_transcript_message(%AgentMessage{role: role, content: content}) do
    role_label =
      case role do
        :user -> "user"
        :agent -> "assistant"
      end

    "#{role_label}: #{render_transcript_content(content)}"
  end

  defp render_transcript_content(blocks) when is_list(blocks) do
    blocks
    |> Enum.map_join(" ", fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        text

      %{"type" => "tool_use", "name" => name, "input" => input} ->
        "tool_use #{name} #{encode_json(input)}"

      %{"type" => "tool_result", "content" => result, "is_error" => true} ->
        "tool_error #{render_tool_result(result)}"

      %{"type" => "tool_result", "content" => result} ->
        "tool_result #{render_tool_result(result)}"

      other ->
        inspect(other, limit: 12, printable_limit: 400)
    end)
    |> String.trim()
  end

  defp render_transcript_content(text) when is_binary(text), do: text

  defp render_transcript_content(other),
    do: inspect(other, limit: 12, printable_limit: 400)

  defp render_tool_result(result) when is_binary(result),
    do: truncate(result, 280)

  defp render_tool_result(result), do: truncate(inspect(result), 280)

  defp initial_intention(messages) when is_list(messages) do
    messages
    |> Enum.find_value(fn
      %AgentMessage{role: :user} = message ->
        AgentMessage.extract_text(message)

      _ ->
        nil
    end)
    |> cap_field()
  end

  defp reply_target(
         %Context{
           bot_config: %BotConfig{id: bot_id},
           surface: %Surface{chat_id: chat_id, reply_to: reply_to},
           view: view
         },
         _tool_call
       )
       when is_binary(bot_id) and is_integer(chat_id) do
    last_agent_message_id =
      case view do
        %View{last_sent: %{id: id}} when is_integer(id) -> id
        _ -> nil
      end

    candidate = last_agent_message_id || reply_to

    if is_integer(candidate) do
      MessageIdSync.resolve(bot_id, chat_id, candidate)
    else
      candidate
    end
  end

  defp reply_target(_ctx, _tool_call), do: nil

  defp format_invocation("run_shell", %{"command" => command})
       when is_binary(command) do
    "run_shell command=#{inspect(command)}"
  end

  defp format_invocation("elixir_eval", %{"code" => code})
       when is_binary(code) do
    "elixir_eval code=#{inspect(truncate(code, 220))}"
  end

  defp format_invocation(name, input)
       when is_binary(name) and is_map(input) do
    "#{name} #{encode_json(input)}"
  end

  defp format_invocation(name, _input) when is_binary(name), do: name
  defp format_invocation(_name, _input), do: "tool invocation"

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> truncate(encoded, 260)
      _ -> truncate(inspect(value), 260)
    end
  end

  defp resume_note(%PendingAsk{} = pending_ask) do
    report = get_in(pending_ask.config, ["report"]) || %{}
    answer = pending_ask.answer || ""

    intervention_line =
      case get_in(pending_ask.config, ["resolution", "kind"]) do
        "custom" ->
          actor = get_in(pending_ask.config, ["resolution", "actor_label"])

          if is_binary(actor) and actor != "" do
            "Custom intervention from #{actor}: #{answer}"
          else
            "Custom intervention: #{answer}"
          end

        _ ->
          "Chosen intervention: #{answer}"
      end

    [
      "Failure report",
      nil,
      "Intention: #{report["intention"]}",
      "Situation: #{report["situation"]}",
      "Invocation: #{report["invocation"]}",
      "Expectation: #{report["expectation"]}",
      "Irritation: #{report["irritation"]}",
      "Designation: #{report["designation"]}",
      intervention_line,
      nil,
      "Original error",
      original_error(pending_ask)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp original_error(%PendingAsk{} = pending_ask) do
    get_in(pending_ask.config, ["original_error"]) || "tool failed"
  end

  defp decision_line(%PendingAsk{} = pending_ask) do
    resolution = pending_ask.config["resolution"] || %{}
    actor = normalize_label(resolution["actor_label"])

    case resolution["kind"] do
      "carry_on" ->
        join_actor("→ Carried on 🤘", actor)

      "stop" ->
        join_actor("→ Stopped", actor)

      "custom" ->
        join_actor("→ Custom intervention recorded", actor)

      "intervention" ->
        index =
          case resolution["index"] do
            value when is_integer(value) and value >= 0 -> value + 1
            _ -> nil
          end

        label =
          if is_integer(index) do
            "→ Intervention ##{index} chosen"
          else
            "→ Intervention chosen"
          end

        join_actor(label, actor)

      _ ->
        "→ Decision recorded"
    end
  end

  defp join_actor(label, nil), do: label
  defp join_actor(label, actor), do: "#{label} by #{actor}"

  defp cap_field(value) when is_binary(value) do
    case value |> String.trim() |> truncate(@max_field_chars) do
      "" -> nil
      text -> text
    end
  end

  defp cap_field(_value), do: nil

  defp resolution_source(value) when value in ["callback", "message"],
    do: value

  defp resolution_source(value) when value in [:callback, :message],
    do: Atom.to_string(value)

  defp resolution_source(_value), do: nil

  defp normalize_resolution_index(value)
       when is_integer(value) and value >= 0, do: value

  defp normalize_resolution_index(_value), do: nil

  defp normalize_resolution_actor_id(value) when is_integer(value), do: value
  defp normalize_resolution_actor_id(_value), do: nil

  defp normalize_label(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      label -> label
    end
  end

  defp normalize_label(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)

  defp stringify_value(value) when is_list(value),
    do: Enum.map(value, &stringify_value/1)

  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value

  defp truncate(text, limit)
       when is_binary(text) and is_integer(limit) and limit > 3 do
    if String.length(text) > limit do
      String.slice(text, 0, limit - 3) <> "..."
    else
      text
    end
  end

  defp truncate(text, _limit) when is_binary(text), do: text
  defp truncate(value, _limit), do: inspect(value)

  # Keep the LAST `limit` characters, with a leading "..." when clipped.
  # Used for cycle transcripts where the most recent turns (the failing
  # tool call and its immediate context) matter more than the ancient
  # preamble. The old `truncate/2` did the opposite and would feed the
  # diagnostic agent only the stale opening of a long conversation.
  defp truncate_tail(text, limit)
       when is_binary(text) and is_integer(limit) and limit > 3 do
    len = String.length(text)

    if len > limit do
      "..." <> String.slice(text, len - (limit - 3), limit - 3)
    else
      text
    end
  end

  defp truncate_tail(text, _limit) when is_binary(text), do: text
  defp truncate_tail(value, _limit), do: inspect(value)
end
