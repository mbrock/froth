defmodule Froth.Blob do
  @moduledoc """
  Schema for a frozen piece of text (or binary) content referred to by
  its ULID. Used as the canonical "large thing" handle across the
  agent's context: shell output, eval output, extracted documents,
  analyses, summaries, transcripts.

  The bytes live in the row itself (`bytea`) — no external filesystem.
  Postgres handles this fine up to multi-megabyte payloads, and it
  keeps blobs transactional with the rest of the schema.

  Blob IDs are globally addressable — there is no per-chat or per-cycle
  namespace. Provenance (which cycle / tool call produced a blob) is
  implicit in the place the ID appears (tool_result, cycle event, etc.).
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          id: String.t() | nil,
          bytes: binary() | nil,
          mime: String.t() | nil,
          size: non_neg_integer() | nil,
          lines: non_neg_integer() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, Ecto.ULID, autogenerate: true}

  schema "blobs" do
    field(:bytes, :binary)
    field(:mime, :string, default: "text/plain")
    field(:size, :integer)
    field(:lines, :integer)
    field(:sha256, :binary)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
