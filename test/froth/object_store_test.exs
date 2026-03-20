defmodule Froth.ObjectStoreTest do
  use ExUnit.Case, async: false

  alias Froth.ObjectStore

  setup do
    root_dir =
      Path.join(System.tmp_dir!(), "froth-object-store-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:froth, ObjectStore, [])

    Application.put_env(:froth, ObjectStore,
      mode: :local,
      root_dir: root_dir,
      public_base: "http://example.test/froth/objects",
      write_token: "secret"
    )

    on_exit(fn ->
      Application.put_env(:froth, ObjectStore, previous)
      File.rm_rf(root_dir)
    end)

    {:ok, root_dir: root_dir}
  end

  test "put_file/3 and fetch/2 round-trip a stored object", %{root_dir: root_dir} do
    source = Path.join(root_dir, "source.txt")
    destination = Path.join(root_dir, "downloaded.txt")
    File.mkdir_p!(root_dir)
    File.write!(source, "hello object store")

    assert {:ok, stored} = ObjectStore.put_file("video/test/source.txt", source)
    assert stored.url == "http://example.test/froth/objects/video/test/source.txt"

    assert {:ok, path} = ObjectStore.local_path("video/test/source.txt")
    assert File.read!(path) == "hello object store"

    assert {:ok, ^destination} = ObjectStore.fetch("video/test/source.txt", destination)
    assert File.read!(destination) == "hello object store"
  end

  test "normalize_key/1 rejects traversal keys" do
    assert {:error, :invalid_key} = ObjectStore.normalize_key("../etc/passwd")
    assert {:error, :invalid_key} = ObjectStore.normalize_key("video/../../oops")
  end
end
