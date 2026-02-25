defmodule Froth.Inference.EffectExecutor do
  @moduledoc """
  Transport-facing side effects needed by inference session runtime.

  Session logic should call this behaviour rather than transport modules
  directly so alternate transports can be plugged in.
  """

  @callback send_error(state :: map(), chat_id :: integer(), message :: binary()) :: any()
  @callback send_italic(
              state :: map(),
              chat_id :: integer(),
              reply_to :: integer(),
              text :: binary()
            ) ::
              any()

  @callback edit_message_italic(
              state :: map(),
              chat_id :: integer(),
              message_id :: integer(),
              text :: binary()
            ) :: any()

  @callback send_typing(state :: map(), chat_id :: integer()) :: any()

  @callback send_message(
              state :: map(),
              chat_id :: integer(),
              text :: binary(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @callback send_or_edit_eval_prompt(
              state :: map(),
              inference_session :: struct(),
              last_message_id :: integer() | nil
            ) :: {:ok, integer(), binary()} | {:error, term()}
end
