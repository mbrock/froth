defmodule Froth.Telegram.SessionConfig do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "telegram_sessions" do
    field(:api_id, :integer)
    field(:api_hash, :string)
    field(:bot_token, :string)
    field(:phone_number, :string)
    field(:database_dir, :string)
    field(:files_dir, :string)
    field(:enabled, :boolean, default: true)

    timestamps()
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :id,
      :api_id,
      :api_hash,
      :bot_token,
      :phone_number,
      :database_dir,
      :files_dir,
      :enabled
    ])
    |> validate_required([:id, :api_id, :api_hash])
    |> validate_auth_method()
  end

  defp validate_auth_method(changeset) do
    bot = get_field(changeset, :bot_token)
    phone = get_field(changeset, :phone_number)

    if is_nil(bot) and is_nil(phone) do
      add_error(changeset, :bot_token, "either bot_token or phone_number is required")
    else
      changeset
    end
  end

  @doc "XDG state path for TDLib session data."
  def tdlib_path(session_id, subdir) do
    state_home = System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state")
    Path.join([state_home, "froth", "tdlib", session_id, subdir])
  end

  def to_session_config(%__MODULE__{} = sc) do
    %{
      id: sc.id,
      api_id: sc.api_id,
      api_hash: sc.api_hash,
      bot_token: sc.bot_token,
      phone_number: sc.phone_number,
      database_dir: sc.database_dir || tdlib_path(sc.id, "database"),
      files_dir: sc.files_dir || tdlib_path(sc.id, "files")
    }
  end
end
