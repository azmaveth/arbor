defmodule Arbor.Credo.Check.ImplTrueEnforcement do
  @moduledoc """
  Ensures that all behavior callbacks use @impl true annotation.

  This check enforces best practices for behavior implementations by requiring
  explicit @impl true annotations on all callback functions. This makes it
  clear which functions are implementing a behavior contract and helps catch
  typos or signature mismatches at compile time.

  ## Benefits

  - Makes behavior implementations explicit and searchable
  - Catches callback signature mismatches at compile time
  - Improves code documentation and readability
  - Aligns with Elixir community best practices

  ## Configuration

      {Arbor.Credo.Check.ImplTrueEnforcement, [
        strict: true
      ]}
  """

  @explanation [
    check: @moduledoc,
    params: [
      strict: "Whether to require @impl true (not just @impl)"
    ]
  ]
  
  @default_params [
    strict: true
  ]

  use Credo.Check, 
    base_priority: :normal, 
    category: :readability,
    exit_status: 0

  alias Credo.SourceFile

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = Credo.IssueMeta.for(source_file, params)
    strict = Credo.Check.Params.get(params, :strict, @default_params)
    
    # Only check files that have @behaviour declarations
    ast = SourceFile.ast(source_file)
    
    if has_behaviour?(ast) do
      ast
      |> find_callback_implementations(strict)
      |> Enum.map(&issue_for_missing_impl(&1, issue_meta))
    else
      []
    end
  end

  defp has_behaviour?(ast) do
    ast
    |> Macro.postwalk(false, fn
      {:@, _, [{behaviour, _, _}]} = node, _acc 
          when behaviour in [:behaviour, :behavior] ->
        {node, true}
      
      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp find_callback_implementations(ast, strict) do
    ast
    |> Macro.postwalk({[], nil, []}, fn
      # Track when we see @behaviour
      {:@, _, [{behaviour, _, [module]}]} = node, {issues, _current_impl, behaviors} 
          when behaviour in [:behaviour, :behavior] ->
        {node, {issues, nil, [module | behaviors]}}
      
      # Track @impl annotations
      {:@, _, [{:impl, _, impl_value}]} = node, {issues, _current_impl, behaviors} ->
        impl_val = parse_impl_value(impl_value, strict)
        {node, {issues, impl_val, behaviors}}
      
      # Check function definitions
      {def_type, meta, [{name, _, args} | _]} = node, {issues, current_impl, behaviors} 
          when def_type in [:def, :defp] and is_list(args) ->
        
        if not Enum.empty?(behaviors) and is_callback?(name, length(args)) and not valid_impl?(current_impl) do
          issue = {name, meta[:line] || 1, length(args)}
          {node, {[issue | issues], nil, behaviors}}
        else
          {node, {issues, nil, behaviors}}
        end
      
      # Reset impl after each function
      {def_type, _, _} = node, {issues, _current_impl, behaviors} 
          when def_type in [:def, :defp] ->
        {node, {issues, nil, behaviors}}
      
      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> elem(0)
    |> Enum.reverse()
  end

  defp parse_impl_value([value], strict) do
    parse_impl_value(value, strict)
  end
  defp parse_impl_value(true, _strict), do: :valid
  defp parse_impl_value(false, _strict), do: :disabled
  defp parse_impl_value(module, false) when is_atom(module), do: :valid
  defp parse_impl_value({:__aliases__, _, _}, false), do: :valid
  defp parse_impl_value(_, true), do: :invalid
  defp parse_impl_value(_, false), do: :valid

  defp valid_impl?(:valid), do: true
  defp valid_impl?(_), do: false

  # Common callback names - in a real implementation, we'd look these up
  # from the actual behavior module
  @known_callbacks ~w(
    init handle_call handle_cast handle_info terminate code_change
    handle_event handle_sync_event handle_continue
    start_link child_spec
    run call cast
    handle_message handle_command handle_query
  )a

  defp is_callback?(name, _arity) do
    name in @known_callbacks or
      String.starts_with?(to_string(name), "handle_") or
      String.ends_with?(to_string(name), "_callback")
  end

  defp issue_for_missing_impl({function_name, line, arity}, issue_meta) do
    format_issue(
      issue_meta,
      message: "Callback function #{function_name}/#{arity} should be marked with @impl true",
      line_no: line,
      trigger: to_string(function_name)
    )
  end
end