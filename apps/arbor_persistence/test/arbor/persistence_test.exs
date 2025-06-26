defmodule Arbor.PersistenceTest do
  @moduledoc """
  Basic tests for the Arbor.Persistence module.

  Verifies the persistence application module loads correctly
  and provides expected functionality.
  """

  use ExUnit.Case
  @moduletag :fast
  doctest Arbor.Persistence

  test "greets the world" do
    assert Arbor.Persistence.hello() == :world
  end
end
