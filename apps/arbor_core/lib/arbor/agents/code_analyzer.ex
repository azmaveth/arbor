defmodule Arbor.Agents.CodeAnalyzer do
  @moduledoc """
  A code analysis agent that provides file and directory analysis capabilities.

  The CodeAnalyzer agent can:
  - Analyze individual files for LOC, language detection, and complexity
  - Analyze directories with aggregated metrics
  - List files in directories with security restrictions
  - Execute analysis commands through a generic exec interface

  ## Security Features

  - Filesystem access restricted to agent working directory and below
  - Path traversal prevention (rejects ".." and unauthorized absolute paths)
  - Resource limits (maximum file size: 10MB)
  - Command validation against allow-list

  ## Usage

      # Spawn agent through HordeSupervisor
      {:ok, pid} = Arbor.Core.HordeSupervisor.start_agent(
        Arbor.Agents.CodeAnalyzer,
        agent_id: "analyzer_001",
        working_dir: "/safe/analysis/path"
      )

      # Use agent through client API
      {:ok, analysis} = Arbor.Agents.CodeAnalyzer.analyze_file("analyzer_001", "file.ex")
      {:ok, files} = Arbor.Agents.CodeAnalyzer.list_files("analyzer_001", ".")
  """

  @behaviour Arbor.Contracts.Agents.CodeAnalyzer

  # Note: The following warning is acceptable and expected:
  # "this clause of defp handle_restore_result/2 is never used"
  # This occurs because AgentBehavior generates defensive error handling
  # for restore_state/2, but this module uses the default implementation
  # which always returns {:ok, _}. The error clauses are needed for other
  # modules that override restore_state/2 to return errors.
  use Arbor.Core.AgentBehavior

  # 10MB
  @max_file_size 10 * 1024 * 1024
  @allowed_extensions ~w(.ex .exs .py .js .ts .rb .go .rs .java .c .cpp .h .hpp)

  # ================================
  # Behaviour Callbacks
  # ================================

  @impl Arbor.Contracts.Agents.CodeAnalyzer
  @spec process(input :: any()) :: {:ok, output :: any()} | {:error, term()}
  def process(input) do
    # This is a generic process function that could be used for batch operations
    # or alternative processing modes. For now, it delegates to the appropriate
    # function based on the input format.
    case input do
      {:analyze_file, agent_id, path} ->
        analyze_file(agent_id, path)

      {:analyze_directory, agent_id, path} ->
        analyze_directory(agent_id, path)

      {:list_files, agent_id, path} ->
        list_files(agent_id, path)

      _ ->
        {:error, :invalid_input}
    end
  end

  @impl Arbor.Contracts.Agents.CodeAnalyzer
  @spec configure(options :: keyword()) :: :ok | {:error, term()}
  def configure(options) do
    # Configuration could include setting working directory, max file size, etc.
    # For now, we'll accept any configuration
    _ = options
    :ok
  end

  # ================================
  # Client API
  # ================================

  @doc """
  Start the CodeAnalyzer agent.

  ## Required Args
  - `:agent_id` - Unique identifier for this agent
  - `:working_dir` - Safe directory path for analysis (optional, defaults to /tmp)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    agent_id = Keyword.fetch!(args, :agent_id)
    GenServer.start_link(__MODULE__, args, name: via_name(agent_id))
  end

  @doc """
  Analyze a single file for metrics and characteristics.

  Returns analysis including:
  - Lines of code (total, code, comments, blank)
  - Language detection
  - Basic complexity metrics
  - File size and modification time

  ## Example
      {:ok, analysis} = CodeAnalyzer.analyze_file("agent_id", "lib/app.ex")
      # => {:ok, %{
      #   language: "elixir",
      #   lines: %{total: 150, code: 120, comments: 20, blank: 10},
      #   complexity: %{cyclomatic: 8, cognitive: 12},
      #   size_bytes: 4568,
      #   modified_at: ~U[2025-06-21 10:30:00Z]
      # }}
  """
  @spec analyze_file(String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def analyze_file(agent_id, path) do
    GenServer.call(via_name(agent_id), {:analyze_file, path})
  end

  @doc """
  Analyze all files in a directory with aggregated metrics.

  ## Example
      {:ok, analysis} = CodeAnalyzer.analyze_directory("agent_id", "lib/")
  """
  @spec analyze_directory(String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def analyze_directory(agent_id, path) do
    GenServer.call(via_name(agent_id), {:analyze_directory, path})
  end

  @doc """
  List files in a directory with security filtering.

  Only returns files within the agent's working directory.
  """
  @spec list_files(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, any()}
  def list_files(agent_id, path) do
    GenServer.call(via_name(agent_id), {:list_files, path})
  end

  @doc """
  Execute a command with arguments.

  Supports the following commands:
  - "analyze" - Analyze file or directory
  - "list" - List files
  - "status" - Get agent status

  ## Example
      {:ok, result} = CodeAnalyzer.exec("agent_id", "analyze", ["lib/app.ex"])
  """
  @spec exec(String.t(), String.t(), [String.t()]) :: {:ok, any()} | {:error, any()}
  def exec(agent_id, command, args \\ []) do
    GenServer.call(via_name(agent_id), {:exec, command, args})
  end

  # ================================
  # GenServer Callbacks
  # ================================

  @impl true
  def init(args) do
    agent_id = Keyword.fetch!(args, :agent_id)
    working_dir = Keyword.get(args, :working_dir, "/tmp")

    # Ensure working directory exists and is safe
    case validate_and_create_working_dir(working_dir) do
      {:ok, safe_working_dir} ->
        Logger.info("CodeAnalyzer agent initialized",
          agent_id: agent_id,
          working_dir: safe_working_dir
        )

        state = %{
          agent_id: agent_id,
          working_dir: safe_working_dir,
          created_at: DateTime.utc_now(),
          analysis_count: 0,
          last_analysis: nil
        }

        {:ok, state, {:continue, :register_with_supervisor}}

      {:error, reason} ->
        Logger.error("Invalid working directory for CodeAnalyzer",
          agent_id: agent_id,
          working_dir: working_dir,
          reason: reason
        )

        {:stop, {:invalid_working_dir, reason}}
    end
  end

  @impl Arbor.Core.AgentBehavior
  def get_agent_metadata(state) do
    %{
      type: :code_analyzer,
      capabilities: [:analyze_file, :analyze_directory, :list_files, :exec],
      working_dir: state.working_dir,
      max_file_size: @max_file_size,
      supported_extensions: @allowed_extensions
    }
  end

  @impl true
  def handle_call({:analyze_file, path}, _from, state) do
    with {:ok, safe_path} <- validate_path(path, state.working_dir),
         {:ok, analysis} <- perform_file_analysis(safe_path) do
      new_state = %{
        state
        | analysis_count: state.analysis_count + 1,
          last_analysis: DateTime.utc_now()
      }

      Logger.info("File analysis completed",
        agent_id: state.agent_id,
        path: safe_path,
        language: analysis.language
      )

      {:reply, {:ok, analysis}, new_state}
    else
      {:error, reason} = error ->
        Logger.warning("File analysis failed",
          agent_id: state.agent_id,
          path: path,
          reason: reason
        )

        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:analyze_directory, path}, _from, state) do
    with {:ok, safe_path} <- validate_path(path, state.working_dir),
         {:ok, analysis} <- perform_directory_analysis(safe_path) do
      new_state = %{
        state
        | analysis_count: state.analysis_count + 1,
          last_analysis: DateTime.utc_now()
      }

      Logger.info("Directory analysis completed",
        agent_id: state.agent_id,
        path: safe_path,
        files_analyzed: analysis.files_count
      )

      {:reply, {:ok, analysis}, new_state}
    else
      {:error, reason} = error ->
        Logger.warning("Directory analysis failed",
          agent_id: state.agent_id,
          path: path,
          reason: reason
        )

        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:list_files, path}, _from, state) do
    with {:ok, safe_path} <- validate_path(path, state.working_dir),
         {:ok, files} <- list_directory_files(safe_path) do
      {:reply, {:ok, files}, state}
    else
      {:error, reason} = error ->
        Logger.warning("Directory listing failed",
          agent_id: state.agent_id,
          path: path,
          reason: reason
        )

        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:exec, command, args}, _from, state) do
    case execute_command(command, args, state) do
      {:ok, _result} = success ->
        Logger.info("Command executed successfully",
          agent_id: state.agent_id,
          command: command,
          args_count: length(args)
        )

        {:reply, success, state}

      {:error, reason} = error ->
        Logger.warning("Command execution failed",
          agent_id: state.agent_id,
          command: command,
          reason: reason
        )

        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      agent_id: state.agent_id,
      type: :code_analyzer,
      status: :active,
      created_at: state.created_at,
      analysis_count: state.analysis_count,
      last_analysis: state.last_analysis,
      working_dir: state.working_dir
    }

    {:reply, {:ok, status}, state}
  end

  # ================================
  # Private Implementation
  # ================================

  defp via_name(agent_id) do
    {:via, Horde.Registry, {Arbor.Core.HordeAgentRegistry, agent_id}}
  end

  defp validate_and_create_working_dir(path) do
    # Resolve to absolute path and ensure it's safe
    abs_path = Path.expand(path)

    # Basic security check - reject paths that could be system directories
    cond do
      String.starts_with?(abs_path, "/etc") ->
        {:error, :system_directory_not_allowed}

      String.starts_with?(abs_path, "/root") ->
        {:error, :system_directory_not_allowed}

      String.starts_with?(abs_path, "/sys") ->
        {:error, :system_directory_not_allowed}

      true ->
        case File.mkdir_p(abs_path) do
          :ok -> {:ok, abs_path}
          {:error, reason} -> {:error, {:mkdir_failed, reason}}
        end
    end
  end

  defp validate_path(path, working_dir) do
    # Prevent path traversal attacks
    if String.contains?(path, "..") do
      {:error, :path_traversal_detected}
    else
      # Convert to absolute path relative to working directory
      abs_path =
        if Path.type(path) == :absolute do
          path
        else
          Path.join(working_dir, path)
        end

      abs_path = Path.expand(abs_path)

      # Ensure the path is within working directory
      if String.starts_with?(abs_path, working_dir) do
        {:ok, abs_path}
      else
        {:error, :path_outside_working_dir}
      end
    end
  end

  defp perform_file_analysis(file_path) do
    with {:ok, stat} <- File.stat(file_path),
         :ok <- check_file_size(stat.size),
         {:ok, content} <- File.read(file_path) do
      language = detect_language(file_path)
      lines = analyze_lines(content)
      complexity = calculate_complexity(content, language)

      analysis = %{
        path: file_path,
        language: language,
        lines: lines,
        complexity: complexity,
        size_bytes: stat.size,
        modified_at: stat.mtime
      }

      {:ok, analysis}
    else
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, :eacces} -> {:error, :access_denied}
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform_directory_analysis(dir_path) do
    case File.ls(dir_path) do
      {:ok, files} ->
        analyses =
          files
          |> Enum.map(&Path.join(dir_path, &1))
          |> Enum.filter(fn path -> File.regular?(path) && has_supported_extension?(path) end)
          |> Enum.map(&perform_file_analysis/1)
          |> Enum.filter(fn
            {:ok, _} -> true
            _ -> false
          end)
          |> Enum.map(fn {:ok, analysis} -> analysis end)

        aggregate = %{
          path: dir_path,
          files_count: length(analyses),
          total_lines: Enum.sum(Enum.map(analyses, & &1.lines.total)),
          total_size: Enum.sum(Enum.map(analyses, & &1.size_bytes)),
          languages: analyses |> Enum.map(& &1.language) |> Enum.uniq(),
          files: analyses
        }

        {:ok, aggregate}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_directory_files(dir_path) do
    case File.ls(dir_path) do
      {:ok, files} ->
        file_info =
          Enum.map(files, fn file ->
            full_path = Path.join(dir_path, file)

            case File.stat(full_path) do
              {:ok, stat} ->
                %{
                  name: file,
                  type: if(stat.type == :directory, do: :directory, else: :file),
                  size: stat.size,
                  modified_at: stat.mtime
                }

              _ ->
                %{name: file, type: :unknown, size: 0, modified_at: nil}
            end
          end)

        {:ok, file_info}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_command(command, args, state) do
    # Validate command against allow-list
    case command do
      "analyze" -> execute_analyze_command(args, state)
      "list" -> execute_list_command(args, state)
      "status" -> execute_status_command(state)
      _ -> {:error, :command_not_allowed}
    end
  end

  defp execute_analyze_command(args, state) do
    case args do
      [path] ->
        case validate_path(path, state.working_dir) do
          {:ok, safe_path} ->
            if File.dir?(safe_path) do
              perform_directory_analysis(safe_path)
            else
              perform_file_analysis(safe_path)
            end

          error ->
            error
        end

      _ ->
        {:error, :invalid_args_for_analyze}
    end
  end

  defp execute_list_command(args, state) do
    case args do
      [] ->
        list_directory_files(state.working_dir)

      [path] ->
        case validate_path(path, state.working_dir) do
          {:ok, safe_path} ->
            list_directory_files(safe_path)

          error ->
            error
        end

      _ ->
        {:error, :invalid_args_for_list}
    end
  end

  defp execute_status_command(state) do
    {:ok,
     %{
       agent_id: state.agent_id,
       analysis_count: state.analysis_count,
       last_analysis: state.last_analysis,
       working_dir: state.working_dir
     }}
  end

  defp check_file_size(size) when size > @max_file_size do
    {:error, :file_too_large}
  end

  defp check_file_size(_size), do: :ok

  @language_map %{
    ".ex" => "elixir",
    ".exs" => "elixir",
    ".py" => "python",
    ".js" => "javascript",
    ".ts" => "typescript",
    ".rb" => "ruby",
    ".go" => "go",
    ".rs" => "rust",
    ".java" => "java",
    ".c" => "c",
    ".cpp" => "cpp",
    ".h" => "c_header",
    ".hpp" => "cpp_header"
  }

  defp detect_language(file_path) do
    ext = Path.extname(file_path)
    Map.get(@language_map, ext, "unknown")
  end

  defp has_supported_extension?(file_path) do
    ext = Path.extname(file_path)
    ext in @allowed_extensions
  end

  defp analyze_lines(content) do
    lines = String.split(content, "\n")

    {code_lines, comment_lines, blank_lines} =
      Enum.reduce(lines, {0, 0, 0}, fn line, {code, comment, blank} ->
        trimmed = String.trim(line)

        cond do
          trimmed == "" -> {code, comment, blank + 1}
          String.starts_with?(trimmed, "#") -> {code, comment + 1, blank}
          String.starts_with?(trimmed, "//") -> {code, comment + 1, blank}
          String.starts_with?(trimmed, "/*") -> {code, comment + 1, blank}
          true -> {code + 1, comment, blank}
        end
      end)

    %{
      total: length(lines),
      code: code_lines,
      comments: comment_lines,
      blank: blank_lines
    }
  end

  defp calculate_complexity(content, language) do
    # Basic complexity analysis - count branching statements
    complexity_keywords =
      case language do
        "elixir" -> ~w(if unless case cond with when)
        "python" -> ~w(if elif while for try except)
        "javascript" -> ~w(if else while for switch case try catch)
        _ -> ~w(if else while for switch case)
      end

    cyclomatic =
      complexity_keywords
      |> Enum.map(fn keyword ->
        content
        |> String.split()
        |> Enum.count(&(&1 == keyword))
      end)
      |> Enum.sum()
      # Base complexity is 1
      |> Kernel.+(1)

    %{
      cyclomatic: cyclomatic,
      # Simplified cognitive complexity
      cognitive: min(cyclomatic, 15)
    }
  end
end
