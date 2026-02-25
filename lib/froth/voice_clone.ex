defmodule Froth.VoiceClone do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  schema "voice_clones" do
    field(:voice_id, :string)
    field(:name, :string)
    field(:character, :string)
    field(:notes, :string)
    field(:source_url, :string)
    field(:clone_model, :string, default: "speech-02-turbo")
    field(:tts_model, :string, default: "minimax/speech-2.8-hd")
    field(:language, :string, default: "Swedish")
    field(:cloned_from_prediction_id, :integer)
    field(:created_by, :string)

    timestamps()
  end

  def changeset(clone, attrs) do
    clone
    |> cast(attrs, [
      :voice_id,
      :name,
      :character,
      :notes,
      :source_url,
      :clone_model,
      :tts_model,
      :language,
      :cloned_from_prediction_id,
      :created_by
    ])
    |> validate_required([:voice_id, :name])
    |> unique_constraint(:voice_id)
  end

  @doc "Get a voice clone by name (case-insensitive partial match)"
  def by_name(name) do
    pattern = "%#{name}%"

    from(v in __MODULE__,
      where: ilike(v.name, ^pattern) or ilike(v.character, ^pattern),
      where: is_nil(v.notes) or not ilike(v.notes, "%DEPRECATED%")
    )
    |> Froth.Repo.all()
  end

  @doc "Get a voice ID by name. Returns the voice_id string or nil."
  def voice_id(name) do
    case by_name(to_string(name)) do
      [%{voice_id: id} | _] -> id
      [] -> nil
    end
  end

  @doc """
  Resolve a map of speaker atoms to voice IDs from the database.

  Given a list of speaker atoms (e.g. [:alex, :sigge, :jocke]),
  returns a map like %{alex: "R8_21QSL3ML", sigge: "R8_CWVYAU3I", ...}.

  Raises if any speaker cannot be found.
  """
  def resolve(speakers) when is_list(speakers) do
    Map.new(speakers, fn speaker ->
      name = to_string(speaker)

      case voice_id(name) do
        nil -> raise "No voice clone found for #{inspect(speaker)}"
        id -> {speaker, id}
      end
    end)
  end

  @doc "List all usable voices (excludes deprecated ones)"
  def all do
    from(v in __MODULE__,
      where: is_nil(v.notes) or not ilike(v.notes, "%DEPRECATED%"),
      order_by: v.name
    )
    |> Froth.Repo.all()
  end

  @doc "Register a new voice clone"
  def register(voice_id, name, opts \\ []) do
    %__MODULE__{}
    |> changeset(Map.merge(%{voice_id: voice_id, name: name}, Map.new(opts)))
    |> Froth.Repo.insert()
  end
end
