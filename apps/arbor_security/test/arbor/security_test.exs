defmodule Arbor.SecurityTest do
  use ExUnit.Case
  @moduletag :fast
  doctest Arbor.Security

  test "greets the world" do
    assert Arbor.Security.hello() == :world
  end
end
