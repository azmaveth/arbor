defmodule Arbor.CodeGen.ContractAnalyzer do
  @moduledoc """
  Analyzes a contract module to extract callback information.
  """

  @doc """
  Analyzes the given contract module and extracts its callbacks.

  It ensures the module is loaded and then introspects its behaviour information
  to find all `@callback` and `@macrocallback` definitions.
  """
  @spec analyze(module()) :: {:ok, list(map())} | {:error, :contract_not_found}
  @spec extract_callbacks(module()) :: {:ok, list(map())} | {:error, :contract_not_found}
  def extract_callbacks(contract_module), do: analyze(contract_module)

  def analyze(contract_module) do
    # Ensure all dependencies are compiled and available
    Mix.Task.run("deps.compile", [])
    Mix.Task.run("compile", [])

    case Code.ensure_loaded(contract_module) do
      {:module, _} ->
        callbacks = get_callbacks(contract_module)
        docs = get_callback_docs(contract_module)
        enriched_callbacks = enrich_callbacks(callbacks, docs)
        {:ok, enriched_callbacks}

      {:error, _} ->
        {:error, :contract_not_found}
    end
  end

  defp get_callbacks(module) do
    if function_exported?(module, :behaviour_info, 1) do
      callbacks =
        try do
          module.behaviour_info(:callbacks)
        rescue
          FunctionClauseError -> []
        end

      macrocallbacks =
        try do
          module.behaviour_info(:macrocallbacks)
        rescue
          FunctionClauseError -> []
        end

      callbacks ++ macrocallbacks
    else
      []
    end
  end

  defp get_callback_docs(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, _, _, callbacks_docs} ->
        Map.new(callbacks_docs, fn {signature, _line, _spec, doc, _meta} ->
          {signature, doc}
        end)

      _ ->
        %{}
    end
  end

  defp enrich_callbacks(callbacks, docs) do
    Enum.map(callbacks, fn {name, arity} ->
      signature = {name, arity}
      doc = Map.get(docs, signature, "")

      %{
        name: name,
        arity: arity,
        doc: doc
      }
    end)
  end
end
