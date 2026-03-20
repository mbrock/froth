defmodule Froth.LennartHourly do
  @moduledoc """
  Hourly ping that asks Lennart for a trip report.
  Sends via mbrockman (user) session so Lennart's bot can see it.
  """
  use GenServer
  require Logger

  @chat_id -1003690254489
  @interval :timer.hours(1)

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    schedule_next()
    Logger.info("LennartHourly started — pinging every hour via mbrockman session")
    {:ok, state}
  end

  def handle_info(:ping_lennart, state) do
    prompts = [
      "Lennart, trip report. What's happening out there.",
      "Lennart. Hourly check-in. What's the world doing.",
      "Hey Lennart, what's the news. Give us the rundown.",
      "Lennart, status report from Montreal. What are you seeing.",
      "Trip report time, Lennart. What's going on in the world."
    ]

    prompt = Enum.random(prompts)

    # Send via mbrockman user session — user messages bypass bot privacy mode.
    # Bot-to-bot messages are invisible on Telegram. User-to-bot are not.
    case Froth.Telegram.call("mbrockman", %{
      "@type" => "sendMessage",
      "chat_id" => @chat_id,
      "input_message_content" => %{
        "@type" => "inputMessageText",
        "text" => %{
          "@type" => "formattedText",
          "text" => prompt
        }
      }
    }) do
      {:ok, _} -> Logger.info("LennartHourly: sent ping")
      {:error, reason} -> Logger.error("LennartHourly: failed — #{inspect(reason)}")
    end

    schedule_next()
    {:noreply, state}
  end

  defp schedule_next do
    Process.send_after(self(), :ping_lennart, @interval)
  end
end
