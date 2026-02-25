# Froth

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

```bash
bin/restart                          # restart the service
journalctl --user -u froth           # view logs
systemctl --user status froth        # check status
```

### Manual

```bash
elixir --sname froth -S mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000).

### RPC

Run code on the live `froth@<hostname>` node:

```bash
bin/rpc 'node()'
bin/rpc 'Froth.Telegram.list_sessions()'
echo 'IO.puts("hello")' | bin/rpc
```

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

## TgCalls Runtime Smoke

Build the registration plugin and verify C node runtime registration from Elixir:

```bash
make tgcalls-runtime-smoke
# or:
bin/build_tgcalls_register_plugin
mix froth.tgcalls.smoke
```

`mix froth.tgcalls.smoke` uses distributed RPC against an already-running Froth
node and does not boot local Telegram sessions.
