defmodule Arbor.CodeGen.ContractAnalyzer do
  @moduledoc """
  Analyzes a contract module to extract callback information.
  """

  @behaviour Arbor.Contracts.Codegen.CodeGen.ContractAnalyzer

  @doc """
  Analyzes the given contract module and extracts its callbacks.

  It ensures the module is loaded and then introspects its behaviour information
  to find all `@callback` and `@macrocallback` definitions.
  """
  @spec analyze(module()) :: {:ok, list(map())} | {:error, :contract_not_found}
  @spec extract_callbacks(module()) :: {:ok, list(map())} | {:error, :contract_not_found}
  def extract_callbacks(contract_module), do: analyze(contract_module)

  @doc """
  Process contract analysis for the given input.
  Currently delegates to analyze/1 for contract module analysis.
  """
  @impl true
  @spec process(input :: any()) :: {:ok, [map()]} | {:error, :contract_not_found | :invalid_input}
  def process(contract_module) when is_atom(contract_module) do
    analyze(contract_module)
  end

  def process(_input) do
    {:error, :invalid_input}
  end

  @doc """
  Configure the contract analyzer with options.
  Currently no configuration options are supported.
  """
  @impl true
  @spec configure(options :: keyword()) :: :ok
  def configure(_options) do
    :ok
  end

  def analyze(contract_module) do
    # Try to load the module directly - compilation should already be done at build time
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

      callbacks
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
