# Froth

## Comic strips

`Froth.Comic` generates Comic Chat-inspired PNG strips from Telegram-shaped
message maps. See [`docs/comic.md`](docs/comic.md) for the API, original
algorithm notes, and asset regeneration workflow.

## Requirements

- Elixir + Erlang/OTP via `asdf` (versions pinned in `.tool-versions`)
- PostgreSQL

## Setup

```bash
sudo ln -s /path/to/froth /srv/froth
sudo loginctl enable-linger $USER
cp .env.example .env               # fill in API keys
make setup                          # deps, build, cnode, install + start
```

This installs dependencies, builds the cnode, symlinks the systemd unit, and
starts the service. The service uses `Type=notify` — systemd waits for the
app to signal readiness after the supervisor tree is up.

That path is for a managed host with the native stack available. On a fresh
development machine, prefer the standalone full-node path below instead of
jumping straight to `make setup`.

## Standalone Dev Full Node

Start a local PostgreSQL instance first. If you already have PostgreSQL, use
that. Otherwise this repo includes a Docker-backed helper:

```bash
bin/dev_db up
```

Then boot a standalone full node with local-safe defaults:

```bash
bin/dev_full
```

`bin/dev_full` keeps the runtime shape as a full node, but defaults to:

- `FROTH_CLUSTER_NODES=off` so a fresh machine does not immediately try to join
  the Tailscale cluster
- `FROTH_DISABLE_CHARLIE=1` so Charlie does not auto-start before its Telegram
  session exists on this machine
- `FROTH_DAILY_DIGEST_ENABLED=0` so the Charlie-bound digest job stays off on a
  secondary/dev node

Override those env vars if you explicitly want clustered behaviour or Charlie
auto-start.

If the machine's short hostname resolves to its Tailscale IP instead of
loopback, give Froth an explicit local node alias in `.env`:

```bash
FROTH_NODE_NAME="froth@temple.local"
```

and add the alias to `/etc/hosts`:

```text
127.0.0.1 temple temple.local
::1 temple temple.local
```

This avoids the macOS/Tailscale self-connect problem while still giving the
machine a human name.

This path does not require TgCalls. TDLib can be added later by building the
TDLib cnode and configuring Telegram sessions. The voice-call registration
plugin remains optional.

```bash
bin/restart                          # restart the service
journalctl --user -u froth           # view logs
systemctl --user status froth        # check status
```

On macOS, use the bundled `launchd` helper instead of `systemd`:

```bash
bin/launch_agent install             # install + start per-user service
bin/launch_agent wait                # wait until launchd + Froth are ready
bin/launch_agent status              # show launchd state
bin/logs                             # tail logs
bin/restart                          # restart the service
bin/launch_agent uninstall           # unload + remove the service
```

The macOS service is a per-user LaunchAgent, analogous to the Linux
`systemd --user` service. It runs `bin/dev_full`, so it loads `.env`,
keeps the standalone full-node defaults, and comes back automatically
after crashes or login-session restarts.

`launchd` itself does not provide a generic `Type=notify` equivalent for
arbitrary CLI daemons. The Froth helper compensates by making
`bin/launch_agent install`, `start`, `restart`, and `wait` block until the
LaunchAgent is running and the Froth node has brought up its supervisor tree
and endpoint.

### Manual

```bash
FROTH_NODE_NAME="froth@temple.local" elixir --name froth@temple.local -S mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000).

### RPC

Run code on the live local Froth node:

```bash
bin/rpc 'node()'
bin/rpc 'Froth.Telegram.list_sessions()'
echo 'IO.puts("hello")' | bin/rpc
```

`bin/rpc` now follows `FROTH_NODE_NAME` from `.env`. Set `RPC_NODE=froth@swa`
to target a different host explicitly.

## Telemetry Follow

Prefer `bin/follow` over `mix froth.follow`. It uses the same distributed-node
backend, but disables the BEAM break menu so `Ctrl-C` exits immediately instead
of dropping into the Erlang break prompt.

```bash
bin/follow
bin/follow froth.telegram
bin/follow --errors
bin/follow --tail 120
```

`mix froth.follow` still exists as a compatibility wrapper.

## Telegram Auth

Authenticate a configured Telegram session against the already-running node
without `iex`:

```bash
bin/telegram_auth mbrockman
```

That drives TDLib phone/code/2FA auth over RPC and returns once the session
reaches `authorizationStateReady`.

This does not run a Froth history backfill. Full chat-history import remains an
explicit step:

```bash
mix froth.telegram.backfill --session mbrockman
```

## Cluster

Froth uses `libcluster` with the EPMD strategy over Tailscale short hostnames.
By default the static cluster peers are `froth@igloo`, `froth@swa`, and
`froth@Mikaels-Mac-mini`. On March 20, 2026 the Mac Mini's actual Erlang short
node name is still derived from its local hostname, so that mixed-case host is
the one the cluster uses today.

You can override or disable that at boot:

```bash
export FROTH_NODE_ROLE="full"       # use "worker" on render-only nodes
export FROTH_COORDINATOR_NODE="froth@igloo"
export FROTH_CLUSTER_NODES="froth@igloo,froth@swa,froth@Mikaels-Mac-mini"
export FROTH_HTTP_IP="100.64.48.44" # bind igloo to its tailnet IP for object-store access
# or disable clustering entirely
export FROTH_CLUSTER_NODES="off"
```

For worker nodes, the simplest setup is a star topology: set
`FROTH_NODE_ROLE=worker`, leave `FROTH_CLUSTER_NODES` unset (or `default`), and
let the worker connect only to `FROTH_COORDINATOR_NODE`.

The tracked `bin/serve` and `bin/serve_worker` scripts also boot distributed
Erlang with `connect_all=false` and `prevent_overlapping_partitions=false` so
that coordinator/worker stars stay stable even when workers do not resolve each
other directly.

All cluster members need the same Erlang cookie. Worker-only nodes can run the
minimal boot path with:

```bash
/srv/froth/bin/serve_worker
```

The tracked `froth-worker.service` unit uses that entrypoint for systemd user
services on nodes such as `swa`.

## TDLib (Telegram) C Node

TDLib bridge implemented as a distributed Erlang C node. One shared process
multiplexes multiple Telegram sessions via TDLib `client_id`s.

* TDLib is a git submodule at `vendor/tdlib`
* C node sources at `cnode/tdlib_cnode`
* Build output: `priv/native/tdlib_cnode/`

Build prerequisites (Linux): `cmake`, `gperf`, zlib headers.

```bash
bin/build_tdlib_cnode
```

For a fresh secondary/dev instance, this is the first Telegram-native build to
aim for. The TgCalls/WebRTC path is optional unless you specifically need voice
call support.

## TgCalls Dependency Smoke Build

`tgcalls` is wired as a submodule plus a pinned WebRTC dependency set. The
smoke build compiles key private-call and group-call translation units in
`-fsyntax-only` mode (compile check, no final link step yet).

```bash
git submodule update --init --recursive
bin/build_tgcalls_smoke
# or:
make tgcalls-smoke
```

Sessions are configured in the `telegram_sessions` database table and
auto-start on boot. From `bin/rpc`:

```elixir
Froth.Telegram.subscribe("charlie")
{:ok, res} = Froth.Telegram.call("charlie", %{"@type" => "getOption", "name" => "version"})
```
