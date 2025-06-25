defmodule Mix.Tasks.Credo.Refactor do
  @moduledoc """
  Provides tools to analyze and refactor common Credo architectural issues in Arbor.

  ## Usage

      # Generate Credo report and analyze
      mix credo.refactor
      
      # Future options (not yet implemented):
      # mix credo.refactor --fix-impls
      # mix credo.refactor --audit-contracts
      # mix credo.refactor --dry-run
  """

  use Mix.Task
  require Logger

  @shortdoc "Analyzes and helps refactor Credo architectural issues"

  # Define constants for our target checks
  @impl_true_check "Arbor.Credo.Check.ImplTrueEnforcement"
  @contract_check "Arbor.Credo.Check.ContractEnforcement"
  @location_check "Arbor.Credo.Check.BehaviorLocationCheck"

  @impl Mix.Task
  def run(args) do
    {opts, _parsed_args, _invalid} =
      OptionParser.parse(
        args,
        strict: [
          fix_impls: :boolean,
          dry_run: :boolean,
          extract_callbacks: :boolean,
          generate_contracts: :boolean,
          migrate_implementations: :boolean,
          fix_behaviours: :boolean
        ],
        aliases: [
          f: :fix_impls,
          d: :dry_run,
          e: :extract_callbacks,
          g: :generate_contracts,
          m: :migrate_implementations,
          b: :fix_behaviours
        ]
      )

    Mix.shell().info("Running Credo to generate issue report...")

    case execute_credo() do
      {:ok, issues} ->
        cond do
          opts[:fix_behaviours] ->
            fix_misplaced_behaviour_declarations(issues, opts)

          opts[:migrate_implementations] ->
            migrate_implementations_from_analysis(issues, opts)

          opts[:generate_contracts] ->
            generate_contracts_from_analysis(issues, opts)

          opts[:extract_callbacks] ->
            extract_callbacks_from_modules(issues, opts)

          opts[:fix_impls] ->
            fix_impl_true_issues(issues, opts)

          true ->
            analyze_issues(issues)
        end

      {:error, reason} ->
        Logger.error(reason)
        System.halt(1)
    end
  end

  defp execute_credo do
    # We run credo and pipe stderr to stdout to capture all output.
    case System.cmd("mix", ["credo", "--format=json", "--all-priorities"], stderr_to_stdout: true) do
      {output, _exit_code} ->
        # We ignore the exit code. Credo returns non-zero when issues are found.
        # Our success condition is whether we can find a JSON object in the output.
        # This regex robustly finds a JSON object even with other text in the output.
        case Regex.run(~r/({.*})/s, output) do
          [json_string | _] ->
            {:ok, Jason.decode!(json_string)["issues"]}

          nil ->
            {:error,
             """
             Could not find a valid JSON object in Credo's output.
             This indicates a failure in the Credo command itself.
             Output received:
             #{output}
             """}
        end
    end
  end

  defp analyze_issues(issues) do
    grouped_by_check = Enum.group_by(issues, & &1["check"])

    # Extract issues based on the custom check names
    impl_true_issues = grouped_by_check[@impl_true_check] || []
    contract_issues = grouped_by_check[@contract_check] || []
    location_issues = grouped_by_check[@location_check] || []

    total_issues = Enum.count(issues)
    impl_count = Enum.count(impl_true_issues)
    contract_count = Enum.count(contract_issues)
    location_count = Enum.count(location_issues)
    other_count = total_issues - impl_count - contract_count - location_count

    # Group contract issues by module
    modules_missing_contracts =
      contract_issues
      |> Enum.map(& &1["scope"])
      |> Enum.uniq()
      |> Enum.sort()

    # Group impl issues by file
    files_missing_impl =
      impl_true_issues
      |> Enum.group_by(& &1["filename"])
      |> Enum.map(fn {file, issues} -> {file, length(issues)} end)
      |> Enum.sort_by(fn {_, count} -> -count end)

    # Group behavior location issues by file
    misplaced_behaviors =
      location_issues
      |> Enum.group_by(& &1["filename"])
      |> Enum.map(fn {file, issues} -> {file, length(issues)} end)
      |> Enum.sort()

    Mix.shell().info("""

    =====================================
    Arbor Credo Architecture Analysis
    =====================================

    Total Issues: #{total_issues}

    Actionable Issues Breakdown:
    - `#{@impl_true_check}`: #{impl_count}
    - `#{@contract_check}`: #{contract_count}
    - `#{@location_check}`: #{location_count}

    Other Credo Issues: #{other_count}

    -------------------------------------
    MODULES NEEDING CONTRACTS (#{contract_count})
    -------------------------------------
    """)

    Enum.each(modules_missing_contracts, fn module ->
      Mix.shell().info("  • #{module}")
    end)

    Mix.shell().info("""

    -------------------------------------
    FILES WITH MISSING @impl true (Top 10)
    -------------------------------------
    """)

    files_missing_impl
    |> Enum.take(10)
    |> Enum.each(fn {file, count} ->
      short_file = String.replace(file, ~r/^apps\//, "")
      Mix.shell().info("  • #{short_file}: #{count} instances")
    end)

    if length(files_missing_impl) > 10 do
      Mix.shell().info("  ... and #{length(files_missing_impl) - 10} more files")
    end

    Mix.shell().info("""

    -------------------------------------
    FILES WITH MISPLACED BEHAVIORS (#{length(misplaced_behaviors)})
    -------------------------------------
    """)

    Enum.each(misplaced_behaviors, fn {file, count} ->
      short_file = String.replace(file, ~r/^apps\//, "")
      Mix.shell().info("  • #{short_file}: #{count} @callback definitions")
    end)

    Mix.shell().info("""

    =====================================
    RECOMMENDED ACTION PLAN
    =====================================

    1. Create #{contract_count} behavior contracts in arbor_contracts
    2. Move #{location_count} @callback definitions to contracts  
    3. Add #{impl_count} @impl true annotations

    Next steps:
    - Run 'mix credo.refactor --audit-contracts' to preview contract creation
    - Run 'mix credo.refactor --fix-impls' to add @impl annotations
    """)

    # Save detailed report for other tools
    save_detailed_report(issues)
  end

  defp save_detailed_report(issues) do
    report = %{
      timestamp: DateTime.utc_now(),
      summary: %{
        total_issues: length(issues),
        by_check: Enum.frequencies_by(issues, & &1["check"])
      },
      issues: issues
    }

    case Jason.encode(report, pretty: true) do
      {:ok, json} ->
        File.write!("credo_analysis.json", json)
        Mix.shell().info("\nDetailed report saved to: credo_analysis.json")

      {:error, _} ->
        Logger.warning("Could not save detailed report")
    end
  end

  defp fix_impl_true_issues(issues, opts) do
    dry_run? = opts[:dry_run] || false
    impl_issues = Enum.filter(issues, &(&1["check"] == @impl_true_check))

    if Enum.empty?(impl_issues) do
      Mix.shell().info("No '#{@impl_true_check}' issues found to fix.")
      :ok
    else
      total_to_fix = Enum.count(impl_issues)
      plural = if total_to_fix > 1, do: "s", else: ""
      mode_info = if dry_run?, do: "[DRY RUN] ", else: ""

      Mix.shell().info(
        "#{mode_info}Found #{total_to_fix} missing @impl true issue#{plural} to fix."
      )

      impl_issues
      |> Enum.group_by(& &1["filename"])
      |> Enum.each(fn {filename, file_issues} ->
        process_file_for_impl_fix(filename, file_issues, dry_run?)
      end)

      if dry_run? do
        Mix.shell().info(
          IO.ANSI.yellow() <> "\nDry run complete. No files were modified." <> IO.ANSI.reset()
        )
      else
        Mix.shell().info(
          IO.ANSI.green() <>
            "\nFixes applied. Please review the changes and run tests." <> IO.ANSI.reset()
        )
      end
    end
  end

  defp process_file_for_impl_fix(filename, file_issues, dry_run?) do
    if dry_run? do
      Mix.shell().info(
        "\n" <> IO.ANSI.yellow() <> "Proposed changes for #{filename}:" <> IO.ANSI.reset()
      )

      # Show a diff-like preview instead of full file
      changes_summary =
        file_issues
        |> Enum.map(fn issue ->
          "  Line #{issue["line_no"]}: Add @impl true before #{issue["trigger"]}"
        end)
        |> Enum.join("\n")

      Mix.shell().info(changes_summary)
    else
      # Use string-based replacement as fallback to AST transformation
      source_code = File.read!(filename)
      new_code = add_impl_annotations_string_based(source_code, file_issues)

      if new_code != source_code do
        File.write!(filename, new_code)
        Mix.shell().info(IO.ANSI.green() <> "Fixed: " <> IO.ANSI.reset() <> filename)

        # Run mix format on the file to ensure proper formatting
        System.cmd("mix", ["format", filename], stderr_to_stdout: true)
      else
        Mix.shell().info("No changes needed for: #{filename}")
      end
    end
  end

  # String-based approach to add @impl true annotations
  defp add_impl_annotations_string_based(source_code, file_issues) do
    lines = String.split(source_code, "\n")

    # Create a map of line numbers to function names for quick lookup
    line_to_function =
      file_issues
      |> Enum.map(fn issue -> {issue["line_no"], issue["trigger"]} end)
      |> Map.new()

    # Process each line and add @impl true where needed
    {new_lines, _} =
      lines
      |> Enum.with_index(1)
      |> Enum.map_reduce(false, fn {line, line_num}, prev_was_impl ->
        function_name = Map.get(line_to_function, line_num)

        cond do
          # This line has a function that needs @impl true
          function_name && !prev_was_impl ->
            # Get the indentation from the current line
            indentation = get_line_indentation(line)
            impl_line = indentation <> "@impl true"
            {[impl_line, line], false}

          # This line has @impl ModuleName - replace with @impl true
          function_name && prev_was_impl ->
            # The function needs @impl true, but the previous line already has @impl
            # We'll keep the line as-is since prev_was_impl means we processed it
            {[line], false}

          # This line is @impl - check if it needs replacement and track it
          String.match?(line, ~r/^\s*@impl\s/) ->
            # Check if the next line needs fixing (look ahead)
            next_line_num = line_num + 1
            needs_strict_impl = Map.has_key?(line_to_function, next_line_num)

            if needs_strict_impl && !String.match?(line, ~r/^\s*@impl\s+true\s*$/) do
              # Replace @impl ModuleName with @impl true
              indentation = get_line_indentation(line)
              new_impl_line = indentation <> "@impl true"
              {[new_impl_line], true}
            else
              {[line], true}
            end

          # Regular line
          true ->
            {[line], false}
        end
      end)

    # Flatten the result and join back into a string
    new_lines
    |> List.flatten()
    |> Enum.join("\n")
  end

  # Extract indentation from a line (spaces and tabs before the first non-whitespace)
  defp get_line_indentation(line) do
    case Regex.run(~r/^(\s*)/, line) do
      [_, indentation] -> indentation
      _ -> ""
    end
  end

  # Domain mapping based on module names and existing contract patterns
  defp get_contract_domain(module_name) do
    cond do
      String.contains?(module_name, "Gateway") ->
        "gateway"

      String.contains?(module_name, "Cluster") ->
        "cluster"

      String.contains?(module_name, "Session") ->
        "session"

      String.contains?(module_name, "Agent") and not String.contains?(module_name, "Arbor.Agents") ->
        "agent"

      String.contains?(module_name, "Arbor.Agents") ->
        "agents"

      String.contains?(module_name, "Horde") ->
        "cluster"

      String.contains?(module_name, "Reconciler") ->
        "agent"

      String.contains?(module_name, "Registry") ->
        "cluster"

      String.contains?(module_name, "Supervisor") ->
        "cluster"

      String.contains?(module_name, "CodeGen") ->
        "codegen"

      String.contains?(module_name, "Mix.Tasks") ->
        "tasks"

      String.contains?(module_name, "TelemetryHelper") ->
        "telemetry"

      String.contains?(module_name, "Application") ->
        "core"

      String.contains?(module_name, "Checkpoint") ->
        "agent"

      true ->
        "core"
    end
  end

  # Extract callbacks from modules that need contracts
  defp extract_callbacks_from_modules(issues, opts) do
    dry_run? = opts[:dry_run] || false

    # Get modules that need contracts
    contract_issues = Enum.filter(issues, &(&1["check"] == @contract_check))
    location_issues = Enum.filter(issues, &(&1["check"] == @location_check))

    if Enum.empty?(contract_issues) and Enum.empty?(location_issues) do
      Mix.shell().info("No modules need contract extraction.")
      :ok
    else
      target_modules =
        contract_issues
        |> Enum.map(& &1["scope"])
        |> Enum.uniq()
        |> Enum.sort()

      misplaced_files =
        location_issues
        |> Enum.map(& &1["filename"])
        |> Enum.uniq()
        |> Enum.sort()

      Mix.shell().info("Extracting callbacks from #{length(target_modules)} modules...")

      Mix.shell().info(
        "Found #{length(location_issues)} misplaced @callback definitions in #{length(misplaced_files)} files..."
      )

      # Extract callbacks from files with misplaced definitions
      extracted_callbacks = extract_callbacks_from_files(misplaced_files)

      # Classify modules by domain for contract generation
      classified_modules = classify_modules_by_domain(target_modules)

      # Generate extraction report
      report = %{
        timestamp: DateTime.utc_now(),
        target_modules: target_modules,
        classified_modules: classified_modules,
        misplaced_callbacks: extracted_callbacks,
        summary: %{
          modules_needing_contracts: length(target_modules),
          misplaced_callback_files: length(misplaced_files),
          total_misplaced_callbacks: length(location_issues)
        }
      }

      save_extraction_report(report, dry_run?)
    end
  end

  # Extract @callback definitions from files
  defp extract_callbacks_from_files(files) do
    files
    |> Enum.map(fn file_path ->
      case File.read(file_path) do
        {:ok, content} ->
          callbacks = extract_callbacks_from_content(content)

          %{
            file: file_path,
            module: extract_module_name_from_content(content),
            callbacks: callbacks
          }

        {:error, _} ->
          %{file: file_path, module: nil, callbacks: []}
      end
    end)
    |> Enum.filter(&(length(&1.callbacks) > 0))
  end

  # Extract @callback definitions using string parsing
  defp extract_callbacks_from_content(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {line, line_num}, acc ->
      case Regex.run(~r/^\s*@callback\s+(.+)$/, line) do
        [_full_match, callback_sig] ->
          [%{line: line_num, signature: String.trim(callback_sig)} | acc]

        nil ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  # Extract module name from file content
  defp extract_module_name_from_content(content) do
    case Regex.run(~r/defmodule\s+([\w\.]+)\s+do/, content) do
      [_full_match, module_name] -> module_name
      nil -> nil
    end
  end

  # Classify modules by their target contract domain
  defp classify_modules_by_domain(modules) do
    modules
    |> Enum.map(fn module ->
      domain = get_contract_domain(module)
      contract_name = generate_contract_name(module, domain)

      %{
        module: module,
        domain: domain,
        contract_name: contract_name,
        contract_path:
          "apps/arbor_contracts/lib/arbor/contracts/#{domain}/#{String.downcase(contract_name)}.ex"
      }
    end)
    |> Enum.group_by(& &1.domain)
  end

  # Generate appropriate contract name based on module name
  defp generate_contract_name(module_name, domain) do
    # Remove Arbor.Core prefix and domain-specific prefixes
    clean_name =
      module_name
      |> String.replace("Arbor.Core.", "")
      |> String.replace("Arbor.Agents.", "")
      |> String.replace("Arbor.", "")
      |> String.replace("Mix.Tasks.", "")

    # Convert to contract-style name
    case domain do
      "cluster" ->
        cond do
          String.contains?(clean_name, "Horde") -> String.replace(clean_name, "Horde", "")
          String.contains?(clean_name, "Cluster") -> String.replace(clean_name, "Cluster", "")
          true -> clean_name
        end

      "agent" ->
        String.replace(clean_name, "Agent", "")

      "session" ->
        String.replace(clean_name, "Sessions.", "")

      _ ->
        clean_name
    end
  end

  # Save extraction report
  defp save_extraction_report(report, dry_run?) do
    mode_info = if dry_run?, do: "[DRY RUN] ", else: ""

    Mix.shell().info("\n#{mode_info}Contract Extraction Report")
    Mix.shell().info("=" <> String.duplicate("=", 40))

    Mix.shell().info("Target Modules: #{report.summary.modules_needing_contracts}")
    Mix.shell().info("Misplaced Callback Files: #{report.summary.misplaced_callback_files}")
    Mix.shell().info("Total Misplaced Callbacks: #{report.summary.total_misplaced_callbacks}")

    Mix.shell().info("\nClassified by Domain:")

    Enum.each(report.classified_modules, fn {domain, modules} ->
      Mix.shell().info("  #{domain}/: #{length(modules)} modules")

      Enum.each(modules, fn mod ->
        Mix.shell().info("    • #{mod.module} -> #{mod.contract_name}")
      end)
    end)

    Mix.shell().info("\nMisplaced Callbacks:")

    Enum.each(report.misplaced_callbacks, fn file_info ->
      Mix.shell().info("  #{file_info.file}: #{length(file_info.callbacks)} callbacks")

      Enum.each(file_info.callbacks, fn cb ->
        Mix.shell().info("    Line #{cb.line}: #{cb.signature}")
      end)
    end)

    # Save detailed JSON report
    case Jason.encode(report, pretty: true) do
      {:ok, json} ->
        File.write!("contract_extraction.json", json)
        Mix.shell().info("\nDetailed report saved to: contract_extraction.json")

      {:error, _} ->
        Logger.warning("Could not save extraction report")
    end
  end

  # Generate contracts from analysis
  defp generate_contracts_from_analysis(issues, opts) do
    dry_run? = opts[:dry_run] || false

    # Get modules that need contracts and misplaced callbacks
    contract_issues = Enum.filter(issues, &(&1["check"] == @contract_check))
    location_issues = Enum.filter(issues, &(&1["check"] == @location_check))

    if Enum.empty?(contract_issues) and Enum.empty?(location_issues) do
      Mix.shell().info("No contracts need to be generated.")
      :ok
    else
      target_modules =
        contract_issues
        |> Enum.map(& &1["scope"])
        |> Enum.uniq()
        |> Enum.sort()

      misplaced_files =
        location_issues
        |> Enum.map(& &1["filename"])
        |> Enum.uniq()
        |> Enum.sort()

      Mix.shell().info("Generating contracts for #{length(target_modules)} modules...")

      # Extract callbacks from files with misplaced definitions
      extracted_callbacks = extract_callbacks_from_files(misplaced_files)

      # Classify modules by domain for contract generation
      classified_modules = classify_modules_by_domain(target_modules)

      # Generate contracts for each domain
      generation_results =
        generate_contracts_by_domain(classified_modules, extracted_callbacks, dry_run?)

      # Generate summary report
      report_contract_generation(
        generation_results,
        target_modules,
        extracted_callbacks,
        dry_run?
      )
    end
  end

  # Generate contracts grouped by domain
  defp generate_contracts_by_domain(classified_modules, extracted_callbacks, dry_run?) do
    classified_modules
    |> Enum.map(fn {domain, modules} ->
      Mix.shell().info("Generating #{length(modules)} contracts in #{domain}/ domain...")

      domain_results =
        modules
        |> Enum.map(fn mod_info ->
          generate_single_contract(mod_info, extracted_callbacks, dry_run?)
        end)

      {domain, domain_results}
    end)
    |> Map.new()
  end

  # Generate a single contract file
  defp generate_single_contract(mod_info, extracted_callbacks, dry_run?) do
    %{
      module: module_name,
      contract_name: contract_name,
      contract_path: contract_path,
      domain: domain
    } = mod_info

    # Find any extracted callbacks for this module
    module_callbacks = find_callbacks_for_module(module_name, extracted_callbacks)

    # Generate contract content using template
    contract_content =
      generate_contract_template(contract_name, domain, module_name, module_callbacks)

    result =
      if dry_run? do
        Mix.shell().info("  [DRY RUN] Would create: #{contract_path}")
        {:dry_run, contract_path}
      else
        # Ensure directory exists
        Path.dirname(contract_path) |> File.mkdir_p!()

        case File.write(contract_path, contract_content) do
          :ok ->
            Mix.shell().info("  ✓ Created: #{contract_path}")
            {:created, contract_path}

          {:error, reason} ->
            Mix.shell().error("  ✗ Failed to create #{contract_path}: #{reason}")
            {:error, contract_path, reason}
        end
      end

    %{
      module: module_name,
      contract_name: contract_name,
      contract_path: contract_path,
      result: result,
      callbacks_found: length(module_callbacks)
    }
  end

  # Find callbacks that belong to a specific module
  defp find_callbacks_for_module(module_name, extracted_callbacks) do
    extracted_callbacks
    |> Enum.filter(&(&1.module == module_name))
    |> Enum.flat_map(& &1.callbacks)
  end

  # Generate contract content using template
  defp generate_contract_template(contract_name, domain, original_module, callbacks) do
    # Convert contract name to proper module format
    contract_module = "Arbor.Contracts.#{String.capitalize(domain)}.#{contract_name}"

    # Generate @callback definitions from extracted callbacks
    callback_defs =
      if Enum.empty?(callbacks) do
        generate_placeholder_callbacks(domain, original_module)
      else
        callbacks
        |> Enum.map(fn cb -> "  @callback #{cb.signature}" end)
        |> Enum.join("\n")
      end

    # Use the domain-specific template
    case domain do
      "gateway" ->
        generate_gateway_contract_template(
          contract_module,
          contract_name,
          original_module,
          callback_defs
        )

      _ ->
        generate_simple_contract_template(
          contract_module,
          contract_name,
          domain,
          original_module,
          callback_defs
        )
    end
  end

  # Generate placeholder callbacks when none are extracted
  defp generate_placeholder_callbacks(domain, _original_module) do
    case domain do
      "gateway" ->
        "  @callback handle_request(request :: any(), context :: map()) ::\n" <>
          "              {:ok, response :: any()} | {:error, reason :: term()}\n" <>
          "\n" <>
          "  @callback validate_request(request :: any()) :: :ok | {:error, term()}"

      "cluster" ->
        "  @callback start_service(config :: map()) :: {:ok, pid()} | {:error, term()}\n" <>
          "\n" <>
          "  @callback stop_service(reason :: term()) :: :ok\n" <>
          "\n" <>
          "  @callback get_status() :: {:ok, map()} | {:error, term()}"

      "session" ->
        "  @callback create_session(params :: map()) :: {:ok, session_id :: binary()} | {:error, term()}\n" <>
          "\n" <>
          "  @callback get_session(session_id :: binary()) :: {:ok, map()} | {:error, term()}\n" <>
          "\n" <>
          "  @callback terminate_session(session_id :: binary()) :: :ok | {:error, term()}"

      "agent" ->
        "  @callback execute_task(task :: any()) :: {:ok, result :: any()} | {:error, term()}\n" <>
          "\n" <>
          "  @callback get_state() :: {:ok, state :: any()} | {:error, term()}"

      _ ->
        "  @callback process(input :: any()) :: {:ok, output :: any()} | {:error, term()}\n" <>
          "\n" <>
          "  @callback configure(options :: keyword()) :: :ok | {:error, term()}"
    end
  end

  # Gateway-specific contract template  
  defp generate_gateway_contract_template(
         contract_module,
         contract_name,
         _original_module,
         callback_defs
       ) do
    "defmodule #{contract_module} do\n" <>
      "  @moduledoc \"\"\"\n" <>
      "  Contract for #{String.downcase(contract_name)} gateway operations.\n" <>
      "\n" <>
      "  This contract defines the interface for gateway components that handle\n" <>
      "  client requests, command processing, and response management.\n" <>
      "\n" <>
      "  ## Responsibilities\n" <>
      "\n" <>
      "  - Request validation and processing\n" <>
      "  - Client authentication and authorization\n" <>
      "  - Command routing and execution\n" <>
      "  - Response formatting and delivery\n" <>
      "  - Error handling and recovery\n" <>
      "\n" <>
      "  @version \"1.0.0\"\n" <>
      "  \"\"\"\n" <>
      "\n" <>
      "  alias Arbor.Types\n" <>
      "\n" <>
      "  @type request :: map()\n" <>
      "  @type context :: map()\n" <>
      "  @type response :: map()\n" <>
      "\n" <>
      "#{callback_defs}\n" <>
      "end\n"
  end

  # Simplified contract template
  defp generate_simple_contract_template(
         contract_module,
         contract_name,
         domain,
         original_module,
         callback_defs
       ) do
    "defmodule #{contract_module} do\n" <>
      "  @moduledoc \"\"\"\n" <>
      "  Contract for #{String.downcase(contract_name)} #{domain} operations.\n" <>
      "\n" <>
      "  This contract defines the interface for #{domain} components in the Arbor system.\n" <>
      "  Original implementation: #{original_module}\n" <>
      "\n" <>
      "  ## Responsibilities\n" <>
      "\n" <>
      "  - Define the core interface for #{domain} operations\n" <>
      "  - Ensure consistent behavior across implementations\n" <>
      "  - Provide clear contracts for testing and mocking\n" <>
      "  - Enable dependency injection and modularity\n" <>
      "\n" <>
      "  @version \"1.0.0\"\n" <>
      "  \"\"\"\n" <>
      "\n" <>
      "  alias Arbor.Types\n" <>
      "\n" <>
      "#{callback_defs}\n" <>
      "end\n"
  end

  # Generate final report for contract generation
  defp report_contract_generation(
         generation_results,
         target_modules,
         extracted_callbacks,
         dry_run?
       ) do
    mode_info = if dry_run?, do: "[DRY RUN] ", else: ""

    total_contracts =
      Enum.sum(Enum.map(generation_results, fn {_domain, results} -> length(results) end))

    successful = count_successful_generations(generation_results)
    failed = total_contracts - successful

    Mix.shell().info("\n#{mode_info}Contract Generation Report")
    Mix.shell().info("=" <> String.duplicate("=", 50))

    Mix.shell().info("Target Modules: #{length(target_modules)}")
    Mix.shell().info("Contracts Generated: #{successful}/#{total_contracts}")

    if failed > 0 do
      Mix.shell().info("Failed Generations: #{failed}")
    end

    Mix.shell().info("\nGenerated by Domain:")

    Enum.each(generation_results, fn {domain, results} ->
      domain_successful = Enum.count(results, &match?(%{result: {:created, _}}, &1))
      Mix.shell().info("  #{domain}/: #{domain_successful}/#{length(results)} contracts")

      Enum.each(results, fn result ->
        case result.result do
          {:created, _path} ->
            Mix.shell().info(
              "    ✓ #{result.contract_name} (#{result.callbacks_found} callbacks)"
            )

          {:dry_run, _path} ->
            Mix.shell().info(
              "    → #{result.contract_name} (#{result.callbacks_found} callbacks)"
            )

          {:error, _path, reason} ->
            Mix.shell().info("    ✗ #{result.contract_name} - #{reason}")
        end
      end)
    end)

    if !dry_run? and successful > 0 do
      Mix.shell().info("\nNext Steps:")

      Mix.shell().info(
        "1. Review generated contracts in apps/arbor_contracts/lib/arbor/contracts/"
      )

      Mix.shell().info("2. Add @behaviour declarations to implementation modules")
      Mix.shell().info("3. Remove @callback definitions from implementation files")
      Mix.shell().info("4. Run 'mix credo.refactor' to validate contract compliance")
    end

    # Save detailed generation report
    save_generation_report(generation_results, target_modules, extracted_callbacks, dry_run?)
  end

  # Count successful contract generations
  defp count_successful_generations(generation_results) do
    generation_results
    |> Enum.flat_map(fn {_domain, results} -> results end)
    |> Enum.count(&match?(%{result: {:created, _}}, &1))
  end

  # Save detailed generation report to JSON
  defp save_generation_report(generation_results, target_modules, extracted_callbacks, dry_run?) do
    report = %{
      timestamp: DateTime.utc_now(),
      mode: if(dry_run?, do: "dry_run", else: "execution"),
      summary: %{
        target_modules: length(target_modules),
        total_contracts:
          Enum.sum(Enum.map(generation_results, fn {_domain, results} -> length(results) end)),
        successful_generations: count_successful_generations(generation_results),
        extracted_callbacks: Enum.sum(Enum.map(extracted_callbacks, &length(&1.callbacks)))
      },
      generation_results: generation_results,
      extracted_callbacks: extracted_callbacks
    }

    filename =
      if dry_run?, do: "contract_generation_preview.json", else: "contract_generation.json"

    case Jason.encode(report, pretty: true) do
      {:ok, json} ->
        File.write!(filename, json)
        Mix.shell().info("\nDetailed report saved to: #{filename}")

      {:error, _} ->
        Logger.warning("Could not save generation report")
    end
  end

  # Migrate implementations to use contracts
  defp migrate_implementations_from_analysis(issues, opts) do
    dry_run? = opts[:dry_run] || false

    # Get modules that need @behaviour declarations and misplaced callbacks
    contract_issues = Enum.filter(issues, &(&1["check"] == @contract_check))
    location_issues = Enum.filter(issues, &(&1["check"] == @location_check))

    if Enum.empty?(contract_issues) and Enum.empty?(location_issues) do
      Mix.shell().info(
        "No implementation migration needed - all modules already use contracts properly."
      )

      :ok
    else
      target_modules =
        contract_issues
        |> Enum.map(& &1["scope"])
        |> Enum.uniq()
        |> Enum.sort()

      files_with_callbacks =
        location_issues
        |> Enum.map(& &1["filename"])
        |> Enum.uniq()
        |> Enum.sort()

      Mix.shell().info(
        "Migrating #{length(target_modules)} implementation modules to use contracts..."
      )

      Mix.shell().info(
        "Removing misplaced @callback definitions from #{length(files_with_callbacks)} files..."
      )

      # Step 1: Add @behaviour declarations to implementation modules
      behaviour_results = add_behaviour_declarations(target_modules, dry_run?)

      # Step 2: Remove @callback definitions from implementation files
      callback_results = remove_misplaced_callbacks(files_with_callbacks, dry_run?)

      # Generate migration report
      report_implementation_migration(
        behaviour_results,
        callback_results,
        target_modules,
        files_with_callbacks,
        dry_run?
      )
    end
  end

  # Add @behaviour declarations to implementation modules
  defp add_behaviour_declarations(target_modules, dry_run?) do
    target_modules
    |> Enum.map(fn module_name ->
      # Map module to its contract and file path
      module_info = get_module_file_info(module_name)
      contract_info = get_contract_info_for_module(module_name)

      if module_info && contract_info do
        result = add_behaviour_to_file(module_info, contract_info, dry_run?)

        %{
          module: module_name,
          file_path: module_info.file_path,
          contract: contract_info.contract_module,
          result: result
        }
      else
        %{
          module: module_name,
          file_path: nil,
          contract: nil,
          result: {:error, "Could not locate module file or determine contract"}
        }
      end
    end)
  end

  # Remove @callback definitions from files
  defp remove_misplaced_callbacks(files_with_callbacks, dry_run?) do
    files_with_callbacks
    |> Enum.map(fn file_path ->
      case File.read(file_path) do
        {:ok, content} ->
          callbacks = extract_callbacks_from_content(content)
          result = remove_callbacks_from_file(file_path, content, callbacks, dry_run?)

          %{
            file: file_path,
            callbacks_removed: length(callbacks),
            result: result
          }

        {:error, reason} ->
          %{
            file: file_path,
            callbacks_removed: 0,
            result: {:error, "Could not read file: #{reason}"}
          }
      end
    end)
  end

  # Get file path and module info for a module name
  defp get_module_file_info(module_name) do
    # Convert module name to expected file path
    file_path = module_name_to_file_path(module_name)

    if File.exists?(file_path) do
      %{
        module: module_name,
        file_path: file_path
      }
    else
      nil
    end
  end

  # Convert module name to file path
  defp module_name_to_file_path(module_name) do
    parts = String.split(module_name, ".")

    case parts do
      ["Arbor", "Core" | rest] ->
        filename = rest |> Enum.map(&Macro.underscore/1) |> Enum.join("/")
        "apps/arbor_core/lib/arbor/core/#{filename}.ex"

      ["Arbor", "Agents" | rest] ->
        filename = rest |> Enum.map(&Macro.underscore/1) |> Enum.join("/")
        "apps/arbor_core/lib/arbor/agents/#{filename}.ex"

      ["Arbor", "CodeGen" | rest] ->
        filename = rest |> Enum.map(&Macro.underscore/1) |> Enum.join("/")
        "apps/arbor_core/lib/arbor/codegen/#{filename}.ex"

      ["Mix", "Tasks" | rest] ->
        filename = rest |> Enum.map(&Macro.underscore/1) |> Enum.join("/")
        "apps/arbor_core/lib/mix/tasks/#{filename}.ex"

      ["Arbor"] ->
        "apps/arbor_core/lib/arbor/core.ex"

      _ ->
        # Fallback - try to guess based on module structure
        filename = parts |> Enum.drop(1) |> Enum.map(&Macro.underscore/1) |> Enum.join("/")
        "apps/arbor_core/lib/arbor/#{filename}.ex"
    end
  end

  # Get contract information for a module
  defp get_contract_info_for_module(module_name) do
    domain = get_contract_domain(module_name)
    contract_name = generate_contract_name(module_name, domain)
    contract_module = "Arbor.Contracts.#{String.capitalize(domain)}.#{contract_name}"

    %{
      contract_module: contract_module,
      domain: domain,
      contract_name: contract_name
    }
  end

  # Add @behaviour declaration to a file
  defp add_behaviour_to_file(module_info, contract_info, dry_run?) do
    file_path = module_info.file_path

    case File.read(file_path) do
      {:ok, content} ->
        if String.contains?(content, "@behaviour #{contract_info.contract_module}") do
          {:already_present, "Module already has @behaviour declaration"}
        else
          updated_content = inject_behaviour_declaration(content, contract_info.contract_module)

          if dry_run? do
            {:dry_run, "Would add @behaviour #{contract_info.contract_module}"}
          else
            case File.write(file_path, updated_content) do
              :ok ->
                # Run mix format on the file
                System.cmd("mix", ["format", file_path], stderr_to_stdout: true)
                {:added, "Added @behaviour #{contract_info.contract_module}"}

              {:error, reason} ->
                {:error, "Failed to write file: #{reason}"}
            end
          end
        end

      {:error, reason} ->
        {:error, "Could not read file: #{reason}"}
    end
  end

  # Inject @behaviour declaration after the module definition
  defp inject_behaviour_declaration(content, contract_module) do
    lines = String.split(content, "\n")

    # Find the module definition line
    {before_module, module_line, after_module} = find_module_definition(lines)

    if module_line do
      # Find where to insert the @behaviour declaration (after @moduledoc or module line)
      {before_behaviour, after_behaviour} = find_behaviour_insertion_point(after_module)

      behaviour_line = "  @behaviour #{contract_module}"

      updated_lines =
        before_module ++ [module_line] ++ before_behaviour ++ [behaviour_line] ++ after_behaviour

      Enum.join(updated_lines, "\n")
    else
      # Fallback: add at the beginning of the file after the module line
      String.replace(
        content,
        ~r/(defmodule\s+[\w\.]+\s+do)/,
        "\\1\n  @behaviour #{contract_module}"
      )
    end
  end

  # Find module definition line in file
  defp find_module_definition(lines) do
    case Enum.find_index(lines, &String.match?(&1, ~r/^defmodule\s+[\w\.]+\s+do/)) do
      nil ->
        {lines, nil, []}

      index ->
        {before, [module_line | remaining]} = Enum.split(lines, index)
        {before, module_line, remaining}
    end
  end

  # Find the best place to insert @behaviour declaration
  defp find_behaviour_insertion_point(lines_after_module) do
    # Look for @moduledoc and insert after it, or insert at the beginning
    case find_moduledoc_end(lines_after_module) do
      nil ->
        # No @moduledoc found, insert after any initial comments/blank lines
        {skip_initial_lines(lines_after_module), []}

      index ->
        Enum.split(lines_after_module, index + 1)
    end
  end

  # Find the end of @moduledoc block
  defp find_moduledoc_end(lines) do
    find_moduledoc_end(lines, 0, false, false)
  end

  defp find_moduledoc_end([], _index, _in_doc, _found_doc), do: nil

  defp find_moduledoc_end([line | rest], index, in_doc, found_doc) do
    cond do
      !found_doc && String.match?(line, ~r/^\s*@moduledoc/) ->
        if String.contains?(line, "\"\"\"") && String.match?(line, ~r/"""\s*$/) do
          # Single line @moduledoc
          index
        else
          # Multi-line @moduledoc starts
          find_moduledoc_end(rest, index + 1, true, true)
        end

      in_doc && String.match?(line, ~r/^\s*"""/) ->
        # End of multi-line @moduledoc
        index

      in_doc ->
        # Inside @moduledoc, continue
        find_moduledoc_end(rest, index + 1, true, true)

      found_doc ->
        # @moduledoc block ended, this is insertion point
        index - 1

      true ->
        # Continue looking
        find_moduledoc_end(rest, index + 1, false, false)
    end
  end

  # Skip initial blank lines and comments
  defp skip_initial_lines(lines) do
    lines
    |> Enum.drop_while(fn line ->
      String.trim(line) == "" || String.starts_with?(String.trim(line), "#")
    end)
  end

  # Remove @callback definitions from a file
  defp remove_callbacks_from_file(file_path, content, callbacks, dry_run?) do
    if Enum.empty?(callbacks) do
      {:no_callbacks, "No @callback definitions found"}
    else
      updated_content = remove_callback_lines(content, callbacks)

      if dry_run? do
        {:dry_run, "Would remove #{length(callbacks)} @callback definitions"}
      else
        case File.write(file_path, updated_content) do
          :ok ->
            # Run mix format on the file
            System.cmd("mix", ["format", file_path], stderr_to_stdout: true)
            {:removed, "Removed #{length(callbacks)} @callback definitions"}

          {:error, reason} ->
            {:error, "Failed to write file: #{reason}"}
        end
      end
    end
  end

  # Remove callback lines from content
  defp remove_callback_lines(content, callbacks) do
    lines = String.split(content, "\n")
    callback_line_numbers = Enum.map(callbacks, & &1.line)

    lines
    |> Enum.with_index(1)
    |> Enum.reject(fn {_line, line_num} -> line_num in callback_line_numbers end)
    |> Enum.map(fn {line, _} -> line end)
    |> Enum.join("\n")
  end

  # Generate migration report
  defp report_implementation_migration(
         behaviour_results,
         callback_results,
         target_modules,
         files_with_callbacks,
         dry_run?
       ) do
    mode_info = if dry_run?, do: "[DRY RUN] ", else: ""

    # Count successes
    behaviour_success = Enum.count(behaviour_results, &match?(%{result: {:added, _}}, &1))

    behaviour_already_present =
      Enum.count(behaviour_results, &match?(%{result: {:already_present, _}}, &1))

    callback_success = Enum.count(callback_results, &match?(%{result: {:removed, _}}, &1))

    Mix.shell().info("\n#{mode_info}Implementation Migration Report")
    Mix.shell().info("=" <> String.duplicate("=", 50))

    Mix.shell().info("Target Modules: #{length(target_modules)}")
    Mix.shell().info("Files with Callbacks: #{length(files_with_callbacks)}")

    Mix.shell().info("\n@behaviour Declarations:")
    Mix.shell().info("  Added: #{behaviour_success}")
    Mix.shell().info("  Already Present: #{behaviour_already_present}")

    Mix.shell().info(
      "  Failed: #{length(behaviour_results) - behaviour_success - behaviour_already_present}"
    )

    Mix.shell().info("\n@callback Removals:")
    Mix.shell().info("  Files Processed: #{callback_success}")
    Mix.shell().info("  Failed: #{length(callback_results) - callback_success}")

    Mix.shell().info("\nBehaviour Declaration Results:")

    Enum.each(behaviour_results, fn result ->
      case result.result do
        {:added, _} ->
          Mix.shell().info("  ✓ #{result.module} -> #{result.contract}")

        {:already_present, _} ->
          Mix.shell().info("  = #{result.module} (already has @behaviour)")

        {:dry_run, _} ->
          Mix.shell().info("  → #{result.module} -> #{result.contract}")

        {:error, reason} ->
          Mix.shell().info("  ✗ #{result.module} - #{reason}")
      end
    end)

    Mix.shell().info("\nCallback Removal Results:")

    Enum.each(callback_results, fn result ->
      case result.result do
        {:removed, _} ->
          Mix.shell().info(
            "  ✓ #{Path.basename(result.file)}: #{result.callbacks_removed} callbacks removed"
          )

        {:no_callbacks, _} ->
          Mix.shell().info("  = #{Path.basename(result.file)}: no callbacks found")

        {:dry_run, _} ->
          Mix.shell().info(
            "  → #{Path.basename(result.file)}: #{result.callbacks_removed} callbacks to remove"
          )

        {:error, reason} ->
          Mix.shell().info("  ✗ #{Path.basename(result.file)} - #{reason}")
      end
    end)

    if !dry_run? do
      total_changes = behaviour_success + callback_success

      if total_changes > 0 do
        Mix.shell().info("\nNext Steps:")
        Mix.shell().info("1. Run 'mix compile' to check for compilation errors")
        Mix.shell().info("2. Run 'mix credo.refactor' to validate contract compliance")
        Mix.shell().info("3. Run tests to ensure functionality is preserved")
      end
    end

    # Save migration report
    save_migration_report(
      behaviour_results,
      callback_results,
      target_modules,
      files_with_callbacks,
      dry_run?
    )
  end

  # Fix misplaced @behaviour declarations in @moduledoc strings
  defp fix_misplaced_behaviour_declarations(_issues, opts) do
    Mix.shell().info("🔧 Fixing misplaced @behaviour declarations...")

    # Find files with @behaviour inside @moduledoc strings
    files_to_fix = find_files_with_misplaced_behaviours()

    if opts[:dry_run] do
      Mix.shell().info("DRY RUN: Would fix #{length(files_to_fix)} files:")

      Enum.each(files_to_fix, fn {file, contract} ->
        Mix.shell().info("  #{file} - move @behaviour #{contract}")
      end)
    else
      Enum.each(files_to_fix, fn {file, contract} ->
        fix_behaviour_in_file(file, contract)
      end)

      Mix.shell().info("✅ Fixed @behaviour declarations in #{length(files_to_fix)} files")
    end
  end

  defp find_files_with_misplaced_behaviours do
    # Use grep to find files with @behaviour inside @moduledoc
    case System.cmd("grep", ["-r", "-l", "@behaviour.*Arbor.Contracts", "apps/arbor_core/lib/"]) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.split("\n")
        |> Enum.filter(&(&1 != ""))
        |> Enum.map(&extract_contract_from_file/1)
        |> Enum.filter(fn {_file, contract} -> contract != nil end)

      _ ->
        []
    end
  end

  defp extract_contract_from_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        # Look for @behaviour inside @moduledoc
        case Regex.run(~r/@moduledoc\s+"""\s*@behaviour\s+(Arbor\.Contracts\.\S+)/s, content) do
          [_full_match, contract] ->
            {file_path, String.trim(contract)}

          nil ->
            {file_path, nil}
        end

      _ ->
        {file_path, nil}
    end
  end

  defp fix_behaviour_in_file(file_path, contract) do
    case File.read(file_path) do
      {:ok, content} ->
        # Remove @behaviour from @moduledoc
        content_without_behaviour =
          Regex.replace(
            ~r/(@moduledoc\s+"""\s*)@behaviour\s+#{Regex.escape(contract)}\s*/s,
            content,
            "\\1"
          )

        # Find where to insert the @behaviour declaration (after @moduledoc block)
        case Regex.run(~r/(@moduledoc\s+""".*?""")\s*/s, content_without_behaviour) do
          [_full_match, moduledoc_block] ->
            # Insert @behaviour after the @moduledoc block
            fixed_content =
              String.replace(
                content_without_behaviour,
                moduledoc_block,
                "#{moduledoc_block}\n\n  @behaviour #{contract}"
              )

            File.write!(file_path, fixed_content)
            Mix.shell().info("  ✓ Fixed #{file_path}")

          nil ->
            Mix.shell().error("  ✗ Could not find @moduledoc block in #{file_path}")
        end

      {:error, reason} ->
        Mix.shell().error("  ✗ Could not read #{file_path}: #{reason}")
    end
  end

  # Save detailed migration report
  defp save_migration_report(
         behaviour_results,
         callback_results,
         target_modules,
         files_with_callbacks,
         dry_run?
       ) do
    report = %{
      timestamp: DateTime.utc_now(),
      mode: if(dry_run?, do: "dry_run", else: "execution"),
      summary: %{
        target_modules: length(target_modules),
        files_with_callbacks: length(files_with_callbacks),
        behaviour_declarations_added:
          Enum.count(behaviour_results, &match?(%{result: {:added, _}}, &1)),
        callbacks_removed: Enum.count(callback_results, &match?(%{result: {:removed, _}}, &1))
      },
      behaviour_results: behaviour_results,
      callback_results: callback_results
    }

    filename = if dry_run?, do: "migration_preview.json", else: "migration_results.json"

    case Jason.encode(report, pretty: true) do
      {:ok, json} ->
        File.write!(filename, json)
        Mix.shell().info("\nDetailed migration report saved to: #{filename}")

      {:error, _} ->
        Logger.warning("Could not save migration report")
    end
  end
end
