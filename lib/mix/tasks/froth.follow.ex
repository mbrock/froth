defmodule Mix.Tasks.Froth.Follow do
  @moduledoc """
  Connect to the running node and follow telemetry events.

  `bin/follow` is the preferred entrypoint because it disables the BEAM break
  menu, so `Ctrl-C` exits like a normal Unix tool. The Mix task remains as a
  compatibility wrapper.

      bin/follow
      bin/follow --tail 120
      bin/follow froth.agent
      bin/follow --cycle 01ABC...
      bin/follow --errors

  Flags:

    * `--tail N` - number of recent matching entries to print before following
    * `--raw` - render raw event names and metadata
    * `--errors` - render only warn/error entries
    * `--cycle ID` - restrict to a cycle id prefix
    * `--span ID` - restrict to a span id prefix
  """
  @shortdoc "Follow telemetry events on the running node"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Froth.Mix.Follow.main(args)
  end
end
