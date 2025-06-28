#!/bin/bash

# Hybrid Dialyzer Script
# This script implements a hybrid approach for Dialyzer suppressions:
# - Dependencies (deps/) use .dialyzer_ignore.exs
# - Project code (lib/, apps/) use inline @dialyzer attributes

set -e

echo "🔍 Running Hybrid Dialyzer Analysis"
echo "===================================="

# Step 1: Backup current configuration
cp mix.exs mix.exs.dialyzer_backup

# Step 2: Run dialyzer WITHOUT ignore file to get all warnings
echo -e "\n📋 Phase 1: Collecting all warnings (inline suppressions active)..."
sed -i.bak 's/ignore_warnings: ".dialyzer_ignore.exs",/# ignore_warnings: ".dialyzer_ignore.exs",/' mix.exs

# Run dialyzer and capture output
mix dialyzer --format short > .dialyzer_raw_output.txt 2>&1 || true

# Step 3: Filter warnings based on hybrid rules
echo -e "\n🔧 Phase 2: Applying hybrid filtering..."

# Create a temporary Elixir script for filtering
cat > .dialyzer_filter.exs << 'EOF'
# Load ignore patterns
ignore_patterns = if File.exists?(".dialyzer_ignore.exs") do
  {patterns, _} = Code.eval_file(".dialyzer_ignore.exs")
  patterns
else
  []
end

# Read raw output
raw_output = File.read!(".dialyzer_raw_output.txt")

# Parse warnings
warnings = raw_output
  |> String.split("\n")
  |> Enum.filter(&String.match?(&1, ~r/^\S+:\d+:\w+\s/))
  |> Enum.map(fn line ->
    case Regex.run(~r/^(.+?):(\d+):(\w+)\s+(.+)$/, line) do
      [_, file, line_num, type, desc] ->
        %{
          file: file,
          line: String.to_integer(line_num),
          type: String.to_atom(type),
          description: desc,
          raw: line
        }
      _ -> nil
    end
  end)
  |> Enum.filter(& &1)

# Apply hybrid filtering
filtered = Enum.filter(warnings, fn warning ->
  # Dependencies should use ignore file
  if String.starts_with?(warning.file, "deps/") do
    # Check if matches any ignore pattern
    not Enum.any?(ignore_patterns, fn
      {file, type, line} when is_binary(file) ->
        warning.file == file and warning.type == type and warning.line == line
      {file, type} when is_binary(file) ->
        warning.file == file and warning.type == type
      _ -> false
    end)
  else
    # Project files use inline suppressions (already filtered by dialyzer)
    true
  end
end)

# Output results
if Enum.empty?(filtered) do
  IO.puts("\n✅ No warnings found after hybrid filtering!")
else
  IO.puts("\n⚠️  Warnings after hybrid filtering:\n")
  Enum.each(filtered, fn w -> IO.puts(w.raw) end)
  IO.puts("\nTotal warnings: #{length(filtered)}")
end

# Write count for exit code
File.write!(".dialyzer_warning_count.txt", "#{length(filtered)}")
EOF

# Run the filter
elixir .dialyzer_filter.exs

# Step 4: Clean up and restore
echo -e "\n🧹 Cleaning up..."
mv mix.exs.dialyzer_backup mix.exs
rm -f mix.exs.bak .dialyzer_raw_output.txt .dialyzer_filter.exs

# Exit with appropriate code
WARNING_COUNT=$(cat .dialyzer_warning_count.txt)
rm -f .dialyzer_warning_count.txt

if [ "$WARNING_COUNT" -eq "0" ]; then
  exit 0
else
  exit 1
fi