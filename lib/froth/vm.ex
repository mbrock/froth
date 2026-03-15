defmodule Froth.VM do
  @moduledoc """
  Firecracker microVM manager.

  Spawns ephemeral Alpine Linux virtual machines using the /srv/vm
  infrastructure. Each VM gets its own rootfs, TAP device, and
  systemd service. The VMs boot in ~3 seconds and have SSH access.

  ## Usage

      {:ok, vm} = Froth.VM.create(user: "charlie")
      # => %{quid: "dawelizeloke", ip: "172.31.0.2", ...}

      {:ok, output} = Froth.VM.exec(vm.quid, "uname -a")
      # => "Linux dawelizeloke.less.rest 6.12.52-0-virt ..."

      Froth.VM.list()
      Froth.VM.info(vm.quid)
      Froth.VM.destroy(vm.quid)

  ## Architecture

  Wraps the Go/shell tooling in /srv/vm. Each VM is:
  - A Firecracker microVM with its own kernel, initrd, rootfs
  - A TAP device on a /30 subnet (172.31.x.x)
  - A systemd service (vmguest@<quid>.service)
  - Reachable via SSH as root@<guest-ip>
  """

  use GenServer
  require Logger

  @srv_vm "/srv/vm"
  @run_dir "/run/ntvm"
  @ssh_key "/srv/vm/.ssh/id_ed25519"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]},
      type: :worker, restart: :permanent}
  end

  @doc "Create a new VM. Options: user (default 'froth'), distro ('alpine' or 'arch')"
  def create(opts \\ []), do: GenServer.call(__MODULE__, {:create, opts}, 120_000)

  @doc "List all VMs with status"
  def list, do: GenServer.call(__MODULE__, :list, 30_000)

  @doc "Get detailed info about a VM"
  def info(quid), do: GenServer.call(__MODULE__, {:info, quid}, 10_000)

  @doc "Run a command inside a VM via SSH. Returns {:ok, output} or {:error, reason}"
  def exec(quid, command, timeout \\ 30_000),
    do: GenServer.call(__MODULE__, {:exec, quid, command}, timeout + 5_000)

  @doc "Destroy a VM — stop service, remove tap, clean state"
  def destroy(quid), do: GenServer.call(__MODULE__, {:destroy, quid}, 30_000)

  @doc "Destroy all VMs"
  def destroy_all do
    {:ok, vms} = list()
    Enum.map(vms, fn vm -> {vm.quid, destroy(vm.quid)} end)
  end

  # ── GenServer ───────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Logger.info("[VM] Firecracker VM manager online")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, opts}, _from, state),
    do: {:reply, do_create(opts), state}
  def handle_call(:list, _from, state),
    do: {:reply, do_list(), state}
  def handle_call({:info, quid}, _from, state),
    do: {:reply, do_info(quid), state}
  def handle_call({:exec, quid, command}, _from, state),
    do: {:reply, do_exec(quid, command), state}
  def handle_call({:destroy, quid}, _from, state),
    do: {:reply, do_destroy(quid), state}

  # ── Implementation ──────────────────────────────────────────

  defp do_create(opts) do
    user = Keyword.get(opts, :user, "froth")
    distro = Keyword.get(opts, :distro, "alpine")
    quid = generate_quid()

    Logger.info("[VM] Creating #{distro} VM #{quid} for #{user}")

    args = ["#{@srv_vm}/libexec/vm-mkfirecracker",
            "--quid", quid, "--guest-user", user, "--distro", distro]
    env = [{"PATH", "/srv/vm/bin:/srv/vm/libexec:/srv/bin:" <>
                    "/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin"}]

    case System.cmd("sudo", args, env: env, stderr_to_stdout: true) do
      {_output, 0} ->
        Logger.info("[VM] Created #{quid}, starting service")
        case System.cmd("sudo", ["systemctl", "start", "vmguest@#{quid}.service"],
               stderr_to_stdout: true) do
          {_, 0} ->
            guest_ip = read_state(quid, "guest-ip")
            Logger.info("[VM] #{quid} started at #{guest_ip}")
            {:ok, %{quid: quid, ip: guest_ip, user: user,
                     distro: distro, status: :starting}}
          {err, code} ->
            Logger.error("[VM] Failed to start #{quid}: #{err}")
            {:error, {:start_failed, code, err}}
        end
      {output, code} ->
        Logger.error("[VM] Failed to create #{quid}: #{output}")
        {:error, {:create_failed, code, output}}
    end
  end

  defp do_list do
    quids = case File.ls(@run_dir) do
      {:ok, entries} -> entries
      {:error, _} -> []
    end

    vms = Enum.map(quids, fn quid ->
      %{quid: quid,
        ip: read_state(quid, "guest-ip"),
        user: read_state(quid, "guest-user"),
        running: service_active?(quid)}
    end)

    {:ok, vms}
  end

  defp do_info(quid) do
    ip = read_state(quid, "guest-ip")
    if ip do
      {:ok, %{quid: quid, ip: ip,
              mac: read_state(quid, "guest-mac"),
              user: read_state(quid, "guest-user"),
              running: service_active?(quid),
              config: read_state_json(quid, "firecracker.json")}}
    else
      {:error, :not_found}
    end
  end

  defp do_exec(quid, command) do
    ip = read_state(quid, "guest-ip")
    if ip do
      ssh_args = [
        "-i", @ssh_key,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=5",
        "-o", "LogLevel=ERROR",
        "root@#{ip}",
        command
      ]
      case System.cmd("ssh", ssh_args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, String.trim(output)}
        {output, code} -> {:error, {:exit, code, String.trim(output)}}
      end
    else
      {:error, :no_ip}
    end
  end

  defp do_destroy(quid) do
    Logger.info("[VM] Destroying #{quid}")
    System.cmd("sudo", ["systemctl", "stop", "vmguest@#{quid}.service"],
      stderr_to_stdout: true)
    System.cmd("sudo", ["ip", "link", "del", "#{quid}-tap0"],
      stderr_to_stdout: true)
    for dir <- ["/var/lib/ntvm/#{quid}", "#{@run_dir}/#{quid}"] do
      System.cmd("sudo", ["rm", "-rf", dir], stderr_to_stdout: true)
    end
    clean_hosts(quid)
    Logger.info("[VM] Destroyed #{quid}")
    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────

  defp generate_quid do
    consonants = ~c"bcdfghjklmnprstvwyz"
    vowels = ~c"aeiou"
    1..12
    |> Enum.map(fn i ->
      chars = if rem(i, 2) == 1, do: consonants, else: vowels
      Enum.random(chars)
    end)
    |> List.to_string()
  end

  defp read_state(quid, file) do
    for dir <- ["/var/lib/ntvm/#{quid}", "#{@run_dir}/#{quid}"] do
      case File.read("#{dir}/#{file}") do
        {:ok, content} -> String.trim(content)
        _ -> nil
      end
    end
    |> Enum.find(& &1)
  end

  defp read_state_json(quid, file) do
    for dir <- ["/var/lib/ntvm/#{quid}", "#{@run_dir}/#{quid}"] do
      case File.read("#{dir}/#{file}") do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} -> data
            _ -> nil
          end
        _ -> nil
      end
    end
    |> Enum.find(& &1)
  end

  defp service_active?(quid) do
    case System.cmd("systemctl", ["is-active", "vmguest@#{quid}.service"],
           stderr_to_stdout: true) do
      {"active\n", 0} -> true
      _ -> false
    end
  end

  defp clean_hosts(quid) do
    case File.read("/etc/hosts") do
      {:ok, content} ->
        cleaned = content
          |> String.split("\n")
          |> Enum.reject(&String.contains?(&1, quid))
          |> Enum.join("\n")
        System.cmd("sudo", ["tee", "/etc/hosts"],
          input: cleaned, stderr_to_stdout: true)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end
end
