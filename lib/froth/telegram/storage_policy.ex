defmodule Froth.Telegram.StoragePolicy do
  @moduledoc """
  Bounds TDLib's local media cache for every Froth Telegram session.

  TDLib stores `storage_max_files_size` in KiB, while `optimizeStorage` accepts
  bytes. The automatic optimizer runs roughly once per day after it is enabled.
  """

  @max_files_size_bytes 10 * 1024 * 1024 * 1024
  @max_time_from_last_access_seconds 30 * 24 * 60 * 60
  @max_file_count 40_000
  @immunity_delay_seconds 60 * 60

  def option_requests do
    [
      integer_option(
        "storage_max_files_size",
        div(@max_files_size_bytes, 1024)
      ),
      integer_option(
        "storage_max_time_from_last_access",
        @max_time_from_last_access_seconds
      ),
      integer_option("storage_max_file_count", @max_file_count),
      integer_option("storage_immunity_delay", @immunity_delay_seconds),
      boolean_option("use_storage_optimizer", true)
    ]
  end

  def optimize_request do
    %{
      "@type" => "optimizeStorage",
      "size" => @max_files_size_bytes,
      "ttl" => @max_time_from_last_access_seconds,
      "count" => @max_file_count,
      "immunity_delay" => @immunity_delay_seconds,
      "file_types" => [],
      "chat_ids" => [],
      "exclude_chat_ids" => [],
      "return_deleted_file_statistics" => true,
      "chat_limit" => 0
    }
  end

  def max_files_size_bytes, do: @max_files_size_bytes

  defp integer_option(name, value) do
    %{
      "@type" => "setOption",
      "name" => name,
      "value" => %{"@type" => "optionValueInteger", "value" => value}
    }
  end

  defp boolean_option(name, value) do
    %{
      "@type" => "setOption",
      "name" => name,
      "value" => %{"@type" => "optionValueBoolean", "value" => value}
    }
  end
end
