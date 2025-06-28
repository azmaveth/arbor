#!/bin/bash

# Silent script runner that shows only test results
# Usage: ./run_silent.sh <script_name>

if [ $# -eq 0 ]; then
    echo "Usage: $0 <script_name>"
    echo "Example: $0 module_loading_test.exs"
    exit 1
fi

SCRIPT_NAME="$1"
SCRIPT_PATH="$(dirname "$0")/$SCRIPT_NAME"

if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Error: Script $SCRIPT_PATH not found"
    exit 1
fi

echo "🧪 Running $SCRIPT_NAME (clean output)..."
echo

# Run the script and show only essential test output
elixir "$SCRIPT_PATH" 2>&1 | \
  grep -v -E "(==> arbor_core|warning:|This clause|got \"@impl true\"|The function passed|https://hexdocs.pm|Postgrex.Protocol|Starting|info\]|error\]|debug\]|module.*is not a behaviour|undefined.*cpu_sup)" | \
  grep -v -E "(▲|│|└|The known callbacks are:|defmodule|use Arbor)" | \
  grep -v "^\s*\*" | \
  grep -v "^\s*$" | \
  sed '/^[[:space:]]*$/d'

echo
echo "✅ Script completed"