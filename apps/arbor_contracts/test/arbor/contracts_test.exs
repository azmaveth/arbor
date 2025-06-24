defmodule Arbor.ContractsTest do
  use ExUnit.Case
  @moduletag :fast
  doctest Arbor.Contracts

  test "greets the world" do
    assert Arbor.Contracts.hello() == :world
  end
end
