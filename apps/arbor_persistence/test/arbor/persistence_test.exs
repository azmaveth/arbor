defmodule Arbor.PersistenceTest do
  use ExUnit.Case
  doctest Arbor.Persistence

  test "greets the world" do
    assert Arbor.Persistence.hello() == :world
  end
end
