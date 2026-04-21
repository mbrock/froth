defmodule FrothWeb.ObjectStoreControllerTest do
  use FrothWeb.ConnCase, async: false

  alias Froth.ObjectStore

  setup do
    root_dir =
      Path.join(
        System.tmp_dir!(),
        "froth-object-store-#{System.unique_integer([:positive])}"
      )

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

    assert %{"key" => "video/test/hello.txt", "url" => url} =
             json_response(put_conn, 200)

    assert url == "http://example.test/froth/objects/video/test/hello.txt"

    get_conn = get(build_conn(), "/froth/objects/video/test/hello.txt")
    assert response(get_conn, 200) == "hello world"
  end

  test "POST uploads a content-addressed object and serves it back with stored content type",
       %{
         conn: conn
       } do
    body = "hello, content-addressed world"
    sha256 = sha256_hex(body)

    post_conn =
      conn
      |> put_req_header("x-froth-object-store-token", "secret")
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("accept", "application/json")
      |> post("/froth/objects", body)

    assert %{
             "key" => "sha256/" <> ^sha256,
             "url" => "http://example.test/froth/objects/sha256/" <> ^sha256,
             "sha256" => ^sha256,
             "content_type" => "text/plain",
             "content_length" => content_length
           } = json_response(post_conn, 201)

    assert content_length == byte_size(body)

    assert get_resp_header(post_conn, "location") == [
             "http://example.test/froth/objects/sha256/#{sha256}"
           ]

    get_conn = get(build_conn(), "/froth/objects/sha256/#{sha256}")
    assert response(get_conn, 200) == body
    assert get_resp_header(get_conn, "content-type") == ["text/plain"]
    assert get_resp_header(get_conn, "etag") == [~s|"sha256-#{sha256}"|]
  end

  test "POST prefers forwarded host headers for public URLs", %{conn: conn} do
    body = "forwarded-hosts test body"
    sha256 = sha256_hex(body)

    post_conn =
      conn
      |> put_req_header("x-froth-object-store-token", "secret")
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-forwarded-host", "less.rest")
      |> put_req_header("x-forwarded-proto", "https")
      |> post("/froth/objects", body)

    assert %{
             "url" => "https://less.rest/froth/objects/sha256/" <> ^sha256
           } = json_response(post_conn, 201)

    assert get_resp_header(post_conn, "location") == [
             "https://less.rest/froth/objects/sha256/#{sha256}"
           ]
  end

  test "PUT rejects unauthorized writes", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "text/plain")
      |> put("/froth/objects/video/test/nope.txt", "nope")

    assert response(conn, 401) == "unauthorized"
  end

  defp sha256_hex(body) do
    :crypto.hash(:sha256, body)
    |> Base.encode16(case: :lower)
  end
end
