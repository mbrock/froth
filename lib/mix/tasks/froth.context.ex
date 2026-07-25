defmodule Mix.Tasks.Froth.Context do
  import Ecto.Query

  @moduledoc """
  Print Charlie's default Telegram bot context, or inspect the exact
  message-chain request shape for a specific agent cycle.

      mix froth.context
      mix froth.context --messages 20
      mix froth.context --only-messages
      mix froth.context --no-trivial
      mix froth.context --cycle latest
      mix froth.context --cycle latest:3
      mix froth.context --cycle 01KQ...
  """
  @shortdoc "Print Charlie's prompt context via RPC"

  use Mix.Task

  alias Froth.Agent.{Cycle, Message}
  alias Froth.Mix.LiveNode

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          messages: :integer,
          only_messages: :boolean,
          no_trivial: :boolean,
          cycle: :string
        ]
      )

    node = LiveNode.connect!("froth_context")

    case Keyword.get(opts, :cycle) do
      cycle_id when is_binary(cycle_id) and cycle_id != "" ->
        print_cycle_request(node, cycle_id, opts)

      _ ->
        print_bot_context(node, opts)
    end
  end

  defp print_bot_context(node, opts) do
    message_limit = Keyword.get(opts, :messages)
    only_messages = Keyword.get(opts, :only_messages, false)
    no_trivial = Keyword.get(opts, :no_trivial, false)

    {system_prompt, parts} =
      :erpc.call(node, fn ->
        config = Froth.Telegram.Charlie.default_config()
        chat_id = -1_003_690_254_489

        opts = [
          telegram_session_id: config.session_id,
          bot_id: config.id,
          chronicle_dir:
            if(only_messages, do: nil, else: config.chronicle_dir),
          only_nontrivial: no_trivial
        ]

        opts =
          if is_integer(message_limit) and message_limit > 0 do
            [{:recent_message_limit, message_limit} | opts]
          else
            opts
            |> Keyword.put(
              :recent_window_target_hours,
              Map.get(config, :recent_window_target_hours)
            )
            |> Keyword.put(
              :recent_window_min_hours,
              Map.get(config, :recent_window_min_hours)
            )
            |> Keyword.put(
              :recent_window_backfill_hours,
              Map.get(config, :recent_window_backfill_hours)
            )
            |> Keyword.put(
              :recent_window_char_budget,
              Map.get(config, :recent_window_char_budget)
            )
            |> Keyword.put(
              :recent_window_bucket_minutes,
              Map.get(config, :recent_window_bucket_minutes)
            )
          end

        parts = Froth.Telegram.BotContext.render_parts(chat_id, opts)
        system_prompt = config.system_prompt_fun.(chat_id, config)
        {system_prompt, parts}
      end)

    unless only_messages, do: IO.puts(system_prompt)

    parts
    |> Enum.intersperse("\n")
    |> Enum.each(&IO.puts/1)
  end

  defp print_cycle_request(node, cycle_id, opts) do
    reject_cycle_conflicts!(opts)

    case fetch_cycle_request_data(node, cycle_id) do
      {:ok, cycle_requests} ->
        IO.puts(render_cycle_requests(cycle_requests))

      {:error, :not_found} ->
        abort("No agent cycle found for #{cycle_id}")

      {:error, :none_found} ->
        abort("No agent cycles found")

      {:error, :invalid_cycle_selector} ->
        abort(
          "Invalid --cycle selector #{inspect(cycle_id)}. Use a cycle id, latest, or latest:N"
        )
    end
  end

  defp fetch_cycle_request_data(node, cycle_id) when is_binary(cycle_id) do
    :erpc.call(node, fn ->
      case resolve_cycle_selector(cycle_id) do
        {:id, cycle_id} ->
          case Froth.Repo.get(Froth.Agent.Cycle, cycle_id) do
            %Froth.Agent.Cycle{} = cycle ->
              {:ok, [cycle_request(cycle)]}

            nil ->
              {:error, :not_found}
          end

        {:latest, count} ->
          cycles =
            Froth.Repo.all(
              from(c in Froth.Agent.Cycle,
                order_by: [desc: c.inserted_at],
                limit: ^count
              )
            )

          case cycles do
            [] -> {:error, :none_found}
            cycles -> {:ok, Enum.map(cycles, &cycle_request/1)}
          end

        :error ->
          {:error, :invalid_cycle_selector}
      end
    end)
  end

  defp cycle_request(%Cycle{} = cycle) do
    messages =
      cycle
      |> Froth.Agent.list_messages()

    {cycle, messages}
  end

  defp reject_cycle_conflicts!(opts) do
    conflicts =
      []
      |> maybe_add_conflict(opts[:messages], "--messages")
      |> maybe_add_conflict(opts[:only_messages], "--only-messages")
      |> maybe_add_conflict(opts[:no_trivial], "--no-trivial")

    case conflicts do
      [] ->
        :ok

      _ ->
        abort("--cycle cannot be combined with #{Enum.join(conflicts, ", ")}")
    end
  end

  defp maybe_add_conflict(conflicts, value, _flag) when value in [nil, false],
    do: conflicts

  defp maybe_add_conflict(conflicts, _value, flag), do: conflicts ++ [flag]

  @doc false
  def render_cycle_request(%Cycle{} = cycle, messages)
      when is_list(messages) do
    {request_messages, previous_response_id} =
      request_messages_for_cycle(cycle, messages)

    header =
      [
        "cycle ",
        cycle.id || "-",
        " status=",
        to_string(cycle.status || "-"),
        cycle.provider && [" provider=", cycle.provider],
        cycle.model && [" model=", cycle.model]
      ]
      |> Enum.reject(&(&1 in [nil, false]))
      |> IO.iodata_to_binary()

    summary =
      [
        "request_messages=",
        Integer.to_string(length(request_messages)),
        if(previous_response_id,
          do: " previous_response_id=#{previous_response_id}",
          else: ""
        ),
        " system_prompt=not_reconstructed"
      ]
      |> IO.iodata_to_binary()

    sections =
      request_messages
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", &format_cycle_message/1)

    Enum.join([header, summary, sections], "\n\n")
  end

  @doc false
  def render_cycle_requests(cycle_requests) when is_list(cycle_requests) do
    cycle_requests
    |> Enum.map(fn
      {%Cycle{} = cycle, messages} when is_list(messages) ->
        render_cycle_request(cycle, messages)
    end)
    |> Enum.join("\n\n" <> String.duplicate("-", 80) <> "\n\n")
  end

  @doc false
  def request_messages_for_cycle(%Cycle{provider: provider}, messages)
      when is_list(messages) do
    if provider in ["openai", "fakeai"] do
      case latest_openai_response_boundary(messages) do
        {response_id, tail_messages}
        when is_binary(response_id) and response_id != "" and
               is_list(tail_messages) and
               tail_messages != [] ->
          {tail_messages, response_id}

        _ ->
          {messages, nil}
      end
    else
      {messages, nil}
    end
  end

  defp format_cycle_message({%Message{} = message, idx}) do
    api = Message.to_api(message)
    role = Map.get(api, "role", "unknown")
    content = Map.get(api, "content", [])

    [
      "[",
      Integer.to_string(idx),
      "] ",
      role,
      message.id && [" id=", message.id],
      "\n",
      pretty_inspect(content)
    ]
    |> IO.iodata_to_binary()
  end

  defp pretty_inspect(value) do
    inspect(value,
      pretty: true,
      sort_maps: true,
      limit: :infinity,
      printable_limit: :infinity
    )
  end

  defp latest_openai_response_boundary(messages) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {%Message{role: :agent, metadata: metadata}, index}, _acc ->
        case openai_response_id(metadata) do
          response_id when is_binary(response_id) and response_id != "" ->
            {response_id, index}

          _ ->
            nil
        end

      _, acc ->
        acc
    end)
    |> case do
      {response_id, index} ->
        {response_id, Enum.drop(messages, index + 1)}

      nil ->
        nil
    end
  end

  @doc false
  def resolve_cycle_selector("latest"), do: {:latest, 1}

  def resolve_cycle_selector("latest:" <> count) do
    case Integer.parse(count) do
      {value, ""} when value > 0 -> {:latest, value}
      _ -> :error
    end
  end

  def resolve_cycle_selector(cycle_id)
      when is_binary(cycle_id) and cycle_id != "",
      do: {:id, cycle_id}

  defp openai_response_id(metadata) when is_map(metadata) do
    metadata["response_id"] || metadata[:response_id] ||
      response_id_from_message_id(metadata)
  end

  defp openai_response_id(_metadata), do: nil

  defp response_id_from_message_id(metadata) when is_map(metadata) do
    case metadata["message_id"] || metadata[:message_id] do
      "resp_" <> _rest = response_id -> response_id
      _ -> nil
    end
  end

  defp response_id_from_message_id(_metadata), do: nil

  defp abort(message) do
    Mix.shell().error(message)
    System.halt(1)
  end
end
