defmodule Froth.LogFormatter do
  @moduledoc """
  Log formatter for terminal/journald.
  Three-line format: source header, data, blank line.
  """

  @dim "\e[2m"
  @reset "\e[0m"
  @red "\e[31m"
  @yellow "\e[33m"
  @bold "\e[1m"

  def format(%{level: level, msg: msg, meta: meta}, _config) do
    message = format_message(msg, meta)
    tag = level_tag(level)
    source = format_source(meta)
    [tag, source, @reset, ?\n, "  ", message, ?\n, @dim, "─", @reset, ?\n]
  rescue
    e -> ["!!! formatter crash: #{Exception.message(e)}\n"]
  end

  defp level_tag(:debug), do: [@dim]
  defp level_tag(:info), do: []
  defp level_tag(:notice), do: []
  defp level_tag(:warning), do: [@yellow]
  defp level_tag(:error), do: [@red, @bold]
  defp level_tag(:critical), do: [@red, @bold]
  defp level_tag(:alert), do: [@red, @bold]
  defp level_tag(:emergency), do: [@red, @bold]
  defp level_tag(_), do: []

  defp format_source(meta) do
    mfa = format_mfa(meta)
    loc = format_loc(meta)

    case {mfa, loc} do
      {[], []} -> ["?"]
      {mfa, []} -> mfa
      {[], loc} -> loc
      {mfa, loc} -> [mfa, " ", @dim, loc]
    end
  end

  defp format_mfa(%{mfa: {mod, fun, arity}}) do
    mod = mod |> Atom.to_string() |> String.replace_leading("Elixir.", "")
    [mod, ".", Atom.to_string(fun), "/", Integer.to_string(arity)]
  end

  defp format_mfa(_), do: []

  defp format_loc(%{file: file, line: line}) when is_integer(line) do
    file = to_string(file) |> String.replace_leading(File.cwd!() <> "/", "")
    [file, ":", Integer.to_string(line)]
  end

  defp format_loc(_), do: []

  defp format_message({:string, msg}, _meta), do: msg

  # Our translator stashes the translation in the report data
  defp format_message({:report, %{elixir_translation: t}}, _meta), do: t
  defp format_message({:report, [{:elixir_translation, t} | _]}, _meta), do: t

  # Keyword list or map — key=value on one line
  defp format_message({:report, data}, _meta) when is_list(data) do
    if Keyword.keyword?(data), do: format_kv(data), else: inspect(data, limit: 30)
  end

  defp format_message({:report, data}, _meta) when is_map(data) do
    format_kv(Map.to_list(data))
  end

  # Erlang format string
  defp format_message({fmt, args}, _meta) do
    :io_lib.format(fmt, args)
  end

  defp format_kv(pairs) do
    Enum.map_intersperse(pairs, " ", fn {k, v} ->
      [@dim, Atom.to_string(k), "=", @reset, format_val(v)]
    end)
  end

  defp format_val(v) when is_binary(v), do: v
  defp format_val(v) when is_atom(v), do: Atom.to_string(v)
  defp format_val(v) when is_integer(v), do: Integer.to_string(v)
  defp format_val(v), do: inspect(v, limit: 10)
end
