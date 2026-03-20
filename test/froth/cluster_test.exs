defmodule Froth.ClusterTest do
  use ExUnit.Case, async: true

  test "configured_nodes/2 defaults to igloo, swa, and the mac mini for full nodes" do
    assert Froth.Cluster.configured_nodes(nil, node_role: :full) ==
             [:froth@igloo, :froth@swa, :"froth@Mikaels-Mac-mini"]
  end

  test "configured_nodes/2 defaults worker nodes to the coordinator" do
    assert Froth.Cluster.configured_nodes(nil,
             node_role: :worker,
             coordinator_node: "froth@igloo"
           ) == [:froth@igloo]
  end

  test "configured_nodes/1 can be disabled" do
    assert Froth.Cluster.configured_nodes("off") == []
  end

  test "configured_nodes/1 parses a node list" do
    assert Froth.Cluster.configured_nodes("froth@swa, froth@igloo invalid") ==
             [:froth@swa, :froth@igloo]
  end

  test "topologies/0 is empty when distribution is not running" do
    refute Node.alive?()
    assert Froth.Cluster.topologies() == []
  end
end
