defmodule Froth.Browser do
  @moduledoc """
  Supervised Chromium orchestration over the Chrome DevTools Protocol.

  The initial slice uses one browser process per lease. Each lease is
  identified by a stable browser ID registered in `Froth.Browser.Registry`.
  """

  alias Froth.Browser.Instance

  @default_checkout_timeout_ms 15_000

  @type browser_id :: String.t()

  @doc """
  Starts a supervised browser lease and waits until Chromium is ready.
  """
  @spec checkout(keyword()) :: {:ok, browser_id()} | {:error, term()}
  def checkout(opts \\ []) when is_list(opts) do
    browser_id = Keyword.get(opts, :browser_id, Froth.Tasks.generate_id("browser"))
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_checkout_timeout_ms)

    child_opts =
      opts
      |> Keyword.put(:browser_id, browser_id)
      |> Keyword.delete(:timeout_ms)

    with {:ok, pid} <- start_instance(child_opts),
         :ok <- Instance.await_ready(pid, timeout_ms) do
      {:ok, browser_id}
    end
  end

  @doc """
  Releases a browser lease and terminates the Chromium process.
  """
  @spec release(browser_id() | pid()) :: :ok | {:error, term()}
  def release(browser_ref) do
    with {:ok, pid} <- fetch_pid(browser_ref) do
      Instance.release(pid)
    end
  end

  @doc """
  Navigates the page to a URL and waits for the document ready state.
  """
  @spec navigate(browser_id() | pid(), String.t(), keyword()) :: :ok | {:error, term()}
  def navigate(browser_ref, url, opts \\ []) when is_binary(url) and is_list(opts) do
    with {:ok, pid} <- fetch_pid(browser_ref) do
      Instance.navigate(pid, url, opts)
    end
  end

  @doc """
  Sets the emulated browser viewport via CDP device metrics.
  """
  @spec set_viewport(browser_id() | pid(), keyword()) :: :ok | {:error, term()}
  def set_viewport(browser_ref, opts \\ []) when is_list(opts) do
    with {:ok, pid} <- fetch_pid(browser_ref) do
      Instance.set_viewport(pid, opts)
    end
  end

  @doc """
  Replaces the current page document with the given HTML string.
  """
  @spec set_content(browser_id() | pid(), String.t(), keyword()) :: :ok | {:error, term()}
  def set_content(browser_ref, html, opts \\ []) when is_binary(html) and is_list(opts) do
    with {:ok, pid} <- fetch_pid(browser_ref) do
      Instance.set_content(pid, html, opts)
    end
  end

  @doc """
  Evaluates JavaScript in the current page and returns the decoded value.
  """
  @spec eval(browser_id() | pid(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def eval(browser_ref, expression, opts \\ []) when is_binary(expression) and is_list(opts) do
    with {:ok, pid} <- fetch_pid(browser_ref) do
      Instance.eval(pid, expression, opts)
    end
  end

  @doc """
  Captures a PNG screenshot and returns the saved file path.
  """
  @spec screenshot(browser_id() | pid(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def screenshot(browser_ref, opts \\ []) when is_list(opts) do
    with {:ok, pid} <- fetch_pid(browser_ref) do
      Instance.screenshot(pid, opts)
    end
  end

  @doc """
  Clicks the first element matching a CSS selector.
  """
  @spec click(browser_id() | pid(), String.t(), keyword()) :: :ok | {:error, term()}
  def click(browser_ref, selector, opts \\ []) when is_binary(selector) and is_list(opts) do
    with {:ok, pid} <- fetch_pid(browser_ref) do
      Instance.click(pid, selector, opts)
    end
  end

  @doc """
  Types text into the first element matching a CSS selector.
  """
  @spec type(browser_id() | pid(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def type(browser_ref, selector, text, opts \\ [])
      when is_binary(selector) and is_binary(text) and is_list(opts) do
    with {:ok, pid} <- fetch_pid(browser_ref) do
      Instance.type(pid, selector, text, opts)
    end
  end

  @doc """
  Returns runtime info for a browser lease.
  """
  @spec info(browser_id() | pid()) :: {:ok, map()} | {:error, term()}
  def info(browser_ref) do
    with {:ok, pid} <- fetch_pid(browser_ref) do
      Instance.info(pid)
    end
  end

  @doc """
  Looks up a running browser lease in the registry.
  """
  @spec whereis(browser_id()) :: pid() | nil
  def whereis(browser_id) when is_binary(browser_id) do
    case Registry.lookup(Froth.Browser.Registry, browser_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp fetch_pid(pid) when is_pid(pid), do: {:ok, pid}

  defp fetch_pid(browser_id) when is_binary(browser_id) do
    case whereis(browser_id) do
      nil -> {:error, :browser_not_running}
      pid -> {:ok, pid}
    end
  end

  defp start_instance(opts) do
    DynamicSupervisor.start_child(
      Froth.Browser.InstanceSupervisor,
      {Instance, opts}
    )
  end
end
