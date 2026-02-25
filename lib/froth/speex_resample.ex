defmodule Froth.SpeexResample do
  @moduledoc """
  NIF wrapper around the Speex resampler for sample-rate conversion of
  16-bit signed integer PCM audio.

  ## Usage

      {:ok, r} = Froth.SpeexResample.new(1, 24000, 16000, 4)
      {:ok, out_pcm} = Froth.SpeexResample.process(r, in_pcm)

  Quality ranges from 0 (fastest, lowest quality) to 10 (slowest, best).
  4 is a good default.
  """

  @on_load :load_nif

  def load_nif do
    path = :filename.join(:code.priv_dir(:froth), ~c"speex_resample_nif")
    :erlang.load_nif(path, 0)
  end

  @doc """
  Create a new resampler.

  - `channels` — number of audio channels (1 for mono)
  - `in_rate` — input sample rate in Hz
  - `out_rate` — output sample rate in Hz
  - `quality` — 0..10, higher is better but slower
  """
  def new(channels, in_rate, out_rate, quality \\ 4) do
    nif_new(channels, in_rate, out_rate, quality)
  end

  @doc """
  Resample a binary of interleaved 16-bit signed PCM samples.

  Returns `{:ok, output_binary}` with the resampled audio.
  """
  def process(resampler, input) when is_binary(input) do
    nif_process(resampler, input)
  end

  defp nif_new(_channels, _in_rate, _out_rate, _quality) do
    :erlang.nif_error(:not_loaded)
  end

  defp nif_process(_resampler, _input) do
    :erlang.nif_error(:not_loaded)
  end
end
