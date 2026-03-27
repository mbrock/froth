defmodule Froth.Cast.Recording do
  @moduledoc false

  @type theme :: %{
          optional(:name) => String.t(),
          required(:fg) => String.t(),
          required(:bg) => String.t(),
          required(:palette) => [String.t()]
        }

  @type event :: %{
          required(:at) => float(),
          required(:code) => String.t(),
          required(:data) => term()
        }

  @type t :: %__MODULE__{
          version: pos_integer(),
          cols: pos_integer(),
          rows: pos_integer(),
          max_cols: pos_integer(),
          max_rows: pos_integer(),
          terminal_type: String.t() | nil,
          terminal_version: String.t() | nil,
          timestamp: integer() | nil,
          duration_s: float(),
          idle_time_limit: float() | nil,
          command: String.t() | nil,
          title: String.t() | nil,
          env: map(),
          theme: theme() | nil,
          events: [event()]
        }

  defstruct version: 2,
            cols: 80,
            rows: 24,
            max_cols: 80,
            max_rows: 24,
            terminal_type: nil,
            terminal_version: nil,
            timestamp: nil,
            duration_s: 0.0,
            idle_time_limit: nil,
            command: nil,
            title: nil,
            env: %{},
            theme: nil,
            events: []
end
