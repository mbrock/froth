defmodule Froth.LLM do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Froth.ApiKey
  alias Froth.LLM.{Edit, Request, Store}
  alias Froth.LLM.Transport.SSE
  alias Froth.Telemetry.Span

  @type on_event :: (term() -> any())
  @type on_edit :: (Edit.t() -> any())
  @type provider_ref :: atom() | String.t() | module() | nil

  @spec stream_single(list(map()), on_event(), keyword()) :: {:ok, map()} | {:error, term()}
  def stream_single(api_messages, on_event, opts \\ [])
      when is_list(api_messages) and is_function(on_event, 1) and is_list(opts) do
    case Application.get_env(:froth, :llm_stream_single_fun) do
      fun when is_function(fun, 3) ->
        fun.(api_messages, on_event, opts)

      _ ->
        with {:ok, client} <-
               resolve_client_module(Keyword.get(opts, :provider), Keyword.get(opts, :model)) do
          client.stream_single(api_messages, on_event, opts)
        else
          {:error, _} = err -> err
        end
    end
  end

  @spec stream(Request.t(), on_event(), keyword()) :: {:ok, map()} | {:error, term()}
  def stream(%Request{} = request, on_event, opts \\ []) when is_function(on_event, 1) do
    case Application.get_env(:froth, :llm_stream_fun) do
      fun when is_function(fun, 3) ->
        fun.(request, on_event, opts)

      _ ->
        provider = request.provider
        telemetry_provider = Keyword.get(opts, :provider_name, provider)
        on_edit = Keyword.get(opts, :on_edit, fn _edit -> :ok end)
        parent_id = request.parent_id || Keyword.get(opts, :parent_id)

        with true <- provider_module?(provider),
             {:ok, transport_request} <- provider.build_request(request) do
          initial = Store.new()

          SSE.stream(
            transport_request.url,
            transport_request.headers,
            transport_request.body,
            initial,
            fn payload, _raw, store ->
              {edits, done?} = provider.decode_payload(payload, store)
              store = Store.apply_edits(store, edits)

              Enum.each(edits, fn edit ->
                emit_edit(telemetry_provider, edit, parent_id)
                on_edit.(edit)

                case provider.project_event(edit) do
                  nil -> :ok
                  event -> on_event.(event)
                end
              end)

              if done?, do: {:halt, store}, else: {:cont, store}
            end,
            Keyword.take(opts, [:receive_timeout, :finch])
          )
          |> case do
            {:ok, store} -> {:ok, provider.finalize(store)}
            {:error, _} = err -> err
          end
        else
          false -> {:error, {:invalid_provider, provider}}
          {:error, _} = err -> err
        end
    end
  end

  @spec active_api_key(String.t() | atom() | [String.t() | atom()]) :: String.t() | nil
  def active_api_key(provider)
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
      |> Froth.Repo.one()
    end
  rescue
    _ -> nil
  end

  @spec default_system_prompt() :: String.t()
  def default_system_prompt, do: Froth.Anthropic.default_system_prompt()

  @spec provider_name_for_model(String.t() | nil) :: atom() | nil
  def provider_name_for_model(model) when is_binary(model) do
    cond do
      String.starts_with?(model, "claude") -> :anthropic
      String.starts_with?(model, "grok") -> :grok
      String.starts_with?(model, "gemini") -> :gemini
      String.starts_with?(model, "gpt") -> :openai
      String.starts_with?(model, "chatgpt") -> :openai
      String.starts_with?(model, "o") -> :openai
      true -> nil
    end
  end

  def provider_name_for_model(_model), do: nil

  @spec resolve_client_module(provider_ref(), String.t() | nil) ::
          {:ok, module()} | {:error, term()}
  def resolve_client_module(provider, model \\ nil)

  def resolve_client_module(provider, _model) when is_atom(provider) and not is_nil(provider) do
    cond do
      Code.ensure_loaded?(provider) and function_exported?(provider, :stream_single, 3) ->
        {:ok, provider}

      provider in [:anthropic, :openai, :grok, :gemini] ->
        resolve_client_module(Atom.to_string(provider), nil)

      true ->
        {:error, {:unknown_provider, provider}}
    end
  end

  def resolve_client_module(provider, model) do
    resolved =
      case provider do
        nil -> provider_name_for_model(model)
        ref -> normalize_provider_ref(ref)
      end

    case resolved do
      :anthropic -> {:ok, Froth.Anthropic}
      :openai -> {:ok, Froth.OpenAI}
      :grok -> {:ok, Froth.Grok}
      :gemini -> {:ok, Froth.Gemini}
      nil -> {:error, {:unknown_provider, provider || model}}
      other -> {:error, {:unknown_provider, other}}
    end
  end

  defp emit_edit(provider, %Edit{} = edit, parent_id) do
    Span.execute([:froth, :llm, :edit], parent_id, %{
      provider: provider_name(provider),
      op: edit.op,
      resource: edit.resource,
      path: edit.path,
      resource_id: Edit.resource_id(edit),
      full_path: Edit.full_path(edit),
      value: edit.value,
      attrs: edit.attrs,
      raw: edit.raw
    })
  end

  defp provider_name(provider) when provider in [:anthropic, :openai, :grok, :gemini] do
    provider
  end

  defp provider_name(provider) when is_atom(provider) do
    provider
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp provider_module?(provider) when is_atom(provider) do
    Code.ensure_loaded?(provider) and function_exported?(provider, :build_request, 1) and
      function_exported?(provider, :decode_payload, 2) and
      function_exported?(provider, :finalize, 1) and
      function_exported?(provider, :project_event, 1)
  end

  defp provider_module?(_provider), do: false

  defp normalize_provider_ref(ref) when is_atom(ref), do: ref

  defp normalize_provider_ref(ref) when is_binary(ref) do
    ref
    |> String.trim()
    |> String.downcase()
    |> case do
      "anthropic" -> :anthropic
      "claude" -> :anthropic
      "openai" -> :openai
      "gpt" -> :openai
      "grok" -> :grok
      "xai" -> :grok
      "gemini" -> :gemini
      "google" -> :gemini
      _ -> nil
    end
  end
end
