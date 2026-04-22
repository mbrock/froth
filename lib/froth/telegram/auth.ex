defmodule Froth.Telegram.Auth do
  @moduledoc """
  Interactive TDLib authentication helper for development.

  Run from an IEx shell with distribution enabled and the cnode bridge enabled:

      export TELEGRAM_TDLIB_ENABLED=1
      iex --sname froth -S mix run --no-halt

      iex> Froth.Telegram.Auth.run()
      iex> Froth.Telegram.Auth.run("my-bot")

  It uses `.env` variables if present:

  - `TDLIB_API_ID`
  - `TDLIB_API_HASH`
  - `TDLIB_DATABASE_DIR`
  - `TDLIB_FILES_DIR`
  - `TELEGRAM_BOT_TOKEN` (preferred if present; avoids SMS login)
  """

  @name :froth_telegram_auth

  @doc """
  Drive TDLib authentication until it reaches `authorizationStateReady`.

  The first argument is the session ID (default: "default").

  Options:
  - `:use_bot` (boolean) if true, prefer `TELEGRAM_BOT_TOKEN` when available (default: true)
  - `:print_updates` (boolean | :important | :all) (default: :important)
  """
  def run(session_id \\ "default", opts \\ []) do
    _ = stop()

    pid =
      spawn(fn ->
        try do
          run_loop(session_id, opts)
        rescue
          e ->
            IO.puts("[tdlib] auth helper crashed: #{Exception.message(e)}")
            IO.puts(Exception.format(:error, e, __STACKTRACE__))
        end
      end)

    Process.register(pid, @name)
    {:ok, pid}
  end

  @doc """
  Drive TDLib authentication in the current process until it reaches
  `authorizationStateReady`, then return `{:ok, :ready}`.

  Intended for terminal wrappers that authenticate via RPC without `iex`.
  """
  def run_blocking(session_id \\ "default", opts \\ []) do
    _ = stop()
    run_loop(session_id, Keyword.put(opts, :stop_on_ready, true))
  end

  @doc "Stop the currently running auth loop (if any)."
  def stop do
    case Process.whereis(@name) do
      nil ->
        :ok

      pid ->
        _ = Process.unregister(@name)
        Process.exit(pid, :kill)
        :ok
    end
  end

  @doc "Stop a running auth loop started via `run/1`."
  def stop(pid) when is_pid(pid) do
    if Process.whereis(@name) == pid do
      _ = Process.unregister(@name)
    end

    Process.exit(pid, :kill)
    :ok
  end

  defp td_send(state, request) do
    Froth.Telegram.send(state.session_id, request)
  end

  defp log(state, text), do: log(state, :info, text)

  defp log(state, level, text) do
    id = IO.ANSI.cyan() <> state.session_id <> IO.ANSI.reset()

    line =
      case level do
        :err -> "#{id} #{IO.ANSI.red()}#{text}#{IO.ANSI.reset()}"
        :ok -> "#{id} #{IO.ANSI.green()}#{text}#{IO.ANSI.reset()}"
        :dim -> "#{id} #{IO.ANSI.faint()}#{text}#{IO.ANSI.reset()}"
        _ -> "#{id} #{text}"
      end

    IO.puts(line)
  end

  defp run_loop(session_id, opts) do
    use_bot = Keyword.get(opts, :use_bot, true)

    print_updates =
      normalize_print_updates(Keyword.get(opts, :print_updates, :important))

    stop_on_ready? = Keyword.get(opts, :stop_on_ready, false)

    :ok = Froth.Telegram.subscribe(session_id)

    Froth.Telegram.send(session_id, %{
      "@type" => "getAuthorizationState"
    })

    db_config =
      case Froth.Repo.get(Froth.Telegram.SessionConfig, session_id) do
        nil -> %{}
        sc -> Froth.Telegram.SessionConfig.to_session_config(sc)
      end

    loop(%{
      session_id: session_id,
      db_config: db_config,
      use_bot: use_bot,
      print_updates: print_updates,
      stop_on_ready?: stop_on_ready?,
      api_id: Keyword.get(opts, :api_id) || db_config[:api_id],
      api_hash: Keyword.get(opts, :api_hash) || db_config[:api_hash],
      prompted_api?: false,
      sent_tdlib_parameters?: false,
      sent_encryption_key?: false,
      sent_bot_token?: false,
      sent_phone?: false,
      sent_code?: false,
      sent_password?: false,
      ready?: false,
      last_auth_type: nil
    })
  end

  defp loop(state) do
    receive do
      {:telegram_update, %{"@type" => "error"} = err} ->
        print_update(err, state)

        state =
          case err do
            %{"code" => 400, "message" => msg} when is_binary(msg) ->
              state
              |> maybe_prompt_api(msg)
              |> reset_retry_state()
              |> retry_last_auth_state()

            _ ->
              state
              |> reset_retry_state()
              |> retry_last_auth_state()
          end

        loop(state)

      {:telegram_update,
       %{"@type" => "authorizationStateWaitTdlibParameters"} = auth_state} ->
        state = handle_auth_state(auth_state, state)
        loop(state)

      {:telegram_update,
       %{"@type" => "authorizationStateWaitEncryptionKey"} = auth_state} ->
        state = handle_auth_state(auth_state, state)
        loop(state)

      {:telegram_update,
       %{"@type" => "authorizationStateWaitPhoneNumber"} = auth_state} ->
        state = handle_auth_state(auth_state, state)
        loop(state)

      {:telegram_update,
       %{"@type" => "authorizationStateWaitCode"} = auth_state} ->
        state = handle_auth_state(auth_state, state)
        loop(state)

      {:telegram_update,
       %{"@type" => "authorizationStateWaitPassword"} = auth_state} ->
        state = handle_auth_state(auth_state, state)
        loop(state)

      {:telegram_update, %{"@type" => "authorizationStateReady"} = auth_state} ->
        state = handle_auth_state(auth_state, state)
        maybe_finish(state)

      {:telegram_update, %{"@type" => "updateAuthorizationState"} = upd} ->
        auth_state = get_in(upd, ["authorization_state"]) || %{}
        state = handle_auth_state(auth_state, state)
        maybe_finish(state)

      {:telegram_update,
       %{
         "@type" => "updateOption",
         "name" => name,
         "value" => %{"value" => v}
       } = _upd} ->
        if should_print_update?(
             %{"@type" => "updateOption"},
             state.print_updates
           ) do
          log(state, :dim, "option #{name}=#{v}")
        end

        loop(state)

      {:telegram_update, %{"@type" => "updateOption"} = _upd} ->
        loop(state)

      {:telegram_update, %{"@type" => _type} = upd} ->
        print_update(upd, state)
        loop(state)

      other ->
        Span.execute(
          [:froth, :telegram, :auth, :ignored],
          nil,
          %{message: other}
        )

        loop(state)
    after
      60_000 ->
        log(state, :dim, "waiting...")
        loop(state)
    end
  end

  defp maybe_finish(%{ready?: true, stop_on_ready?: true}) do
    {:ok, :ready}
  end

  defp maybe_finish(state), do: loop(state)

  defp handle_auth_state(
         %{"@type" => "authorizationStateWaitTdlibParameters"},
         state
       ) do
    if state.sent_tdlib_parameters? do
      state
    else
      log(state, "setting tdlib parameters")

      td_send(
        state,
        Map.put(tdlib_parameters(state), "@type", "setTdlibParameters")
      )

      %{state | sent_tdlib_parameters?: true}
    end
  end

  defp handle_auth_state(
         %{"@type" => "authorizationStateWaitEncryptionKey"},
         state
       ) do
    if state.sent_encryption_key? do
      state
    else
      td_send(state, %{
        "@type" => "checkDatabaseEncryptionKey",
        "encryption_key" => ""
      })

      %{state | sent_encryption_key?: true}
    end
  end

  defp handle_auth_state(
         %{"@type" => "authorizationStateWaitPhoneNumber"},
         state
       ) do
    cond do
      state.use_bot and state.sent_bot_token? ->
        state

      state.use_bot ->
        token =
          state.db_config[:bot_token] || System.get_env("TELEGRAM_BOT_TOKEN")

        case token do
          t when is_binary(t) and t != "" ->
            log(state, "authenticating as bot")

            td_send(state, %{
              "@type" => "checkAuthenticationBotToken",
              "token" => t
            })

            %{state | sent_bot_token?: true}

          _ ->
            handle_user_phone_login(state)
        end

      true ->
        handle_user_phone_login(state)
    end
  end

  defp handle_auth_state(%{"@type" => "authorizationStateWaitCode"}, state) do
    if state.sent_code? do
      state
    else
      code = prompt("Enter the login code")
      td_send(state, %{"@type" => "checkAuthenticationCode", "code" => code})
      %{state | sent_code?: true}
    end
  end

  defp handle_auth_state(
         %{"@type" => "authorizationStateWaitPassword"},
         state
       ) do
    if state.sent_password? do
      state
    else
      password = prompt("Enter the 2FA password")

      td_send(state, %{
        "@type" => "checkAuthenticationPassword",
        "password" => password
      })

      %{state | sent_password?: true}
    end
  end

  defp handle_auth_state(%{"@type" => "authorizationStateReady"}, state) do
    if state.ready? do
      state
    else
      log(state, :ok, "ready")
      td_send(state, %{"@type" => "getMe"})
      %{state | ready?: true}
    end
  end

  defp handle_auth_state(
         %{"@type" => "authorization" <> _ = type} = auth_state,
         state
       ) do
    short =
      type |> String.replace("authorizationState", "") |> Macro.underscore()

    if state.last_auth_type != type do
      log(state, "auth: #{short}")
    end

    if Map.has_key?(auth_state, "error") do
      log(state, :err, auth_state["error"])
    end

    %{state | last_auth_type: type}
  end

  defp handle_auth_state(%{"@type" => type} = auth_state, state) do
    if state.last_auth_type != type do
      log(state, "auth: #{type}")
    end

    if Map.has_key?(auth_state, "error") do
      log(state, :err, auth_state["error"])
    end

    %{state | last_auth_type: type}
  end

  defp handle_auth_state(_other, state), do: state

  defp handle_user_phone_login(state) do
    if state.sent_phone? do
      state
    else
      phone =
        state.db_config[:phone_number] ||
          System.get_env("TDLIB_PHONE_NUMBER") ||
          System.get_env("TELEGRAM_PHONE_NUMBER") ||
          prompt(
            "Enter phone number (international format, e.g. +15551234567)"
          )

      td_send(state, %{
        "@type" => "setAuthenticationPhoneNumber",
        "phone_number" => phone
      })

      %{state | sent_phone?: true}
    end
  end

  defp print_update(upd, state) do
    if should_print_update?(upd, state.print_updates) do
      case upd do
        %{"@type" => "error", "code" => code, "message" => msg} ->
          log(state, :err, "#{code}: #{msg}")

        %{"@type" => "user"} = u ->
          name = user_name(u)
          username = if u["username"], do: " @#{u["username"]}", else: ""
          log(state, :ok, "#{name}#{username}")

        %{"@type" => "updateNewMessage", "message" => msg} when is_map(msg) ->
          print_message(state, msg)

        %{"@type" => "update" <> _ = type} ->
          short =
            type |> String.replace_prefix("update", "") |> Macro.underscore()

          log(state, :dim, short)

        %{"@type" => type} ->
          log(state, :dim, type)

        other ->
          log(state, :dim, inspect(other))
      end
    else
      :ok
    end
  end

  defp should_print_update?(_upd, false), do: false
  defp should_print_update?(_upd, :all), do: true
  defp should_print_update?(%{"@type" => "error"}, :important), do: true
  defp should_print_update?(%{"@type" => "user"}, :important), do: true

  defp should_print_update?(
         %{"@type" => "authorizationState" <> _},
         :important
       ),
       do: true

  defp should_print_update?(
         %{"@type" => "updateAuthorizationState"},
         :important
       ),
       do: true

  defp should_print_update?(_upd, :important), do: false

  defp print_message(state, msg) do
    chat_id = msg["chat_id"]
    text = msg |> get_in(["content"]) |> message_text()

    case text do
      nil ->
        log(state, :dim, "#{chat_id} [non-text]")

      t ->
        preview = t |> String.replace(~r/\s+/, " ") |> String.slice(0, 80)
        trail = if String.length(t) > 80, do: "...", else: ""
        log(state, "#{chat_id} #{preview}#{trail}")
    end
  end

  defp user_name(u) do
    [u["first_name"], u["last_name"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp message_text(%{"@type" => "messageText", "text" => %{"text" => text}})
       when is_binary(text),
       do: text

  defp message_text(_), do: nil

  defp tdlib_parameters(state) do
    api_id =
      case state.api_id do
        nil -> System.get_env("TDLIB_API_ID") |> to_int!("TDLIB_API_ID")
        i when is_integer(i) -> i
        s when is_binary(s) -> to_int!(s, "TDLIB_API_ID")
      end

    api_hash =
      case state.api_hash do
        nil ->
          System.get_env("TDLIB_API_HASH") |> to_required!("TDLIB_API_HASH")

        s when is_binary(s) ->
          to_required!(s, "TDLIB_API_HASH")
      end

    database_dir =
      state.db_config[:database_dir] ||
        System.get_env("TDLIB_DATABASE_DIR") ||
        Froth.Telegram.SessionConfig.tdlib_path(state.session_id, "database")

    files_dir =
      state.db_config[:files_dir] ||
        System.get_env("TDLIB_FILES_DIR") ||
        Froth.Telegram.SessionConfig.tdlib_path(state.session_id, "files")

    %{
      "use_test_dc" => false,
      "database_directory" => database_dir,
      "files_directory" => files_dir,
      "database_encryption_key" => "",
      "use_file_database" => true,
      "use_chat_info_database" => true,
      "use_message_database" => true,
      "use_secret_chats" => false,
      "api_id" => api_id,
      "api_hash" => api_hash,
      "system_language_code" =>
        System.get_env("LANG", "en") |> String.slice(0, 2),
      "device_model" => "froth",
      "system_version" => System.get_env("KERNEL", "linux"),
      "application_version" => "0.1.0"
    }
  end

  defp maybe_prompt_api(%{prompted_api?: true} = state, _msg), do: state

  defp maybe_prompt_api(state, msg) do
    if String.contains?(msg, "api_id") do
      log(
        state,
        :err,
        "bad api_id/api_hash -- get valid ones from my.telegram.org"
      )

      api_id = prompt("TDLIB_API_ID")
      api_hash = prompt("TDLIB_API_HASH")

      %{
        state
        | api_id: to_int!(api_id, "TDLIB_API_ID"),
          api_hash: to_required!(api_hash, "TDLIB_API_HASH"),
          prompted_api?: true
      }
    else
      state
    end
  end

  defp reset_retry_state(
         %{last_auth_type: "authorizationStateWaitTdlibParameters"} = state
       ) do
    %{state | sent_tdlib_parameters?: false}
  end

  defp reset_retry_state(
         %{last_auth_type: "authorizationStateWaitEncryptionKey"} = state
       ) do
    %{state | sent_encryption_key?: false}
  end

  defp reset_retry_state(
         %{last_auth_type: "authorizationStateWaitPhoneNumber"} = state
       ) do
    %{state | sent_phone?: false, sent_bot_token?: false}
  end

  defp reset_retry_state(
         %{last_auth_type: "authorizationStateWaitCode"} = state
       ) do
    %{state | sent_code?: false}
  end

  defp reset_retry_state(
         %{last_auth_type: "authorizationStateWaitPassword"} = state
       ) do
    %{state | sent_password?: false}
  end

  defp reset_retry_state(state), do: state

  defp retry_last_auth_state(%{last_auth_type: nil} = state), do: state

  defp retry_last_auth_state(%{last_auth_type: type} = state) do
    handle_auth_state(%{"@type" => type}, state)
  end

  defp normalize_print_updates(false), do: false
  defp normalize_print_updates(:important), do: :important
  defp normalize_print_updates(:all), do: :all
  defp normalize_print_updates("false"), do: false
  defp normalize_print_updates("important"), do: :important
  defp normalize_print_updates("all"), do: :all
  defp normalize_print_updates(nil), do: :important
  defp normalize_print_updates(_), do: :important

  defp to_required!(nil, name), do: raise("#{name} is not set")
  defp to_required!("", name), do: raise("#{name} is not set")
  defp to_required!(val, _name), do: val

  defp to_int!(nil, name), do: raise("#{name} is not set")

  defp to_int!(val, name) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {i, ""} -> i
      _ -> raise("#{name} must be an integer")
    end
  end

  defp prompt(label) do
    label = String.trim(label)

    case IO.gets("#{label}: ") do
      nil -> ""
      str -> String.trim(str)
    end
  end
end
