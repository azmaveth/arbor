defmodule Arbor.PersistenceTest do
  use ExUnit.Case
  @moduletag :fast
  doctest Arbor.Persistence

  test "greets the world" do
    assert Arbor.Persistence.hello() == :world
  end
end
