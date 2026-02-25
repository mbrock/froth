defmodule Mix.Tasks.Froth.Top do
  @moduledoc "Connect to the running node and show processes with non-empty mailboxes."
  @shortdoc "Mailbox monitor for the running node"

  use Mix.Task

  @default_node "froth@igloo"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [interval: :integer, count: :integer])
    interval = Keyword.get(opts, :interval, 500)
    count = Keyword.get(opts, :count, 10)

    node =
      System.get_env("RPC_NODE", @default_node)
      |> String.to_atom()

    cookie =
      case System.get_env("ERLANG_COOKIE") do
        nil -> File.read!(Path.expand("~/.erlang.cookie")) |> String.trim()
        val -> val
      end

    Node.start(:"top_#{System.pid()}", :shortnames)
    Node.set_cookie(String.to_atom(cookie))

    unless Node.connect(node) do
      Mix.shell().error("Could not connect to #{node}")
      System.halt(1)
    end

    IO.puts("#{node} — #{interval}ms\n")
    loop(node, interval, count)
  end

  defp loop(node, interval, count) do
    procs = snapshot(node)
    top = Enum.take(procs, count)

    if top != [] do
      ts = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
      IO.puts("── #{ts} ──")

      Enum.each(top, fn {name, msgq, peek, stack} ->
        IO.puts("  q=#{String.pad_leading(to_string(msgq), 5)}  #{name}")

        Enum.each(peek, fn msg ->
          IO.puts("         #{msg}")
        end)

        if stack != "" do
          IO.puts("         BLOCKED: #{stack}")
        end
      end)

      IO.puts("")
    end

    Process.sleep(interval)
    loop(node, interval, count)
  end

  defp snapshot(node) do
    :erpc.call(node, fn ->
      for pid <- Process.list(),
          info = Process.info(pid, [:message_queue_len, :registered_name, :dictionary]),
          info != nil,
          info[:message_queue_len] > 0 do
        name =
          case info[:registered_name] do
            [] -> otp_name(info[:dictionary])
            nil -> otp_name(info[:dictionary])
            name -> inspect(name)
          end

        msgq = info[:message_queue_len]

        peek =
          case :erlang.process_info(pid, :messages) do
            {:messages, msgs} -> Enum.map(msgs, &summarize_msg/1)
            _ -> []
          end

        stack =
          if msgq >= 3 do
            case :erlang.process_info(pid, :current_stacktrace) do
              {:current_stacktrace, frames} ->
                frames
                |> Enum.reject(fn {m, _f, _a, _loc} -> m in [:proc_lib, :gen_statem, :gen] end)
                |> Enum.take(3)
                |> Enum.map_join(" <- ", fn {m, f, a, _loc} ->
                  "#{inspect(m)}.#{f}/#{a}"
                end)

              _ ->
                ""
            end
          else
            ""
          end

        {name, msgq, peek, stack}
      end
      |> Enum.sort_by(&elem(&1, 1), :desc)
    end)
  end

  defp summarize_msg(%{pcm: pcm} = msg) when is_binary(pcm) do
    seq = Map.get(msg, :seq, "?")
    "pcm:#{byte_size(pcm)}B seq=#{seq}"
  end

  defp summarize_msg({:qwen_client_event, %{"type" => type}}), do: "event:#{type}"
  defp summarize_msg(:ping), do: "ping"
  defp summarize_msg(:mailbox_poll), do: "mailbox_poll"

  defp summarize_msg(msg) when is_tuple(msg) do
    elem(msg, 0) |> inspect() |> String.slice(0, 30)
  end

  defp summarize_msg(msg), do: inspect(msg) |> String.slice(0, 30)

  defp otp_name(dict) when is_list(dict) do
    case List.keyfind(dict, :"$initial_call", 0) do
      {_, {m, f, a}} ->
        m = m |> inspect() |> String.replace("Elixir.", "")
        "#{m}.#{f}/#{a}"

      _ ->
        "?"
    end
  end

  defp otp_name(_), do: "?"
end
