defmodule Mix.Tasks.Arbor.Gen.Impl do
  @shortdoc "Generates an implementation for a contract"

  @moduledoc """
  Generates a boilerplate implementation for an Arbor contract (behaviour).

  This task creates a new module that implements a specified contract,
  scaffolding all required callback functions with `@impl true`.

  ## Usage

      mix arbor.gen.impl ContractModule ImplementationModule

  ## Examples

      mix arbor.gen.impl Arbor.Contracts.Cluster.Supervisor Arbor.Core.HordeSupervisor

  The `ImplementationModule` will be created in the appropriate application
  directory based on its name (e.g., `Arbor.Core.*` modules are placed
  in the `arbor_core` app).
  """

  use Mix.Task

  alias Arbor.CodeGen.ImplementationGenerator

  @impl Mix.Task
  def run(args) do
    # Ensure we are in an umbrella project root
    unless Mix.Project.umbrella?() do
      Mix.raise("This task must be run from the root of the Arbor umbrella project.")
    end

    case parse_args(args) do
      {:ok, contract_module, implementation_module} ->
        generate_implementation(contract_module, implementation_module)

      {:error, reason} ->
        Mix.shell().error(reason)
        print_help()
    end
  end

  defp parse_args(args) do
    case args do
      [contract_str, implementation_str] ->
        with {:ok, contract_module} <- to_module(contract_str, "Contract"),
             {:ok, implementation_module} <- to_module(implementation_str, "Implementation") do
          {:ok, contract_module, implementation_module}
        else
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, "Invalid arguments. Expected exactly two arguments."}
    end
  end

  defp to_module(str, type) do
    # Parse as module path - this works even if module doesn't exist yet
    parts = String.split(str, ".")
    module = Module.concat(parts)
    {:ok, module}
  rescue
    ArgumentError ->
      {:error, "Invalid #{type} module name: #{str}"}
  end

  defp generate_implementation(contract_module, implementation_module) do
    Mix.shell().info("Generating implementation for #{contract_module}...")

    case ImplementationGenerator.generate(contract_module, implementation_module) do
      {:ok, path} ->
        Mix.shell().info("Created #{path}")

      {:error, :contract_not_found} ->
        Mix.shell().error("Contract module #{contract_module} could not be found or loaded.")

      {:error, {:file_exists, path}} ->
        Mix.shell().error("File already exists at #{path}. Aborting.")

      {:error, reason} when is_binary(reason) ->
        Mix.shell().error("Failed to generate implementation: #{reason}")

      {:error, reason} ->
        Mix.shell().error("An unexpected error occurred: #{inspect(reason)}")
    end
  end

  defp print_help do
    Mix.shell().info("""
    Usage: mix arbor.gen.impl <ContractModule> <ImplementationModule>

    Arguments:
      <ContractModule>        The fully qualified name of the contract (behaviour) module.
      <ImplementationModule>  The fully qualified name of the new implementation module.
    """)
  end
end
