defmodule Froth.Telegram.StoragePolicyTest do
  use ExUnit.Case, async: true

  alias Froth.Telegram.StoragePolicy

  @max_files_size_kib 10 * 1024 * 1024
  @max_files_size_bytes @max_files_size_kib * 1024
  @max_time_from_last_access_seconds 30 * 24 * 60 * 60
  @immunity_delay_seconds 60 * 60

  test "enables the optimizer after setting bounded cache options" do
    assert [
             %{
               "@type" => "setOption",
               "name" => "storage_max_files_size",
               "value" => %{
                 "@type" => "optionValueInteger",
                 "value" => @max_files_size_kib
               }
             },
             %{
               "@type" => "setOption",
               "name" => "storage_max_time_from_last_access",
               "value" => %{
                 "@type" => "optionValueInteger",
                 "value" => @max_time_from_last_access_seconds
               }
             },
             %{
               "@type" => "setOption",
               "name" => "storage_max_file_count",
               "value" => %{
                 "@type" => "optionValueInteger",
                 "value" => 40_000
               }
             },
             %{
               "@type" => "setOption",
               "name" => "storage_immunity_delay",
               "value" => %{
                 "@type" => "optionValueInteger",
                 "value" => @immunity_delay_seconds
               }
             },
             %{
               "@type" => "setOption",
               "name" => "use_storage_optimizer",
               "value" => %{"@type" => "optionValueBoolean", "value" => true}
             }
           ] = StoragePolicy.option_requests()
  end

  test "builds an immediate optimization request with the same limits" do
    assert %{
             "@type" => "optimizeStorage",
             "size" => @max_files_size_bytes,
             "ttl" => @max_time_from_last_access_seconds,
             "count" => 40_000,
             "immunity_delay" => @immunity_delay_seconds,
             "file_types" => [],
             "chat_ids" => [],
             "exclude_chat_ids" => [],
             "return_deleted_file_statistics" => true,
             "chat_limit" => 0
           } = StoragePolicy.optimize_request()
  end
end
