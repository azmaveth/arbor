defmodule Mix.Tasks.Arbor.Gen.Impl do
  use Mix.Task

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

  alias Arbor.CodeGen.ImplementationGenerator

  # Mix tasks use Mix environment functions not available during static analysis
  @dialyzer {:nowarn_function, run: 1}
  @dialyzer {:nowarn_function, shell_info: 1}
  @dialyzer {:nowarn_function, shell_error: 1}

  @impl Mix.Task
  def run(args) do
    # Ensure we are in an umbrella project root
    if function_exported?(Mix.Project, :umbrella?, 0) do
      unless Mix.Project.umbrella?() do
        if function_exported?(Mix, :raise, 1) do
          Mix.raise("This task must be run from the root of the Arbor umbrella project.")
        else
          raise "This task must be run from the root of the Arbor umbrella project."
        end
      end
    end

    case parse_args(args) do
      {:ok, contract_module, implementation_module} ->
        generate_implementation(contract_module, implementation_module)

      {:error, reason} ->
        if function_exported?(Mix, :shell, 0) do
          Mix.shell().error(reason)
        else
          IO.puts(:stderr, "Error: #{reason}")
        end

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
    shell_info("Generating implementation for #{contract_module}...")

    case ImplementationGenerator.generate(contract_module, implementation_module) do
      {:ok, path} ->
        shell_info("Created #{path}")

      {:error, :contract_not_found} ->
        shell_error("Contract module #{contract_module} could not be found or loaded.")

      {:error, {:file_exists, path}} ->
        shell_error("File already exists at #{path}. Aborting.")

      {:error, reason} when is_binary(reason) ->
        shell_error("Failed to generate implementation: #{reason}")

      {:error, reason} ->
        shell_error("An unexpected error occurred: #{inspect(reason)}")
    end
  end

  defp print_help do
    shell_info("""
    Usage: mix arbor.gen.impl <ContractModule> <ImplementationModule>

    Arguments:
      <ContractModule>        The fully qualified name of the contract (behaviour) module.
      <ImplementationModule>  The fully qualified name of the new implementation module.
    """)
  end

  # Helper functions to handle Mix environment safely
  defp shell_info(message) do
    if function_exported?(Mix, :shell, 0) do
      Mix.shell().info(message)
    else
      IO.puts(message)
    end
  end

  defp shell_error(message) do
    if function_exported?(Mix, :shell, 0) do
      Mix.shell().error(message)
    else
      IO.puts(:stderr, "Error: #{message}")
    end
  end
end
