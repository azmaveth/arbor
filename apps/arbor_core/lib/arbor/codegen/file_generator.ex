defmodule Arbor.CodeGen.FileGenerator do
  @moduledoc """
  Handles file system operations for code generation.

  This module determines appropriate file paths based on module names
  and handles writing generated code to the file system.
  """

  @doc """
  Writes the given code to a file determined by the implementation module name.

  Returns the path where the file was written or an error if something went wrong.
  """
  @spec write_file(implementation_module :: module(), code :: String.t()) ::
          {:ok, file_path :: String.t()} | {:error, atom() | {atom(), String.t()}}
  def write_file(implementation_module, code) do
    case determine_file_path(implementation_module) do
      {:ok, file_path} ->
        if File.exists?(file_path) do
          {:error, {:file_exists, file_path}}
        else
          case ensure_directory_exists(file_path) do
            :ok ->
              case File.write(file_path, code) do
                :ok -> {:ok, file_path}
                {:error, reason} -> {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Determines the appropriate file path for a given module name.

  Maps module names to their conventional locations in the umbrella project structure.
  """
  @spec determine_file_path(module()) :: {:ok, String.t()} | {:error, String.t()}
  def determine_file_path(module_name) do
    module_string = inspect(module_name)

    cond do
      String.starts_with?(module_string, "Arbor.Core.") ->
        path = module_to_path(module_string, "Arbor.Core.", "apps/arbor_core/lib/arbor/core/")
        {:ok, path}

      String.starts_with?(module_string, "Arbor.Security.") ->
        path =
          module_to_path(
            module_string,
            "Arbor.Security.",
            "apps/arbor_security/lib/arbor/security/"
          )

        {:ok, path}

      String.starts_with?(module_string, "Arbor.Persistence.") ->
        path =
          module_to_path(
            module_string,
            "Arbor.Persistence.",
            "apps/arbor_persistence/lib/arbor/persistence/"
          )

        {:ok, path}

      String.starts_with?(module_string, "Arbor.Contracts.") ->
        path =
          module_to_path(
            module_string,
            "Arbor.Contracts.",
            "apps/arbor_contracts/lib/arbor/contracts/"
          )

        {:ok, path}

      String.starts_with?(module_string, "Arbor.") ->
        # General lib/ folder for other Arbor modules
        path = module_to_path(module_string, "Arbor.", "lib/arbor/")
        {:ok, path}

      true ->
        {:error,
         "Unable to determine file path for module #{module_string}. Module should start with 'Arbor.'"}
    end
  end

  defp module_to_path(module_string, prefix, base_path) do
    # Remove the prefix and convert to file path
    relative_module = String.replace_prefix(module_string, prefix, "")

    # Convert CamelCase to snake_case and replace dots with slashes
    file_path =
      relative_module
      |> Macro.underscore()
      |> String.replace(".", "/")

    base_path <> file_path <> ".ex"
  end

  defp ensure_directory_exists(file_path) do
    dir_path = Path.dirname(file_path)

    case File.mkdir_p(dir_path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
