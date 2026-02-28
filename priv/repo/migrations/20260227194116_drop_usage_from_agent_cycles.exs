defmodule Froth.Repo.Migrations.DropUsageFromAgentCycles do
  use Ecto.Migration

  def change do
    alter table(:agent_cycles) do
      remove :usage, :jsonb
      remove :cost_usd, :float
    end
  end
end
