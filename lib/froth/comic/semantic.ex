defmodule Froth.Comic.Semantic do
  @moduledoc """
  Infers comic-book expression and balloon hints from chat text.

  The priority-based rules are adapted from Comic Chat's `textpose.cpp` and
  resource-table rules. Explicit message emotions always win.
  """

  @type emotion ::
          :neutral
          | :happy
          | :sad
          | :angry
          | :laughing
          | :coy
          | :scared
          | :bored
          | :surprised

  @spec analyze(map()) :: map()
  def analyze(message) when is_map(message) do
    text = message |> fetch(:text, "") |> to_string()
    explicit = normalize_emotion(fetch(message, :emotion))
    {emotion, intensity} = explicit || infer(text)

    balloon =
      normalize_balloon(fetch(message, :balloon)) ||
        infer_balloon(text, emotion)

    %{
      emotion: emotion,
      intensity: intensity,
      gesture: infer_gesture(text, emotion),
      balloon: balloon
    }
  end

  defp infer(text) do
    lower = String.downcase(text)

    [
      rule(all_caps?(text) or String.contains?(text, "!!!"), :angry, 1.0, 90),
      rule(
        word?(text, "ROTFL") or word?(text, "LOL") or emoji?(text, ["😂", "🤣"]),
        :laughing,
        1.0,
        110
      ),
      rule(
        String.contains?(text, [":-)", ":)"]) or
          emoji?(text, ["😀", "😃", "😄", "😊"]),
        :happy,
        0.9,
        100
      ),
      rule(
        String.contains?(text, [":-(", ":("]) or emoji?(text, ["😢", "😭", "☹"]),
        :sad,
        0.9,
        100
      ),
      rule(
        String.contains?(text, [";-)", ";)"]) or emoji?(text, ["😉"]),
        :coy,
        0.9,
        100
      ),
      rule(
        String.contains?(text, "?!") or emoji?(text, ["😮", "😲"]),
        :surprised,
        0.9,
        85
      ),
      rule(
        String.contains?(lower, ["afraid", "scared", "terrified"]),
        :scared,
        0.8,
        75
      ),
      rule(
        String.contains?(lower, ["angry", "furious", "hate"]),
        :angry,
        0.8,
        75
      ),
      rule(
        String.contains?(lower, ["sad", "sorry", "unhappy"]),
        :sad,
        0.7,
        70
      ),
      rule(
        String.contains?(lower, ["yay", "great", "wonderful", "love"]),
        :happy,
        0.7,
        65
      ),
      rule(
        String.contains?(lower, ["boring", "bored", "whatever"]),
        :bored,
        0.7,
        60
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(& &1.priority, fn ->
      %{emotion: :neutral, intensity: 0.25, priority: 0}
    end)
    |> then(&{&1.emotion, &1.intensity})
  end

  defp infer_balloon(text, _emotion) do
    cond do
      String.starts_with?(String.trim(text), ["*", "/me "]) ->
        :action

      all_caps?(text) or String.contains?(text, "!!!") ->
        :shout

      String.starts_with?(String.trim(text), "(") and
          String.ends_with?(String.trim(text), ")") ->
        :think

      String.ends_with?(String.trim(text), "...") ->
        :whisper

      true ->
        :say
    end
  end

  defp infer_gesture(text, emotion) do
    lower = String.downcase(String.trim(text))

    cond do
      starts_with_word?(lower, ["hi", "hello", "howdy", "welcome", "bye"]) ->
        :wave

      starts_with_word?(lower, ["you"]) or
          phrase?(lower, ["are you", "will you", "did you", "don't you"]) ->
        :point_other

      starts_with_word?(lower, ["i"]) or
          phrase?(lower, ["i'm", "i am", "i will", "i'll"]) ->
        :point_self

      emotion in [:laughing, :happy] ->
        :open

      emotion == :angry ->
        :emphatic

      emotion in [:scared, :surprised] ->
        :recoil

      true ->
        :rest
    end
  end

  defp all_caps?(text) do
    letters = Regex.scan(~r/\p{L}/u, text) |> List.flatten()
    length(letters) > 1 and Enum.all?(letters, &(&1 == String.upcase(&1)))
  end

  defp word?(text, word),
    do:
      Regex.match?(
        ~r/(?:^|\s)#{Regex.escape(word)}(?:$|[\s[:punct:]])/u,
        text
      )

  defp emoji?(text, values),
    do: Enum.any?(values, &String.contains?(text, &1))

  defp phrase?(text, values),
    do: Enum.any?(values, &String.contains?(text, &1))

  defp starts_with_word?(text, words) do
    Enum.any?(
      words,
      &Regex.match?(~r/^#{Regex.escape(&1)}(?:$|[^\p{L}\p{N}_])/u, text)
    )
  end

  defp rule(true, emotion, intensity, priority),
    do: %{emotion: emotion, intensity: intensity, priority: priority}

  defp rule(false, _emotion, _intensity, _priority), do: nil

  defp normalize_emotion(nil), do: nil

  defp normalize_emotion(emotion) when is_binary(emotion) do
    emotion
    |> String.downcase()
    |> String.to_existing_atom()
    |> normalize_emotion()
  rescue
    ArgumentError -> nil
  end

  defp normalize_emotion(emotion)
       when emotion in [
              :neutral,
              :happy,
              :sad,
              :angry,
              :laughing,
              :coy,
              :scared,
              :bored,
              :surprised
            ],
       do: {emotion, 1.0}

  defp normalize_emotion(_emotion), do: nil

  defp normalize_balloon(balloon)
       when balloon in [:say, :whisper, :think, :action, :shout], do: balloon

  defp normalize_balloon(_balloon), do: nil

  defp fetch(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
