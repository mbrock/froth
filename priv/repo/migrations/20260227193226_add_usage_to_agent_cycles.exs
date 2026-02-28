defmodule Froth.Repo.Migrations.AddUsageToAgentCycles do
  use Ecto.Migration

  def change do
    alter table(:agent_cycles) do
      add :usage, :jsonb
      add :cost_usd, :float
    end

    alter table(:agent_messages) do
      add :metadata, :jsonb
    end
  end
end
