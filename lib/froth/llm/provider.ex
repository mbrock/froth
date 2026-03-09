defmodule Froth.LLM.Provider do
  @moduledoc false

  alias Froth.LLM.{Edit, Request, Store}

  @type transport_request :: %{
          required(:url) => String.t(),
          required(:headers) => [{String.t(), String.t()}],
          required(:body) => map()
        }

  @callback build_request(Request.t()) :: {:ok, transport_request()} | {:error, term()}
  @callback decode_payload(map(), Store.t()) :: {[Edit.t()], boolean()}
  @callback finalize(Store.t()) :: map()
  @callback project_event(Edit.t()) :: term() | nil
end
