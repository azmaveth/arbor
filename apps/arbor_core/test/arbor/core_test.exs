defmodule Arbor.CoreTest do
  use ExUnit.Case
  @moduletag :fast
  doctest Arbor.Core

  test "greets the world" do
    assert Arbor.Core.hello() == :world
  end
end
