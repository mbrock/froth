defmodule Froth.Browser.ChromeTest do
  use ExUnit.Case, async: true

  alias Froth.Browser.Chrome

  test "find_executable resolves an explicit command name through the resolver" do
    resolver = fn
      "chromium" -> "/usr/bin/chromium"
      _ -> nil
    end

    assert {:ok, "/usr/bin/chromium"} =
             Chrome.find_executable(explicit: "chromium", resolver: resolver)
  end

  test "launch_args keeps the blank page as the last argument" do
    args = Chrome.launch_args("/tmp/froth-browser", extra_args: ["--window-size=1280,720"])

    assert hd(args) == "--user-data-dir=/tmp/froth-browser"
    assert "--remote-debugging-port=0" in args
    assert "--window-size=1280,720" in args
    assert List.last(args) == "about:blank"
  end

  test "launch_args uses a headful profile without forcing headless mode" do
    args = Chrome.launch_args("/tmp/froth-browser", profile: :headful_debug)

    refute "--headless=new" in args
    refute "--disable-gpu" in args
    assert "--start-maximized" in args
  end

  test "profile_metadata describes browser capabilities" do
    assert %{
             headful?: true,
             visible?: true,
             gpu?: true,
             webcodecs?: true
           } = Chrome.profile_metadata(:headful_debug)

    assert %{headless?: true, gpu?: false} = Chrome.profile_metadata(:headless_bulk)
  end

  test "parse_devtools_active_port parses the chrome port file" do
    contents = "42783\n/devtools/browser/abc123\n"

    assert {:ok, %{port: 42_783, browser_path: "/devtools/browser/abc123"}} =
             Chrome.parse_devtools_active_port(contents)
  end

  test "parse_devtools_active_port rejects malformed contents" do
    assert {:error, :invalid_devtools_port} = Chrome.parse_devtools_active_port("garbage\n")
  end
end
