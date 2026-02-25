defmodule Froth.Wiki do
  import Ecto.Query
  alias Froth.Repo

  defmodule Entry do
    use Ecto.Schema
    import Ecto.Changeset

    schema "wiki_entries" do
      field(:slug, :string)
      field(:title, :string)
      field(:also_known_as, :string)
      field(:body, :string, default: "")
      field(:see_also, {:array, :string}, default: [])
      timestamps()
    end

    def changeset(entry, attrs) do
      entry
      |> cast(attrs, [:slug, :title, :also_known_as, :body, :see_also])
      |> validate_required([:slug, :title])
      |> unique_constraint(:slug)
    end
  end

  def entries do
    Entry |> order_by(:title) |> Repo.all()
  end

  def get(slug) do
    Repo.get_by(Entry, slug: slug)
  end

  def create(attrs) do
    %Entry{} |> Entry.changeset(attrs) |> Repo.insert()
  end

  def create_empty_page(name) when is_binary(name) do
    with {:ok, title} <- normalize_non_empty(name, :invalid_name),
         {:ok, slug} <- slug_for_title(title) do
      create(%{slug: slug, title: title, body: ""})
    end
  end

  def create_empty_page(_), do: {:error, :invalid_name}

  def update(slug, attrs) do
    case get(slug) do
      nil -> {:error, :not_found}
      entry -> entry |> Entry.changeset(attrs) |> Repo.update()
    end
  end

  def append_paragraph(page_name, paragraph)
      when is_binary(page_name) and is_binary(paragraph) do
    with {:ok, normalized_page_name} <- normalize_non_empty(page_name, :invalid_page_name),
         {:ok, normalized_paragraph} <- normalize_non_empty(paragraph, :empty_paragraph),
         %Entry{} = entry <- get_by_slug_or_title(normalized_page_name) do
      body =
        case String.trim(entry.body || "") do
          "" -> normalized_paragraph
          _ -> "#{entry.body}\n\n#{normalized_paragraph}"
        end

      entry
      |> Entry.changeset(%{body: body})
      |> Repo.update()
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def append_paragraph(_, _), do: {:error, :invalid_arguments}

  def upsert(attrs) do
    case get(attrs[:slug] || attrs["slug"]) do
      nil -> create(attrs)
      entry -> entry |> Entry.changeset(attrs) |> Repo.update()
    end
  end

  defp get_by_slug_or_title(page_name) do
    normalized_page_name = String.downcase(page_name)

    case Entry
         |> where([entry], fragment("lower(?) = ?", entry.slug, ^normalized_page_name))
         |> limit(1)
         |> Repo.one() do
      %Entry{} = entry ->
        entry

      nil ->
        Entry
        |> where([entry], fragment("lower(?) = ?", entry.title, ^normalized_page_name))
        |> limit(1)
        |> Repo.one()
    end
  end

  defp normalize_non_empty(value, reason) do
    case String.trim(value) do
      "" -> {:error, reason}
      normalized_value -> {:ok, normalized_value}
    end
  end

  defp slug_for_title(title) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
      |> String.trim("-")

    if slug == "" do
      {:error, :invalid_name}
    else
      {:ok, slug}
    end
  end
end
