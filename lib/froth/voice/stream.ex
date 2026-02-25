defmodule Voice.Stream do
  @moduledoc """
  An audio timeline. A UUID and a sample rate.

  The database record is the stream's identity. Live audio flows via PubSub
  on the topic `"audio:{id}"`. Producers hold a write head (a map with seq
  and sample counters) and call `push/2` to stamp and broadcast packets.

  ## Creating a stream

      stream = Repo.insert!(%Voice.Stream{rate: 16_000})

  ## Subscribing (any process)

      Voice.Stream.subscribe(stream)
      # now receives %{stream_id: _, seq: _, ts_ms: _, rate: _, pcm: _}

  ## Producing audio

      head = Voice.Stream.write_head(stream)
      head = Voice.Stream.push(head, pcm_chunk)
      # broadcasts a stamped packet, returns updated head
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "streams" do
    field(:rate, :integer)
    timestamps()
  end

  def topic(%__MODULE__{id: id}), do: "audio:#{id}"
  def topic(id) when is_binary(id), do: "audio:#{id}"

  def subscribe(%__MODULE__{} = stream) do
    Phoenix.PubSub.subscribe(Froth.PubSub, topic(stream))
  end

  def subscribe(id) when is_binary(id) do
    Phoenix.PubSub.subscribe(Froth.PubSub, topic(id))
  end

  def write_head(%__MODULE__{id: id, rate: rate}) do
    %{id: id, rate: rate, seq: 0, samples: 0}
  end

  def push(head, pcm) when is_binary(pcm) do
    ts_ms = if head.rate > 0, do: div(head.samples * 1000, head.rate), else: 0
    samples_in_chunk = div(byte_size(pcm), 2)

    packet = %{
      stream_id: head.id,
      seq: head.seq,
      ts_ms: ts_ms,
      rate: head.rate,
      pcm: pcm
    }

    Phoenix.PubSub.broadcast(Froth.PubSub, topic(head.id), packet)

    %{head | seq: head.seq + 1, samples: head.samples + samples_in_chunk}
  end
end
