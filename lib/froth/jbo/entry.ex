defmodule Froth.Jbo.Entry do
  @moduledoc false

  @enforce_keys [:word, :normalized_word, :type, :definition]
  defstruct [
    :word,
    :normalized_word,
    :type,
    :selmaho,
    :selmaho_key,
    :definition,
    :definition_id,
    :definition_search,
    :definition_preview,
    :notes,
    :notes_search,
    :author_username,
    :author_name,
    :unofficial,
    :obsolete,
    :experimental,
    :gloss_preview,
    :gloss_search,
    :keyword_search,
    :search_blob,
    glosses: [],
    keywords: [],
    rafsi: [],
    rafsi_terms: []
  ]
end
