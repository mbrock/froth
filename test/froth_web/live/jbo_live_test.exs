defmodule FrothWeb.JboLiveTest do
  use FrothWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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

  test "renders an exact lookup and note cross-links", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jbo?q=a'a")
    html = render_async(view)

    assert html =~ "attentive"
    assert has_element?(view, "#jbo-search-form")
    assert has_element?(view, "#jbo-selected-word", "a'a")
    assert has_element?(view, "#jbo-notes a[href=\"/jbo?entry=jundi&q=jundi\"]", "jundi")
  end

  test "updates to a selma'o query", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jbo")

    _html = render_change(element(view, "#jbo-search-form"), %{"jbo" => %{"q" => "UI1"}})

    assert_patch(view, ~p"/jbo?q=UI1")
    _html = render_async(view)

    assert has_element?(view, "#jbo-selected-word", "a'a")
    assert has_element?(view, "#jbo-result-a-au", "a'au")
  end
end
