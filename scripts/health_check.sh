#!/bin/bash
# Health check script for Arbor containerized deployment
set -e

# Configuration
HEALTH_ENDPOINT="${HEALTH_ENDPOINT:-http://localhost:4000/health}"
TIMEOUT="${HEALTH_TIMEOUT:-10}"
NODE_NAME="${NODE_NAME:-arbor@127.0.0.1}"

# Function to check HTTP health endpoint
check_http_health() {
    curl -f -s -m "$TIMEOUT" "$HEALTH_ENDPOINT" > /dev/null 2>&1
    return $?
}

# Function to check Erlang node health
check_node_health() {
    ./bin/arbor rpc "Application.get_application(:arbor_core)" > /dev/null 2>&1
    return $?
}

# Function to check memory usage
check_memory_health() {
    local memory_usage
    memory_usage=$(./bin/arbor rpc ":erlang.memory(:total)" 2>/dev/null | grep -o '[0-9]*' || echo "0")
    
    # Check if memory usage is reasonable (less than 1GB for health check)
    if [ "$memory_usage" -gt 1073741824 ]; then
        echo "WARNING: High memory usage: $memory_usage bytes"
        return 1
    fi
    
    return 0
}

# Function to check application health
check_application_health() {
    # Check if all umbrella applications are running
    local apps=("arbor_contracts" "arbor_security" "arbor_persistence" "arbor_core")
    
    for app in "${apps[@]}"; do
        if ! ./bin/arbor rpc "Application.get_application(:$app)" > /dev/null 2>&1; then
            echo "ERROR: Application $app is not running"
            return 1
        fi
    done
    
    return 0
}

# Main health check
main() {
    local exit_code=0
    
    echo "Arbor Health Check - $(date)"
    echo "Node: $NODE_NAME"
    echo "Endpoint: $HEALTH_ENDPOINT"
    echo "=========================="
    
    # Check HTTP endpoint if available
    if check_http_health; then
        echo "✅ HTTP health endpoint: OK"
    else
        echo "⚠️  HTTP health endpoint: Not available (this may be normal if no HTTP interface is configured)"
    fi
    
    # Check Erlang node
    if check_node_health; then
        echo "✅ Erlang node: OK"
    else
        echo "❌ Erlang node: FAILED"
        exit_code=1
    fi
    
    # Check application health
    if check_application_health; then
        echo "✅ Applications: OK"
    else
        echo "❌ Applications: FAILED"
        exit_code=1
    fi
    
    # Check memory usage
    if check_memory_health; then
        echo "✅ Memory usage: OK"
    else
        echo "⚠️  Memory usage: HIGH"
        # Don't fail on high memory usage, just warn
    fi
    
    echo "=========================="
    
    if [ $exit_code -eq 0 ]; then
        echo "🎉 Health check: PASSED"
    else
        echo "💥 Health check: FAILED"
    fi
    
    exit $exit_code
}

# Run main function
main "$@"