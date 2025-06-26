defmodule Arbor.ContractsTest do
  @moduledoc """
  Basic tests for the Arbor.Contracts module.

  Verifies the contracts application module loads correctly
  and provides expected functionality.
  """

  use ExUnit.Case
  @moduletag :fast
  doctest Arbor.Contracts

  test "greets the world" do
    assert Arbor.Contracts.hello() == :world
  end
end
