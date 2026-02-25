defmodule Froth.Inference.SessionLookup do
  @moduledoc """
  Lookup helpers for mapping tool refs to inference session ids.
  """

  alias Froth.Repo
  alias Froth.Inference.InferenceSession
  import Ecto.Query

  def pending_session_id_for_ref(bot_id, ref)
      when is_binary(bot_id) and is_binary(ref) do
    session_id_for_ref(bot_id, ref, "pending")
  end

  def executing_session_id_for_ref(bot_id, ref)
      when is_binary(bot_id) and is_binary(ref) do
    session_id_for_ref(bot_id, ref, "executing")
  end

  defp session_id_for_ref(bot_id, ref, status)
       when is_binary(bot_id) and is_binary(ref) and is_binary(status) do
    Repo.one(
      from(c in InferenceSession,
        where:
          c.bot_id == ^bot_id and c.status == "awaiting_tools" and
            fragment(
              "EXISTS (SELECT 1 FROM jsonb_array_elements(?) elem WHERE elem->>'ref' = ? AND elem->>'status' = ?)",
              c.pending_tools,
              ^ref,
              ^status
            ),
        order_by: [desc: c.id],
        select: c.id,
        limit: 1
      ),
      log: false
    )
  end
end
