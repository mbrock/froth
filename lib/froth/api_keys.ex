defmodule Froth.ApiKeys do
  import Ecto.Query, only: [from: 2]

  alias Froth.ApiKey
  alias Froth.Repo

  @provider_aliases %{
    anthropic: ["anthropic"],
    openai: ["openai"],
    grok: ["grok", "xai"],
    gemini: ["gemini", "google"],
    fakeai: ["fakeai"],
    replicate: ["replicate"]
  }

  @spec active_key(String.t() | atom() | [String.t() | atom()]) ::
          String.t() | nil
  def active_key(provider)
      when is_binary(provider) or is_atom(provider) or is_list(provider) do
    providers =
      provider
      |> List.wrap()
      |> Enum.map(&to_string/1)

    if providers == [] do
      nil
    else
      from(api_key in ApiKey,
        where: api_key.provider in ^providers,
        order_by: [desc: api_key.inserted_at],
        limit: 1,
        select: api_key.key
      )
      |> Repo.one()
    end
  end

  @spec active_key_for_provider(atom()) :: String.t() | nil
  def active_key_for_provider(:fakeai), do: "fake"

  def active_key_for_provider(provider_name) when is_atom(provider_name) do
    case Map.get(@provider_aliases, provider_name) do
      nil -> nil
      providers -> active_key(providers)
    end
  end
end
