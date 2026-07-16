defmodule Froth.Comic.SemanticTest do
  use ExUnit.Case, async: true

  alias Froth.Comic.Semantic

  test "priority rules recognize Comic Chat text cues" do
    assert %{emotion: :laughing, gesture: :open} =
             Semantic.analyze(%{text: "LOL, that worked!!!"})

    assert %{emotion: :happy} = Semantic.analyze(%{text: "nice :)"})
    assert %{emotion: :sad} = Semantic.analyze(%{text: "oh no :("})
    assert %{gesture: :wave} = Semantic.analyze(%{text: "Hello there"})

    assert %{gesture: :point_other} =
             Semantic.analyze(%{text: "Are you ready?"})
  end

  test "explicit emotions override inferred emotion" do
    assert %{emotion: :happy, balloon: :shout} =
             Semantic.analyze(%{text: "I AM FURIOUS!!!", emotion: :happy})
  end

  test "balloon modes follow message form" do
    assert %{balloon: :action} = Semantic.analyze(%{text: "/me waves"})
    assert %{balloon: :think} = Semantic.analyze(%{text: "(maybe later)"})
    assert %{balloon: :whisper} = Semantic.analyze(%{text: "quietly..."})
  end
end
