#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🧪 Running Arbor test suite...${NC}"
echo

# Parse command line arguments
COVERAGE=false
VERBOSE=false
FAST=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --coverage)
            COVERAGE=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --fast)
            FAST=true
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --coverage   Generate coverage report"
            echo "  --verbose    Show verbose output"
            echo "  --fast       Skip slow checks (dialyzer)"
            echo "  --help       Show this help"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Function to run a test step
run_step() {
    local step_name=$1
    local command=$2
    
    echo -e "${YELLOW}📋 $step_name...${NC}"
    
    if [ "$VERBOSE" = true ]; then
        eval "$command"
    else
        if eval "$command" > /tmp/arbor_test_output.log 2>&1; then
            echo -e "${GREEN}✅ $step_name passed${NC}"
        else
            echo -e "${RED}❌ $step_name failed${NC}"
            echo -e "${YELLOW}Output:${NC}"
            cat /tmp/arbor_test_output.log
            exit 1
        fi
    fi
    echo
}

# Start timestamp
start_time=$(date +%s)

# Run unit tests
if [ "$COVERAGE" = true ]; then
    run_step "Unit tests with coverage" "mix coveralls.html"
else
    run_step "Unit tests" "mix test"
fi

# Code formatting check
run_step "Code formatting" "mix format --check-formatted"

# Static analysis
run_step "Static analysis (Credo)" "mix credo --strict"

# Type checking (skip if fast mode)
if [ "$FAST" = false ]; then
    run_step "Type checking (Dialyzer)" "mix dialyzer"
else
    echo -e "${YELLOW}⏩ Skipping Dialyzer in fast mode${NC}"
    echo
fi

# Documentation check
run_step "Documentation check" "mix docs"

# Calculate duration
end_time=$(date +%s)
duration=$((end_time - start_time))

echo -e "${GREEN}🎉 All tests passed!${NC}"
echo -e "${BLUE}⏱️  Total duration: ${duration}s${NC}"

if [ "$COVERAGE" = true ]; then
    echo -e "${BLUE}📊 Coverage report generated: cover/excoveralls.html${NC}"
fi

echo -e "${BLUE}📚 Documentation generated: doc/index.html${NC}"
echo