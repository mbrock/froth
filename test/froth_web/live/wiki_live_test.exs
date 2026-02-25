defmodule FrothWeb.WikiLiveTest do
  use FrothWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Froth.Repo
  alias Froth.Wiki
  alias Froth.Wiki.Entry

  setup do
    Repo.delete_all(Entry)

    assert {:ok, _entry} =
             Wiki.create(%{
               slug: "pallus",
               title: "Pallus",
               body: "The pallus appears in many lineages.\n\nPALLUS remains contested."
             })

    assert {:ok, _entry} =
             Wiki.create(%{
               slug: "lineages",
               title: "Lineages",
               body: ""
             })

    :ok
  end

  test "entry body links page names case-insensitively", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/froth/wiki/pallus")

    assert has_element?(
             view,
             ~s|.entry-body a.wiki-inline-link[href="/froth/wiki/pallus"]|,
             "pallus"
           )

    assert has_element?(
             view,
             ~s|.entry-body a.wiki-inline-link[href="/froth/wiki/pallus"]|,
             "PALLUS"
           )

    assert has_element?(
             view,
             ~s|.entry-body a.wiki-inline-link[href="/froth/wiki/lineages"]|,
             "lineages"
           )
  end
end
