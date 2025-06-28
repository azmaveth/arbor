#!/bin/bash

# Clean script runner that suppresses warnings and errors
# Usage: ./run_clean.sh <script_name>

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

echo "🧪 Running $SCRIPT_NAME (output cleaned)..."
echo

# Run the script and filter out unwanted log messages
elixir "$SCRIPT_PATH" 2>&1 | grep -v -E "(==> arbor_core|warning:|The function passed as a handler|https://hexdocs.pm|Postgrex.Protocol|Starting Horde|Starting Arbor|Telemetry|CapabilityStore|AuditLogger|Security kernel|info\])" | grep -v "^\s*$"

echo
echo "✅ Script completed"