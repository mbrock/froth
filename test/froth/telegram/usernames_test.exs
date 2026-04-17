defmodule Froth.Telegram.UsernamesTest do
  use ExUnit.Case, async: true

  alias Froth.Repo
  alias Froth.Telegram.Names
  alias Froth.Telegram.Username
  alias Froth.Telegram.Usernames

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  test "upsert_from_user persists username metadata and label" do
    {:ok, _username} =
      Usernames.upsert_from_user(
        %{
          "id" => 123_456,
          "first_name" => "Alice",
          "last_name" => "Example",
          "usernames" => %{"active_usernames" => ["alice_example"]}
        },
        "mbrockman"
      )

    row = Repo.get!(Username, 123_456)

    assert row.username == "alice_example"
    assert row.first_name == "Alice"
    assert row.last_name == "Example"
    assert row.label == "@alice_example"
    assert row.source_session_id == "mbrockman"
  end

  test "sender_label uses persisted username rows before TDLib lookup" do
    Repo.insert!(
      Username.changeset(%Username{}, %{
        user_id: 234_567,
        username: "cached_user",
        label: "@cached_user"
      })
    )

    assert Names.sender_label(234_567, "charlie") == "@cached_user"
  end

  test "labels_for_ids loads persisted user labels in bulk" do
    Repo.insert!(
      Username.changeset(%Username{}, %{
        user_id: 345_678,
        username: "alice",
        label: "@alice"
      })
    )

    Repo.insert!(
      Username.changeset(%Username{}, %{
        user_id: 456_789,
        username: "bob",
        label: "@bob"
      })
    )

    assert Names.labels_for_ids([345_678, 456_789], "charlie") == %{
             345_678 => "@alice",
             456_789 => "@bob"
           }
  end
end
