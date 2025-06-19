#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Setting up Arbor development environment...${NC}"
echo

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check version requirement
check_version() {
    local cmd=$1
    local required=$2
    local current=$($cmd 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?')
    
    if [ -z "$current" ]; then
        echo -e "${RED}❌ Could not determine $cmd version${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ $cmd version: $current${NC}"
    return 0
}

# Check prerequisites
echo -e "${YELLOW}📋 Checking prerequisites...${NC}"

if ! command_exists elixir; then
    echo -e "${RED}❌ Elixir is required but not installed.${NC}"
    echo -e "${YELLOW}   Install with: https://elixir-lang.org/install.html${NC}"
    exit 1
fi

if ! command_exists mix; then
    echo -e "${RED}❌ Mix is required but not installed.${NC}"
    echo -e "${YELLOW}   Mix should come with Elixir installation.${NC}"
    exit 1
fi

if ! command_exists git; then
    echo -e "${RED}❌ Git is required but not installed.${NC}"
    exit 1
fi

# Check versions
check_version "elixir --version" "1.15"
check_version "mix --version" "1.15"

# Check if asdf is available and .tool-versions exists
if command_exists asdf && [ -f ".tool-versions" ]; then
    echo -e "${YELLOW}📦 Installing versions from .tool-versions...${NC}"
    asdf install
fi

echo

# Install hex and rebar if not present
echo -e "${YELLOW}📦 Installing Hex and Rebar...${NC}"
mix local.hex --force --if-missing
mix local.rebar --force --if-missing

echo

# Install dependencies
echo -e "${YELLOW}📦 Installing project dependencies...${NC}"
mix deps.get
mix deps.compile

echo

# Compile project
echo -e "${YELLOW}🔨 Compiling project...${NC}"
mix compile

echo

# Setup dialyzer PLT
echo -e "${YELLOW}🔍 Building Dialyzer PLT (this may take a while on first run)...${NC}"
mix dialyzer --plt

echo

# Run initial quality checks
echo -e "${YELLOW}✨ Running initial quality checks...${NC}"
mix quality

echo

# Create necessary directories
echo -e "${YELLOW}📁 Creating development directories...${NC}"
mkdir -p log
mkdir -p tmp
mkdir -p priv

echo
echo -e "${GREEN}🎉 Setup complete!${NC}"
echo
echo -e "${BLUE}Next steps:${NC}"
echo -e "  • Run ${YELLOW}scripts/dev.sh${NC} to start development server"
echo -e "  • Run ${YELLOW}scripts/test.sh${NC} to run the test suite"
echo -e "  • Run ${YELLOW}mix docs${NC} to generate documentation"
echo -e "  • Check ${YELLOW}README.md${NC} for project overview"
echo