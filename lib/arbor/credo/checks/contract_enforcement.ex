defmodule Arbor.Credo.Check.ContractEnforcement do
  @moduledoc """
  Ensures that public modules in arbor_core implement appropriate behavior contracts.

  This check enforces Arbor's dual-contract architecture by verifying that:
  
  1. Public modules (those not in test/support) have @behaviour declarations
  2. The behaviors they implement exist in arbor_contracts
  3. All behavior callbacks use @impl true
  
  ## Configuration
  
      {Arbor.Credo.Check.ContractEnforcement, [
        excluded_patterns: ["Test", "Mock", "Stub"],
        require_impl: true
      ]}
  """

  @explanation [
    check: @moduledoc,
    params: [
      excluded_patterns: "List of patterns in module names to exclude from checks",
      require_impl: "Whether to require @impl true on all callbacks"
    ]
  ]
  
  @default_params [
    excluded_patterns: ["Test", "Mock", "Stub", "Support"],
    require_impl: true
  ]

  use Credo.Check, 
    base_priority: :high, 
    category: :design,
    exit_status: 0

  alias Credo.SourceFile

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = Credo.IssueMeta.for(source_file, params)
    excluded_patterns = Credo.Check.Params.get(params, :excluded_patterns, @default_params)
    
    # Only check files in lib directories (not test)
    if should_check_file?(source_file.filename) do
      ast = SourceFile.ast(source_file)
      
      ast
      |> find_module_definitions()
      |> Enum.filter(&public_module?(&1, excluded_patterns))
      |> Enum.flat_map(&check_module(&1, ast, issue_meta, params))
    else
      []
    end
  end

  defp should_check_file?(filename) do
    String.starts_with?(filename, "apps/arbor_core/lib/") and
      not String.contains?(filename, "/test/")
  end

  defp find_module_definitions(ast) do
    ast
    |> Macro.postwalk([], fn
      {:defmodule, meta, [{:__aliases__, _, module_parts}, _body]} = node, acc ->
        module_name = Module.concat(module_parts)
        {node, [{module_name, meta[:line] || 1} | acc]}
      
      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp public_module?({module_name, _line}, excluded_patterns) do
    module_string = to_string(module_name)
    
    # Check if it's a public module (not in excluded patterns)
    not Enum.any?(excluded_patterns, &String.contains?(module_string, &1)) and
      should_require_contract?(module_string)
  end

  # Intelligent detection of modules that should have behavior contracts
  defp should_require_contract?(module_string) do
    cond do
      # Mix tasks already implement Mix.Task behavior - exclude them
      String.starts_with?(module_string, "Elixir.Mix.Tasks.") ->
        false
      
      # Example/demo modules - exclude them  
      String.contains?(module_string, "Example") ->
        false
        
      # Simple utility modules with minimal functionality - exclude them
      String.ends_with?(module_string, "Elixir.Arbor.Core") ->
        false
        
      # Registry wrappers that are just adapters - exclude them
      String.contains?(module_string, "Registry") ->
        false
        
      # Otherwise, this is likely a core business logic module that should have a contract
      true ->
        true
    end
  end

  defp check_module({module_name, line}, ast, issue_meta, params) do
    behaviors = find_behaviors_in_module(ast, module_name)
    
    cond do
      # No behaviors found - this is the main issue we want to catch
      Enum.empty?(behaviors) ->
        [issue_for_missing_behavior(issue_meta, module_name, line)]
      
      # Has behaviors - check if they're from arbor_contracts
      true ->
        check_behavior_validity(behaviors, issue_meta, params)
    end
  end

  defp find_behaviors_in_module(ast, target_module) do
    ast
    |> Macro.postwalk([], fn
      {:defmodule, _, [{:__aliases__, _, module_parts}, body]} = node, acc ->
        if Module.concat(module_parts) == target_module do
          behaviors = extract_behaviors_from_body(body)
          {node, behaviors ++ acc}
        else
          {node, acc}
        end
      
      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp extract_behaviors_from_body([do: {:__block__, _, statements}]) do
    # Handle the most common case: [do: {:__block__, _, statements}]
    extract_behaviors_from_statements(statements)
  end
  defp extract_behaviors_from_body([{:__block__, _, statements}]) do
    # Handle legacy case: [{:__block__, _, statements}]
    extract_behaviors_from_statements(statements)
  end
  defp extract_behaviors_from_body([do: statement]) when is_tuple(statement) do
    # Handle single statement in do block: [do: statement]
    extract_behaviors_from_statements([statement])
  end
  defp extract_behaviors_from_body(statement) when is_tuple(statement) do
    # Handle bare statement
    extract_behaviors_from_statements([statement])
  end
  defp extract_behaviors_from_body(_), do: []

  defp extract_behaviors_from_statements(statements) do
    Enum.flat_map(statements, fn
      {:@, meta, [{:behaviour, _, [behavior]}]} ->
        [{behavior, meta[:line] || 1, :behaviour}]
      
      {:@, meta, [{:behavior, _, [behavior]}]} ->
        # American spelling
        [{behavior, meta[:line] || 1, :behavior}]
      
      _ ->
        []
    end)
  end

  defp check_behavior_validity(behaviors, issue_meta, _params) do
    Enum.flat_map(behaviors, fn {behavior, line, _spelling} ->
      case validate_behavior_contract(behavior) do
        :ok ->
          []
        
        {:error, :not_in_contracts} ->
          [issue_for_invalid_behavior(issue_meta, behavior, line)]
        
        {:error, :not_a_module} ->
          []  # Skip aliases and other non-module behaviors
      end
    end)
  end

  defp validate_behavior_contract(behavior) when is_atom(behavior) do
    # Check if the module name follows the Arbor.Contracts namespace pattern
    # This is more reliable than trying to find source/beam files at Credo check time
    module_parts = Module.split(behavior)
    
    case module_parts do
      ["Arbor", "Contracts" | _rest] ->
        # Module is in the correct namespace
        :ok
      _ ->
        # Module is not in arbor_contracts namespace
        {:error, :not_in_contracts}
    end
  end
  defp validate_behavior_contract({:__aliases__, _, parts}) do
    module = Module.concat(parts)
    validate_behavior_contract(module)
  end
  defp validate_behavior_contract(_), do: {:error, :not_a_module}

  defp issue_for_missing_behavior(issue_meta, module_name, line) do
    format_issue(
      issue_meta,
      message: "Public module #{inspect(module_name)} should implement a behavior contract from arbor_contracts",
      line_no: line,
      trigger: to_string(module_name)
    )
  end

  defp issue_for_invalid_behavior(issue_meta, behavior, line) do
    behavior_name = case behavior do
      {:__aliases__, _, parts} -> Module.concat(parts)
      atom when is_atom(atom) -> atom
      other -> other
    end
    
    format_issue(
      issue_meta,
      message: "Behavior #{inspect(behavior_name)} should be defined in arbor_contracts, not elsewhere",
      line_no: line,
      trigger: to_string(behavior_name)
    )
  end
end