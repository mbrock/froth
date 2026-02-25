defmodule Froth.WikiTest do
  use ExUnit.Case, async: false

  alias Froth.Repo
  alias Froth.Wiki
  alias Froth.Wiki.Entry

  setup do
    Repo.delete_all(Entry)
    :ok
  end

  test "create_empty_page/1 creates an empty entry from a page name" do
    assert {:ok, entry} = Wiki.create_empty_page("Pallus")
    assert entry.slug == "pallus"
    assert entry.title == "Pallus"
    assert entry.body == ""
  end

  test "append_paragraph/2 appends paragraphs to an existing page" do
    assert {:ok, _entry} = Wiki.create_empty_page("Pallus")

    assert {:ok, entry} = Wiki.append_paragraph("pallus", "The pallus is a speculative line.")
    assert entry.body == "The pallus is a speculative line."

    assert {:ok, entry} = Wiki.append_paragraph("PALLUS", "Some scholars dispute this account.")

    assert entry.body ==
             "The pallus is a speculative line.\n\nSome scholars dispute this account."
  end
end
