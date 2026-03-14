defmodule Froth.Jbo.Dictionary do
  @moduledoc false

  use GenServer

  require Logger
  require Record

  alias Froth.Jbo.Entry

  Record.defrecord(
    :xmlAttribute,
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecord(
    :xmlElement,
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecord(
    :xmlText,
    :xmlText,
    Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
  )

  @name __MODULE__
  @lookup_timeout 120_000
  @result_limit 16
  @related_limit 10
  @source_label "bundled jbovlaste XML"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def summary do
    GenServer.call(@name, :summary, @lookup_timeout)
  end

  def lookup(query, selected_word \\ nil) do
    GenServer.call(@name, {:lookup, query, selected_word}, @lookup_timeout)
  end

  def reset do
    GenServer.call(@name, :reset, @lookup_timeout)
  end

  @impl true
  def init(_opts) do
    {:ok, maybe_preload(%{data: nil, load_error: nil})}
  end

  @impl true
  def handle_call(:summary, _from, state) do
    case ensure_loaded(state) do
      {:ok, data, state} ->
        {:reply, {:ok, data.summary}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lookup, query, selected_word}, _from, state) do
    case ensure_loaded(state) do
      {:ok, data, state} ->
        {:reply, {:ok, do_lookup(data, query, selected_word)}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | data: nil, load_error: nil}}
  end

  defp maybe_preload(state) do
    if preload_dictionary?() do
      case load_dictionary() do
        {:ok, data} ->
          %{state | data: data, load_error: nil}

        {:error, reason} ->
          Logger.error("Dictionary load failed: #{reason}")
          %{state | load_error: reason}
      end
    else
      state
    end
  end

  defp ensure_loaded(%{data: nil} = state) do
    case load_dictionary() do
      {:ok, data} -> {:ok, data, %{state | data: data, load_error: nil}}
      {:error, reason} -> {:error, reason, %{state | load_error: reason}}
    end
  end

  defp ensure_loaded(%{data: data} = state), do: {:ok, data, state}

  defp load_dictionary do
    with {:ok, source} <- fetch_source(),
         {:ok, data} <- parse_source(source) do
      {:ok, data}
    end
  end

  defp fetch_source do
    case Application.get_env(:froth, :jbo_dictionary_fetch_fun) do
      fun when is_function(fun, 0) ->
        normalize_source(fun.())

      _ ->
        read_local_source()
    end
  end

  defp read_local_source do
    path = source_path()

    with {:ok, xml} when is_binary(xml) <- File.read(path),
         false <- xml == "",
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path) do
      {:ok,
       %{
         xml: xml,
         source_url: nil,
         source_label: @source_label,
         source_last_modified: format_source_timestamp(mtime),
         source_path: path
       }}
    else
      true ->
        {:error, "dictionary source is empty: #{path}"}

      {:error, reason} ->
        {:error, "failed to read dictionary source #{path}: #{inspect(reason)}"}
    end
  end

  defp normalize_source({:ok, xml}) when is_binary(xml) do
    {:ok,
     %{
       xml: xml,
       source_url: "fixture",
       source_label: "fixture",
       source_last_modified: nil,
       source_path: "fixture"
     }}
  end

  defp normalize_source({:ok, %{xml: xml} = source}) when is_binary(xml) do
    {:ok,
     %{
       xml: xml,
       source_url: Map.get(source, :source_url, "fixture"),
       source_label: Map.get(source, :source_label, "fixture"),
       source_last_modified: Map.get(source, :source_last_modified),
       source_path: Map.get(source, :source_path, "fixture")
     }}
  end

  defp normalize_source({:error, reason}), do: {:error, to_error(reason)}

  defp normalize_source(other),
    do: {:error, "unexpected dictionary source response: #{inspect(other)}"}

  defp source_path do
    Application.get_env(:froth, :jbo_dictionary_source_path, default_source_path())
  end

  defp default_source_path do
    Path.join(:code.priv_dir(:froth), "jbo/jbovlaste.en.xml")
  end

  defp parse_source(%{xml: xml} = source) do
    try do
      {document, _rest} = :xmerl_scan.string(:erlang.binary_to_list(xml), quiet: true)

      entries =
        document
        |> valsi_elements()
        |> Enum.map(&parse_entry/1)
        |> Enum.reject(&is_nil/1)

      {:ok, build_dictionary(entries, source)}
    rescue
      error ->
        {:error, "failed to parse dictionary XML: #{Exception.message(error)}"}
    catch
      kind, reason ->
        {:error, "failed to parse dictionary XML: #{inspect({kind, reason})}"}
    end
  end

  defp valsi_elements(document) do
    :xmerl_xpath.string(~c"/dictionary/direction/valsi", document)
  end

  defp parse_entry(valsi) do
    word = attribute(valsi, :word)
    type = attribute(valsi, :type)

    if blank?(word) or blank?(type) do
      nil
    else
      definition = direct_child_text(valsi, :definition) || ""
      notes = direct_child_text(valsi, :notes)
      glosses = parse_glosses(valsi)
      keywords = parse_keywords(valsi)
      rafsi = parse_rafsi(valsi)

      unofficial = attribute(valsi, :unofficial) == "true"
      obsolete = String.contains?(type, "obsolete")
      experimental = String.contains?(type, "experimental")

      definition_search = normalize_query(definition)
      notes_search = normalize_query(notes)
      gloss_search = glosses |> Enum.map_join(" ", &normalize_query(&1.word))
      keyword_search = keywords |> Enum.map_join(" ", &normalize_query(&1.word))

      %Entry{
        word: word,
        normalized_word: normalize_query(word),
        type: type,
        selmaho: direct_child_text(valsi, :selmaho),
        selmaho_key: normalize_selmaho(direct_child_text(valsi, :selmaho)),
        definition: definition,
        definition_id: direct_child_text(valsi, :definitionid),
        definition_search: definition_search,
        definition_preview: compact_preview(definition),
        notes: notes,
        notes_search: notes_search,
        glosses: glosses,
        keywords: keywords,
        rafsi: rafsi,
        rafsi_terms: Enum.map(rafsi, &normalize_query/1),
        author_username: user_value(valsi, :username),
        author_name: user_value(valsi, :realname),
        unofficial: unofficial,
        obsolete: obsolete,
        experimental: experimental,
        gloss_preview: gloss_preview(glosses),
        gloss_search: gloss_search,
        keyword_search: keyword_search,
        search_blob:
          [
            normalize_query(word),
            normalize_query(type),
            normalize_selmaho(direct_child_text(valsi, :selmaho)),
            Enum.map_join(rafsi, " ", &normalize_query/1),
            gloss_search,
            keyword_search,
            definition_search,
            notes_search
          ]
          |> Enum.reject(&blank?/1)
          |> Enum.join(" ")
      }
    end
  end

  defp parse_glosses(valsi) do
    valsi
    |> child_elements(:glossword)
    |> Enum.map(fn gloss ->
      %{
        word: attribute(gloss, :word),
        sense: attribute(gloss, :sense)
      }
    end)
    |> Enum.reject(&blank?(&1.word))
  end

  defp parse_keywords(valsi) do
    valsi
    |> child_elements(:keyword)
    |> Enum.map(fn keyword ->
      %{
        word: attribute(keyword, :word),
        sense: attribute(keyword, :sense),
        place: parse_integer(attribute(keyword, :place))
      }
    end)
    |> Enum.reject(&blank?(&1.word))
    |> Enum.sort_by(fn keyword -> {keyword.place || 99, keyword.word} end)
  end

  defp parse_rafsi(valsi) do
    valsi
    |> child_elements(:rafsi)
    |> Enum.map(&text_content/1)
    |> Enum.map(&compact_text/1)
    |> Enum.reject(&blank?/1)
  end

  defp user_value(valsi, field) do
    valsi
    |> child_elements(:user)
    |> List.first()
    |> case do
      nil -> nil
      user -> direct_child_text(user, field)
    end
  end

  defp build_dictionary(entries, source) do
    by_word =
      Enum.reduce(entries, %{}, fn entry, acc ->
        Map.update(acc, entry.normalized_word, entry, &prefer_entry(&1, entry))
      end)

    by_selmaho =
      Enum.reduce(entries, %{}, fn entry, acc ->
        if blank?(entry.selmaho_key) do
          acc
        else
          Map.update(acc, entry.selmaho_key, [entry], &[entry | &1])
        end
      end)
      |> Map.new(fn {selmaho, hits} ->
        {selmaho, hits |> Enum.uniq_by(& &1.word) |> Enum.sort_by(& &1.word)}
      end)

    by_rafsi =
      Enum.reduce(entries, %{}, fn entry, acc ->
        Enum.reduce(entry.rafsi_terms, acc, fn rafsi, rafsi_acc ->
          Map.update(rafsi_acc, rafsi, [entry], &[entry | &1])
        end)
      end)
      |> Map.new(fn {rafsi, hits} ->
        {rafsi, hits |> Enum.uniq_by(& &1.word) |> Enum.sort_by(& &1.word)}
      end)

    summary = build_summary(entries, by_selmaho, by_rafsi, source)

    %{
      entries: Enum.sort_by(entries, & &1.word),
      by_word: by_word,
      by_selmaho: by_selmaho,
      by_rafsi: by_rafsi,
      summary: summary
    }
  end

  defp build_summary(entries, by_selmaho, by_rafsi, source) do
    %{
      entry_count: length(entries),
      selmaho_count: map_size(by_selmaho),
      rafsi_count: map_size(by_rafsi),
      unofficial_count: Enum.count(entries, & &1.unofficial),
      experimental_count: Enum.count(entries, & &1.experimental),
      obsolete_count: Enum.count(entries, & &1.obsolete),
      top_types:
        entries
        |> Enum.frequencies_by(& &1.type)
        |> Enum.sort_by(fn {type, count} -> {-count, type} end)
        |> Enum.take(6),
      source_url: source.source_url,
      source_label: source.source_label,
      source_last_modified: source.source_last_modified,
      source_path: source.source_path
    }
  end

  defp do_lookup(data, raw_query, selected_word) do
    query = normalize_query(raw_query)
    selected_key = normalize_query(selected_word)

    exact = Map.get(data.by_word, query)
    selmaho_matches = Map.get(data.by_selmaho, normalize_selmaho(raw_query), [])
    rafsi_matches = Map.get(data.by_rafsi, query, [])

    hits =
      if query == "" do
        []
      else
        data.entries
        |> Enum.reduce([], fn entry, acc ->
          case score_entry(entry, query, normalize_selmaho(raw_query)) do
            nil -> acc
            hit -> [hit | acc]
          end
        end)
        |> Enum.sort_by(fn hit -> {-hit.score, hit.word} end)
      end

    selected =
      cond do
        selected_key != "" and Map.has_key?(data.by_word, selected_key) ->
          Map.fetch!(data.by_word, selected_key)

        exact ->
          exact

        hits != [] ->
          hits |> List.first() |> Map.fetch!(:entry)

        true ->
          nil
      end

    selected_word = selected && selected.word

    results =
      hits
      |> Enum.reject(&(&1.word == selected_word))
      |> Enum.take(@result_limit)

    %{
      query: raw_query || "",
      normalized_query: query,
      exact: exact,
      selected: selected,
      selected_word: selected_word,
      results: results,
      selmaho_matches:
        selmaho_matches
        |> Enum.reject(&(&1.word == selected_word))
        |> Enum.take(@related_limit),
      rafsi_matches:
        rafsi_matches
        |> Enum.reject(&(&1.word == selected_word))
        |> Enum.take(@related_limit),
      summary: data.summary
    }
  end

  defp score_entry(entry, query, selmaho_query) do
    reasons =
      []
      |> maybe_add(entry.normalized_word == query, "exact valsi")
      |> maybe_add(entry.selmaho_key != "" and entry.selmaho_key == selmaho_query, "selma'o")
      |> maybe_add(query in entry.rafsi_terms, "rafsi")
      |> maybe_add(
        String.starts_with?(entry.normalized_word, query) and entry.normalized_word != query,
        "word prefix"
      )
      |> maybe_add(contains_prefix?(entry.rafsi_terms, query), "rafsi prefix")
      |> maybe_add(any_gloss_exact?(entry, query), "gloss")
      |> maybe_add(any_keyword_exact?(entry, query), "keyword")
      |> maybe_add(any_gloss_prefix?(entry, query), "gloss prefix")
      |> maybe_add(any_keyword_prefix?(entry, query), "keyword prefix")
      |> maybe_add(
        String.contains?(entry.normalized_word, query) and entry.normalized_word != query,
        "word match"
      )
      |> maybe_add(
        entry.gloss_search != "" and String.contains?(entry.gloss_search, query),
        "gloss match"
      )
      |> maybe_add(
        entry.keyword_search != "" and String.contains?(entry.keyword_search, query),
        "keyword match"
      )
      |> maybe_add(
        entry.definition_search != "" and String.contains?(entry.definition_search, query),
        "definition"
      )
      |> maybe_add(
        entry.notes_search != "" and String.contains?(entry.notes_search, query),
        "notes"
      )

    score =
      0
      |> add_score(entry.normalized_word == query, 15_000)
      |> add_score(entry.selmaho_key != "" and entry.selmaho_key == selmaho_query, 13_000)
      |> add_score(query in entry.rafsi_terms, 12_000)
      |> add_score(
        String.starts_with?(entry.normalized_word, query) and entry.normalized_word != query,
        10_000
      )
      |> add_score(contains_prefix?(entry.rafsi_terms, query), 9_200)
      |> add_score(any_gloss_exact?(entry, query), 8_800)
      |> add_score(any_keyword_exact?(entry, query), 8_200)
      |> add_score(any_gloss_prefix?(entry, query), 7_600)
      |> add_score(any_keyword_prefix?(entry, query), 7_100)
      |> add_score(
        String.contains?(entry.normalized_word, query) and entry.normalized_word != query,
        6_500
      )
      |> add_score(
        entry.gloss_search != "" and String.contains?(entry.gloss_search, query),
        5_700
      )
      |> add_score(
        entry.keyword_search != "" and String.contains?(entry.keyword_search, query),
        5_200
      )
      |> add_score(
        entry.definition_search != "" and String.contains?(entry.definition_search, query),
        3_800
      )
      |> add_score(
        entry.notes_search != "" and String.contains?(entry.notes_search, query),
        3_000
      )
      |> add_score(entry.unofficial, -180)
      |> add_score(entry.obsolete, -220)

    if score <= 0 do
      nil
    else
      %{
        entry: entry,
        id: entry.word,
        word: entry.word,
        type: entry.type,
        selmaho: entry.selmaho,
        gloss: entry.gloss_preview,
        preview: preview_for_query(entry, query),
        score: score,
        reasons: reasons |> Enum.reverse() |> Enum.uniq() |> Enum.take(3),
        unofficial: entry.unofficial,
        obsolete: entry.obsolete,
        experimental: entry.experimental
      }
    end
  end

  defp any_gloss_exact?(entry, query) do
    Enum.any?(entry.glosses, fn gloss -> normalize_query(gloss.word) == query end)
  end

  defp any_keyword_exact?(entry, query) do
    Enum.any?(entry.keywords, fn keyword -> normalize_query(keyword.word) == query end)
  end

  defp any_gloss_prefix?(entry, query) do
    Enum.any?(entry.glosses, fn gloss ->
      String.starts_with?(normalize_query(gloss.word), query)
    end)
  end

  defp any_keyword_prefix?(entry, query) do
    Enum.any?(entry.keywords, fn keyword ->
      String.starts_with?(normalize_query(keyword.word), query)
    end)
  end

  defp contains_prefix?(terms, query) do
    Enum.any?(terms, &String.starts_with?(&1, query))
  end

  defp preview_for_query(entry, query) do
    cond do
      hit =
          Enum.find(entry.glosses, fn gloss ->
            String.contains?(normalize_query(gloss.word), query)
          end) ->
        hit.word

      hit =
          Enum.find(entry.keywords, fn keyword ->
            String.contains?(normalize_query(keyword.word), query)
          end) ->
        hit.word

      entry.definition_search != "" and String.contains?(entry.definition_search, query) ->
        excerpt(entry.definition, query)

      entry.notes_search != "" and String.contains?(entry.notes_search, query) ->
        excerpt(entry.notes, query)

      true ->
        entry.definition_preview
    end
  end

  defp excerpt(nil, _query), do: nil

  defp excerpt(text, query) do
    normalized = normalize_query(text)

    case :binary.match(normalized, query) do
      :nomatch ->
        compact_preview(text)

      {index, _length} ->
        start_at = max(index - 42, 0)
        slice = String.slice(text, start_at, 132)
        maybe_ellipsis(slice, start_at > 0, String.length(text) > start_at + 132)
    end
  end

  defp maybe_ellipsis(text, left?, right?) do
    [left? && "...", compact_text(text), right? && "..."]
    |> Enum.reject(&(&1 in [false, nil, ""]))
    |> Enum.join("")
  end

  defp gloss_preview([]), do: nil

  defp gloss_preview([gloss | _rest]) do
    cond do
      blank?(gloss.sense) -> gloss.word
      true -> "#{gloss.word} (#{gloss.sense})"
    end
  end

  defp compact_preview(text) do
    text
    |> compact_text()
    |> String.slice(0, 140)
  end

  defp prefer_entry(existing, incoming) do
    cond do
      existing.unofficial and not incoming.unofficial -> incoming
      existing.obsolete and not incoming.obsolete -> incoming
      true -> existing
    end
  end

  defp child_elements(element, name) do
    element
    |> xmlElement(:content)
    |> Enum.filter(fn
      node when is_tuple(node) and elem(node, 0) == :xmlElement -> xmlElement(node, :name) == name
      _node -> false
    end)
  end

  defp direct_child_text(element, name) do
    element
    |> child_elements(name)
    |> List.first()
    |> case do
      nil -> nil
      child -> text_content(child) |> compact_text()
    end
  end

  defp attribute(element, name) do
    element
    |> xmlElement(:attributes)
    |> Enum.find_value(fn attribute ->
      if xmlAttribute(attribute, :name) == name do
        attribute
        |> xmlAttribute(:value)
        |> to_string()
      end
    end)
  end

  defp text_content(node) when is_list(node) do
    Enum.map_join(node, "", &text_content/1)
  end

  defp text_content(node) when is_tuple(node) and elem(node, 0) == :xmlText do
    node
    |> xmlText(:value)
    |> to_string()
  end

  defp text_content(node) when is_tuple(node) and elem(node, 0) == :xmlElement do
    node
    |> xmlElement(:content)
    |> text_content()
  end

  defp text_content(_node), do: ""

  defp normalize_query(nil), do: ""

  defp normalize_query(text) do
    text
    |> to_string()
    |> String.replace(~r/[’‘`]/u, "'")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_selmaho(nil), do: ""

  defp normalize_selmaho(text) do
    text
    |> normalize_query()
    |> String.upcase()
  end

  defp compact_text(nil), do: nil

  defp compact_text(text) do
    text
    |> to_string()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_value), do: false

  defp add_score(score, true, value), do: score + value
  defp add_score(score, false, _value), do: score

  defp maybe_add(reasons, true, reason), do: [reason | reasons]
  defp maybe_add(reasons, false, _reason), do: reasons

  defp parse_integer(nil), do: nil

  defp parse_integer(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp preload_dictionary? do
    Application.get_env(:froth, :jbo_dictionary_preload, true)
  end

  defp format_source_timestamp(%NaiveDateTime{} = naive_datetime) do
    naive_datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_source_timestamp({{_year, _month, _day}, {_hour, _minute, _second}} = timestamp) do
    timestamp
    |> NaiveDateTime.from_erl!()
    |> format_source_timestamp()
  end

  defp format_source_timestamp(_timestamp) do
    nil
  end

  defp to_error(reason) when is_binary(reason), do: reason
  defp to_error(reason), do: inspect(reason)
end
