defmodule Arbor.ContractsTest do
  use ExUnit.Case
  doctest Arbor.Contracts

  test "greets the world" do
    assert Arbor.Contracts.hello() == :world
  end
end
