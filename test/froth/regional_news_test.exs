defmodule Froth.RegionalNewsTest do
  use ExUnit.Case, async: false

  alias Froth.RegionalNews

  @location %{
    country: "United States",
    country_code: "US",
    region: "New York",
    city: "New York",
    lat: 40.7128,
    lon: -74.006
  }

  setup do
    original_geolocate = Application.get_env(:froth, :regional_news_geolocate_fun, :__missing__)
    original_query = Application.get_env(:froth, :regional_news_query_fun, :__missing__)

    RegionalNews.reset()

    Application.put_env(:froth, :regional_news_geolocate_fun, fn _ip ->
      {:ok, @location}
    end)

    on_exit(fn ->
      restore_env(:regional_news_geolocate_fun, original_geolocate)
      restore_env(:regional_news_query_fun, original_query)
      RegionalNews.reset()
    end)

    :ok
  end

  test "shares an in-flight stream and replays buffered chunks to new subscribers" do
    parent = self()
    counter = :atomics.new(1, [])

    Application.put_env(:froth, :regional_news_query_fun, fn _location, on_chunk ->
      :atomics.add_get(counter, 1, 1)
      send(parent, {:query_pid, self()})

      on_chunk.("ALPHA")
      send(parent, :first_chunk_sent)

      receive do
        :continue_stream -> :ok
      end

      on_chunk.(" BETA")
      :ok
    end)

    subscriber_one = start_subscriber(parent, :one)
    {:ok, stream_one} = RegionalNews.open_stream("203.0.113.10", subscriber_one)
    assert_receive {:query_pid, query_pid}

    assert stream_one.header =~ "Regional News for New York, New York, United States"
    assert stream_one.chunks == []
    refute stream_one.done?

    assert_receive {:subscriber, :one, {:regional_news_stream, cache_key, {:chunk, "ALPHA"}}}
    assert_receive :first_chunk_sent

    subscriber_two = start_subscriber(parent, :two)
    {:ok, stream_two} = RegionalNews.open_stream("198.51.100.77", subscriber_two)

    assert stream_two.cache_key == cache_key
    assert stream_two.header == stream_one.header
    assert stream_two.chunks == ["ALPHA"]
    refute stream_two.done?

    send(query_pid, :continue_stream)

    assert_receive {:subscriber, :one, {:regional_news_stream, ^cache_key, {:chunk, " BETA"}}}
    assert_receive {:subscriber, :two, {:regional_news_stream, ^cache_key, {:chunk, " BETA"}}}
    assert_receive {:subscriber, :one, {:regional_news_stream, ^cache_key, :done}}
    assert_receive {:subscriber, :two, {:regional_news_stream, ^cache_key, :done}}

    subscriber_three = start_subscriber(parent, :three)
    {:ok, stream_three} = RegionalNews.open_stream("192.0.2.12", subscriber_three)

    assert stream_three.cache_key == cache_key
    assert stream_three.chunks == ["ALPHA", " BETA"]
    assert stream_three.done?
    assert :atomics.get(counter, 1) == 1

    refute_receive {:subscriber, :three, _message}, 50
  end

  defp start_subscriber(parent, tag) do
    spawn_link(fn -> subscriber_loop(parent, tag) end)
  end

  defp subscriber_loop(parent, tag) do
    receive do
      message ->
        send(parent, {:subscriber, tag, message})
        subscriber_loop(parent, tag)
    end
  end

  defp restore_env(key, :__missing__), do: Application.delete_env(:froth, key)
  defp restore_env(key, value), do: Application.put_env(:froth, key, value)
end
