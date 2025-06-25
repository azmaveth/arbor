defmodule Arbor.Credo.Check.BehaviorLocationCheck do
  @moduledoc """
  Ensures that behavior definitions (@callback) only exist in arbor_contracts.

  This check enforces Arbor's architectural principle that all contracts
  (including behavior definitions) must be defined in the arbor_contracts
  application. This ensures:

  - Clear separation of contracts from implementations
  - No circular dependencies
  - Single source of truth for all interfaces
  - Easy discovery of all system contracts

  ## What This Catches

  - @callback definitions outside of arbor_contracts
  - @macrocallback definitions outside of arbor_contracts
  - @optional_callbacks definitions outside of arbor_contracts

  ## Configuration

      {Arbor.Credo.Check.BehaviorLocationCheck, [
        allowed_paths: ["apps/arbor_contracts/lib/"]
      ]}
  """

  @explanation [
    check: @moduledoc,
    params: [
      allowed_paths: "List of paths where behavior definitions are allowed"
    ]
  ]
  
  @default_params [
    allowed_paths: ["apps/arbor_contracts/lib/"]
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
    allowed_paths = Credo.Check.Params.get(params, :allowed_paths, @default_params)
    
    # Check if this file is in an allowed location
    if file_in_allowed_path?(source_file.filename, allowed_paths) do
      []  # File is in allowed location, no issues
    else
      # Look for behavior definitions in non-allowed locations
      ast = SourceFile.ast(source_file)
      
      ast
      |> find_behavior_definitions()
      |> Enum.map(&issue_for_misplaced_behavior(&1, issue_meta, source_file.filename))
    end
  end

  defp file_in_allowed_path?(filename, allowed_paths) do
    Enum.any?(allowed_paths, &String.contains?(filename, &1))
  end

  defp find_behavior_definitions(ast) do
    ast
    |> Macro.postwalk([], fn
      # Find @callback definitions
      {:@, meta, [{:callback, _, [spec]}]} = node, acc ->
        callback_info = extract_callback_info(spec, meta[:line])
        {node, [callback_info | acc]}
      
      # Find @macrocallback definitions
      {:@, meta, [{:macrocallback, _, [spec]}]} = node, acc ->
        callback_info = extract_callback_info(spec, meta[:line])
        {node, [{:macrocallback, callback_info} | acc]}
      
      # Find @optional_callbacks definitions
      {:@, meta, [{:optional_callbacks, _, [callbacks]}]} = node, acc ->
        {node, [{:optional_callbacks, callbacks, meta[:line]} | acc]}
      
      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp extract_callback_info({:"::", _, [{function_spec, _, _} | _]}, line) do
    {extract_function_name(function_spec), line}
  end
  defp extract_callback_info(_spec, line) do
    {:unknown_callback, line}
  end

  defp extract_function_name({name, _, args}) when is_atom(name) and is_list(args) do
    "#{name}/#{length(args)}"
  end
  defp extract_function_name(name) when is_atom(name) do
    to_string(name)
  end
  defp extract_function_name(_) do
    "unknown_function"
  end

  defp issue_for_misplaced_behavior({:macrocallback, {name, line}}, issue_meta, filename) do
    format_issue(
      issue_meta,
      message: "Macro callback #{name} should be defined in arbor_contracts, not in #{Path.relative_to_cwd(filename)}",
      line_no: line,
      trigger: "@macrocallback"
    )
  end
  
  defp issue_for_misplaced_behavior({:optional_callbacks, _callbacks, line}, issue_meta, filename) do
    format_issue(
      issue_meta,
      message: "Optional callbacks should be defined in arbor_contracts, not in #{Path.relative_to_cwd(filename)}",
      line_no: line,
      trigger: "@optional_callbacks"
    )
  end
  
  defp issue_for_misplaced_behavior({name, line}, issue_meta, filename) do
    format_issue(
      issue_meta,
      message: "Callback #{name} should be defined in arbor_contracts, not in #{Path.relative_to_cwd(filename)}",
      line_no: line,
      trigger: "@callback"
    )
  end
end