#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Building Arbor production release...${NC}"
echo

# Parse command line arguments
ENVIRONMENT="prod"
SKIP_TESTS=false
VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --env ENV        Build environment (default: prod)"
            echo "  --skip-tests     Skip running tests before build"
            echo "  --version VER    Set release version"
            echo "  --help           Show this help"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Set environment
export MIX_ENV="$ENVIRONMENT"

echo -e "${YELLOW}🏗️  Environment: $ENVIRONMENT${NC}"
if [ -n "$VERSION" ]; then
    echo -e "${YELLOW}📋 Version: $VERSION${NC}"
fi
echo

# Function to run a build step
run_step() {
    local step_name=$1
    local command=$2
    
    echo -e "${YELLOW}📋 $step_name...${NC}"
    
    if eval "$command"; then
        echo -e "${GREEN}✅ $step_name completed${NC}"
    else
        echo -e "${RED}❌ $step_name failed${NC}"
        exit 1
    fi
    echo
}

# Start timestamp
start_time=$(date +%s)

# Clean previous builds
run_step "Cleaning previous builds" "rm -rf _build/$ENVIRONMENT"

# Install production dependencies
run_step "Installing production dependencies" "mix deps.get --only=$ENVIRONMENT"

# Compile in production mode
run_step "Compiling for production" "mix deps.compile && mix compile"

# Run tests unless skipped
if [ "$SKIP_TESTS" = false ]; then
    run_step "Running test suite" "MIX_ENV=test mix test.all"
else
    echo -e "${YELLOW}⏩ Skipping tests${NC}"
    echo
fi

# Generate documentation
run_step "Generating documentation" "mix docs"

# Future: This will be updated when we add release configuration
echo -e "${YELLOW}📦 Preparing release artifacts...${NC}"

# Create release directory structure
mkdir -p releases/$ENVIRONMENT
mkdir -p releases/$ENVIRONMENT/lib

# Copy compiled applications
cp -r _build/$ENVIRONMENT/lib/* releases/$ENVIRONMENT/lib/

# Create version file
if [ -n "$VERSION" ]; then
    echo "$VERSION" > releases/$ENVIRONMENT/VERSION
else
    # Extract version from mix.exs
    VERSION=$(grep 'version:' mix.exs | sed 's/.*version: "\(.*\)".*/\1/')
    echo "$VERSION" > releases/$ENVIRONMENT/VERSION
fi

# Create release info
cat > releases/$ENVIRONMENT/RELEASE_INFO << EOF
Arbor Release Information
========================
Version: $VERSION
Environment: $ENVIRONMENT
Built: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Git Commit: $(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
Built by: $(whoami)
Built on: $(hostname)
EOF

# Calculate duration
end_time=$(date +%s)
duration=$((end_time - start_time))

echo -e "${GREEN}🎉 Release build completed successfully!${NC}"
echo -e "${BLUE}⏱️  Build duration: ${duration}s${NC}"
echo -e "${BLUE}📁 Release location: releases/$ENVIRONMENT/${NC}"
echo -e "${BLUE}📋 Version: $VERSION${NC}"
echo

echo -e "${YELLOW}📦 Release contents:${NC}"
ls -la releases/$ENVIRONMENT/

echo
echo -e "${YELLOW}💡 Next steps:${NC}"
echo -e "  • Test the release in a staging environment"
echo -e "  • Deploy to production infrastructure"
echo -e "  • Monitor application startup and health"
echo