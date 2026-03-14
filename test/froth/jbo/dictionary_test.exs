defmodule Froth.Jbo.DictionaryTest do
  use ExUnit.Case, async: false

  alias Froth.Jbo.Dictionary

  setup do
    fixture_path = Path.expand("../../fixtures/jbo/sample_dictionary.xml", __DIR__)
    previous_fetch_fun = Application.get_env(:froth, :jbo_dictionary_fetch_fun)

    Application.put_env(:froth, :jbo_dictionary_fetch_fun, fn ->
      {:ok,
       %{
         xml: File.read!(fixture_path),
         source_label: "fixture",
         source_url: "fixture"
       }}
    end)

    :ok = Dictionary.reset()

    on_exit(fn ->
      :ok = Dictionary.reset()

      if previous_fetch_fun do
        Application.put_env(:froth, :jbo_dictionary_fetch_fun, previous_fetch_fun)
      else
        Application.delete_env(:froth, :jbo_dictionary_fetch_fun)
      end
    end)

    :ok
  end

  test "normalizes apostrophes for exact valsi lookup" do
    assert {:ok, lookup} = Dictionary.lookup("a’a")

    assert lookup.exact.word == "a'a"
    assert lookup.selected.word == "a'a"
    assert lookup.selected.gloss_preview == "attentive"
  end

  test "finds selmaho members" do
    assert {:ok, lookup} = Dictionary.lookup("UI1")

    assert lookup.selected.word == "a'a"
    assert Enum.map(lookup.selmaho_matches, & &1.word) == ["a'au"]
    assert Enum.any?(lookup.results, &(&1.word == "a'au"))
  end

  test "finds rafsi and gloss matches" do
    assert {:ok, rafsi_lookup} = Dictionary.lookup("bau")
    assert rafsi_lookup.selected.word == "bangu"
    assert rafsi_lookup.exact == nil

    assert {:ok, gloss_lookup} = Dictionary.lookup("language")
    assert gloss_lookup.selected.word == "bangu"
  end
end
