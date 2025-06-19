#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔥 Starting Arbor development environment...${NC}"
echo

# Check if project is compiled
if [ ! -d "_build/dev" ]; then
    echo -e "${YELLOW}📦 Project not compiled yet, running setup...${NC}"
    mix compile
fi

# Set node name and cookie for distributed development
NODE_NAME="arbor@localhost"
COOKIE="arbor_dev"

echo -e "${GREEN}🌐 Starting distributed node: $NODE_NAME${NC}"
echo -e "${GREEN}🍪 Using cookie: $COOKIE${NC}"
echo
echo -e "${YELLOW}💡 To connect from another terminal, run: scripts/console.sh${NC}"
echo -e "${YELLOW}💡 Press Ctrl+C twice to exit${NC}"
echo

# Start interactive development session
# Note: This will need to be updated when Phoenix is added
# For now, start with basic IEx session for umbrella project
iex \
  --name "$NODE_NAME" \
  --cookie "$COOKIE" \
  --erl "+pc unicode" \
  -S mix