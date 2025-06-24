#!/bin/bash
# test-distributed.sh - Run distributed tests locally
#
# This script sets up the environment and runs distributed tests,
# which test multi-node scenarios, CRDT synchronization, and failover behavior.

set -e

echo "🔄 Running distributed tests..."
echo "This will start a multi-node cluster and may take several minutes."
echo ""

# Set environment variables
export ARBOR_DISTRIBUTED_TEST=true
export MULTI_NODE_TESTS=true
export MIX_ENV=test

# Ensure dependencies are up to date
echo "📦 Fetching dependencies..."
mix deps.get

# Compile the project
echo "🔨 Compiling project..."
mix compile

# Run distributed tests
echo "🧪 Running distributed tests..."
mix test.dist

echo ""
echo "✅ Distributed tests complete!"