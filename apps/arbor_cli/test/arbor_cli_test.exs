defmodule ArborCliTest do
  use ExUnit.Case, async: true

  test "version/0 returns current version" do
    assert ArborCli.version() == "0.1.0"
  end

  test "default_gateway_endpoint/0 returns default endpoint" do
    assert ArborCli.default_gateway_endpoint() =~ "localhost"
  end

  test "config/0 returns configuration map" do
    config = ArborCli.config()
    
    assert is_map(config)
    assert Map.has_key?(config, :gateway_endpoint)
    assert Map.has_key?(config, :timeout)
    assert Map.has_key?(config, :output_format)
    assert Map.has_key?(config, :verbose)
  end
end