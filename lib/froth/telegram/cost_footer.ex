defmodule Froth.Telegram.CostFooter do
  @moduledoc """
  Render and attach per-cycle cost footers to Telegram messages.

  The footer looks like:

      [4.2s | 12k in | 3.5k out | 0.8k cw | 2.1k cr | $0.123]

  It is computed from a reloaded `%Froth.Agent.Cycle{}` — the DB row
  is the source of truth for token usage and cost. We attempt to edit
  the last sent message in place; if that would exceed Telegram's
  per-message limit or the edit fails, we fall back to posting the
  footer as a standalone reply.
  """

  alias Froth.Agent.Cycle
  alias Froth.Repo
  alias Froth.Telegram.BotAdapter

  @doc """
  Render a cycle-cost footer string for the given cycle id, or `nil`
  if there's no cost-worthy usage to report yet.
  """
  @spec render_for_cycle_id(String.t()) :: String.t() | nil
  def render_for_cycle_id(cycle_id) when is_binary(cycle_id) do
    case Repo.get(Cycle, cycle_id) do
      %Cycle{usage: usage} = reloaded when is_map(usage) ->
        render(reloaded, usage, reloaded.cost_usd || 0.0)

      _ ->
        nil
    end
  end

  @doc """
  Apply a cost footer to a previously-sent message.

  If `full_text_with_footer` fits in one Telegram message, edit the
  original in place. Otherwise post the footer as a standalone reply.
  On edit failure, fall back to the standalone reply.
  """
  @spec apply(keyword()) :: :ok
  def apply(opts) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    chat_id = Keyword.fetch!(opts, :chat_id)
    last_sent_message_id = Keyword.fetch!(opts, :last_sent_message_id)
    last_sent_message_text = Keyword.fetch!(opts, :last_sent_message_text)
    footer = Keyword.fetch!(opts, :footer)
    reply_to = Keyword.get(opts, :reply_to)

    markdown = String.trim_trailing(last_sent_message_text)
    full_text = append_footer(markdown, footer)

    if String.length(full_text) <= BotAdapter.text_limit() do
      case BotAdapter.edit_message_markdown(
             session_id,
             chat_id,
             last_sent_message_id,
             markdown,
             plain_suffix: "\n\n" <> footer
           ) do
        {:ok, _} ->
          :ok

        {:error, _reason} ->
          send_standalone(session_id, chat_id, reply_to, footer)
      end
    else
      send_standalone(session_id, chat_id, reply_to, footer)
    end
  end

  defp send_standalone(session_id, chat_id, reply_to, footer) do
    _ =
      BotAdapter.send_message(session_id, chat_id, footer, reply_to: reply_to)

    :ok
  end

  defp append_footer(text, footer) do
    trimmed = String.trim_trailing(text)

    if String.ends_with?(trimmed, footer),
      do: trimmed,
      else: trimmed <> "\n\n" <> footer
  end

  defp render(%Cycle{} = cycle, usage, cost_usd) do
    total_in = total_input_tokens(usage)
    total_out = usage_int(usage["output_tokens"])

    if total_in <= 0 and total_out <= 0 do
      nil
    else
      duration = format_seconds(elapsed_seconds(cycle))
      in_part = format_tokens_k(total_in)
      out_part = format_tokens_k(total_out)

      cache_write_part =
        format_tokens_k(usage_int(usage["cache_creation_input_tokens"]))

      cache_read_part =
        format_tokens_k(usage_int(usage["cache_read_input_tokens"]))

      cost = "$" <> :erlang.float_to_binary(cost_usd * 1.0, decimals: 3)

      "[#{duration} | #{in_part} in | #{out_part} out | #{cache_write_part} cw | #{cache_read_part} cr | #{cost}]"
    end
  end

  defp elapsed_seconds(%Cycle{started_at: %DateTime{} = started_at} = cycle) do
    finished_at = cycle.finished_at || DateTime.utc_now()

    DateTime.diff(finished_at, started_at, :millisecond)
    |> max(0)
    |> Kernel./(1000)
  end

  defp elapsed_seconds(_cycle), do: 0.0

  defp format_seconds(seconds) do
    value = if seconds < 0, do: 0.0, else: seconds * 1.0
    :erlang.float_to_binary(value, decimals: 1) <> "s"
  end

  defp format_tokens_k(tokens) when is_integer(tokens) and tokens >= 0 do
    cond do
      tokens == 0 -> "0k"
      rem(tokens, 1000) == 0 -> "#{div(tokens, 1000)}k"
      true -> format_decimal(tokens / 1000, 1) <> "k"
    end
  end

  defp format_tokens_k(_tokens), do: "0k"

  defp format_decimal(number, decimals) do
    number
    |> :erlang.float_to_binary(decimals: decimals)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp total_input_tokens(usage) when is_map(usage) do
    usage_int(usage["input_tokens"]) +
      usage_int(usage["cache_creation_input_tokens"]) +
      usage_int(usage["cache_read_input_tokens"])
  end

  defp usage_int(value) when is_integer(value) and value >= 0, do: value

  defp usage_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp usage_int(_value), do: 0
end
