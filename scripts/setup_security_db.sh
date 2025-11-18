#!/usr/bin/env bash
#
# Setup script for Arbor Security database
#
# This script creates the security database and runs migrations
# Run this after the main arbor database is set up

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$PROJECT_ROOT"

echo "================================================"
echo "Arbor Security Database Setup"
echo "================================================"
echo ""

# Check if running in development or test environment
if [ -z "$MIX_ENV" ]; then
  MIX_ENV=dev
fi

echo "Environment: $MIX_ENV"
echo ""

# Create the database
echo "Creating arbor_security_${MIX_ENV} database..."
mix ecto.create -r Arbor.Security.Repo || echo "Database may already exist"

echo ""
echo "Running migrations..."
mix ecto.migrate -r Arbor.Security.Repo

echo ""
echo "================================================"
echo "Setup Complete!"
echo "================================================"
echo ""
echo "The security database is now ready to use."
echo "CapabilityStore and AuditLogger will persist data to PostgreSQL."
echo ""
