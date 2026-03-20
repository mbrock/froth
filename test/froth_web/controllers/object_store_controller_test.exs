defmodule FrothWeb.ObjectStoreControllerTest do
  use FrothWeb.ConnCase, async: false

  alias Froth.ObjectStore

  setup do
    root_dir =
      Path.join(System.tmp_dir!(), "froth-object-store-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:froth, ObjectStore, [])

    Application.put_env(:froth, ObjectStore,
      mode: :local,
      root_dir: root_dir,
      public_base: "http://example.test/froth/objects",
      write_token: "secret"
    )

    on_exit(fn ->
      Application.put_env(:froth, ObjectStore, previous)
      File.rm_rf(root_dir)
    end)

    {:ok, root_dir: root_dir}
  end

  test "PUT uploads an object and GET serves it back", %{conn: conn} do
    put_conn =
      conn
      |> put_req_header("x-froth-object-store-token", "secret")
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("accept", "application/json")
      |> put("/froth/objects/video/test/hello.txt", "hello world")

    assert %{"key" => "video/test/hello.txt", "url" => url} = json_response(put_conn, 200)
    assert url == "http://example.test/froth/objects/video/test/hello.txt"

    get_conn = get(build_conn(), "/froth/objects/video/test/hello.txt")
    assert response(get_conn, 200) == "hello world"
  end

  test "PUT rejects unauthorized writes", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "text/plain")
      |> put("/froth/objects/video/test/nope.txt", "nope")

    assert response(conn, 401) == "unauthorized"
  end
end
