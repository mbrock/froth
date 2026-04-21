defmodule FrothWeb.AnalysesApiControllerTest do
  use FrothWeb.ConnCase, async: true

  alias Froth.Analysis
  alias Froth.Repo

  test "GET /froth/analyses returns a JSON help object", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/froth/analyses")

    assert %{
             "endpoint" => "/froth/analyses/:chat_id",
             "method" => "GET",
             "query_params" => %{
               "after" => after_help,
               "limit" => limit_help
             },
             "example" => example
           } = json_response(conn, 200)

    assert after_help =~ "message_id > after"
    assert limit_help =~ "1000"
    assert example =~ "/froth/analyses/"
  end

  test "GET /froth/analyses/:chat_id returns ordered analyses with cursor pagination",
       %{
         conn: conn
       } do
    chat_id = -1_003_690_254_489

    _older =
      insert_analysis(%{
        chat_id: chat_id,
        message_id: 10,
        type: "image",
        agent: "vision",
        analysis_text: "first analysis",
        metadata: %{"filename" => "a.png"},
        generated_at: ~U[2026-04-10 09:00:00Z]
      })

    wanted =
      insert_analysis(%{
        chat_id: chat_id,
        message_id: 20,
        type: "document",
        agent: "charlie",
        analysis_text: "second analysis",
        metadata: %{"filename" => "b.pdf"},
        generated_at: ~U[2026-04-10 10:00:00Z]
      })

    _newer =
      insert_analysis(%{
        chat_id: chat_id,
        message_id: 30,
        type: "voice",
        agent: "charlie",
        analysis_text: "third analysis",
        metadata: %{"duration" => 12},
        generated_at: ~U[2026-04-10 11:00:00Z]
      })

    _other_chat =
      insert_analysis(%{
        chat_id: 123_456,
        message_id: 25,
        type: "image",
        agent: "vision",
        analysis_text: "other chat analysis",
        metadata: %{},
        generated_at: ~U[2026-04-10 12:00:00Z]
      })

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/froth/analyses/#{chat_id}?after=10&limit=1")

    assert [
             %{
               "id" => id,
               "type" => "document",
               "chat_id" => ^chat_id,
               "message_id" => 20,
               "agent" => "charlie",
               "analysis_text" => "second analysis",
               "metadata" => %{"filename" => "b.pdf"},
               "generated_at" => "2026-04-10T10:00:00Z",
               "inserted_at" => inserted_at
             }
           ] = json_response(conn, 200)

    assert id == wanted.id
    assert is_binary(inserted_at)
  end

  test "GET /froth/analyses/:chat_id caps the limit and validates query params",
       %{conn: conn} do
    chat_id = -777

    insert_analysis(%{
      chat_id: chat_id,
      message_id: 1,
      type: "text",
      agent: "charlie",
      analysis_text: "one",
      metadata: %{},
      generated_at: ~U[2026-04-10 08:00:00Z]
    })

    insert_analysis(%{
      chat_id: chat_id,
      message_id: 2,
      type: "text",
      agent: "charlie",
      analysis_text: "two",
      metadata: %{},
      generated_at: ~U[2026-04-10 08:05:00Z]
    })

    capped_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/froth/analyses/#{chat_id}?limit=5000")

    assert [%{"message_id" => 1}, %{"message_id" => 2}] =
             json_response(capped_conn, 200)

    invalid_conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get(~p"/froth/analyses/#{chat_id}?after=nope")

    assert %{"error" => "must be an integer", "param" => "after"} =
             json_response(invalid_conn, 400)
  end

  defp insert_analysis(attrs) do
    Repo.insert!(struct(Analysis, attrs))
  end
end
