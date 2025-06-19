#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔌 Connecting to Arbor development node...${NC}"
echo

# Default connection settings
TARGET_NODE="arbor@localhost"
COOKIE="arbor_dev"
CONSOLE_NODE="console@localhost"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --node)
            TARGET_NODE="$2"
            shift 2
            ;;
        --cookie)
            COOKIE="$2"
            shift 2
            ;;
        --name)
            CONSOLE_NODE="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --node NODE      Target node to connect to (default: arbor@localhost)"
            echo "  --cookie COOKIE  Erlang cookie (default: arbor_dev)"
            echo "  --name NAME      Console node name (default: console@localhost)"
            echo "  --help           Show this help"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check if target node is reachable
echo -e "${YELLOW}🔍 Checking if target node $TARGET_NODE is reachable...${NC}"

# Try to ping the node
if timeout 5s erl -name "ping_test@localhost" -cookie "$COOKIE" -noshell -eval "
case net_adm:ping('$TARGET_NODE') of
    pong -> io:format(\"reachable~n\"), halt(0);
    pang -> io:format(\"unreachable~n\"), halt(1)
end." 2>/dev/null | grep -q "reachable"; then
    echo -e "${GREEN}✅ Target node is reachable${NC}"
else
    echo -e "${RED}❌ Target node $TARGET_NODE is not reachable${NC}"
    echo -e "${YELLOW}💡 Make sure the development server is running with: scripts/dev.sh${NC}"
    exit 1
fi

echo
echo -e "${GREEN}🌐 Connecting to: $TARGET_NODE${NC}"
echo -e "${GREEN}🍪 Using cookie: $COOKIE${NC}"
echo -e "${GREEN}🏷️  Console name: $CONSOLE_NODE${NC}"
echo
echo -e "${YELLOW}💡 You are now connected to the running Arbor node${NC}"
echo -e "${YELLOW}💡 Type 'Node.list()' to see connected nodes${NC}"
echo -e "${YELLOW}💡 Type 'q().' or press Ctrl+C twice to disconnect${NC}"
echo

# Connect to the running node
iex \
  --name "$CONSOLE_NODE" \
  --cookie "$COOKIE" \
  --remsh "$TARGET_NODE"