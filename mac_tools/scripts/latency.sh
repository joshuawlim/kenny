#!/bin/bash

# latency.sh - Performance benchmarking for mac_tools CLI
# Measures P50 latencies for each command

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY="$PROJECT_DIR/.build/release/mac_tools"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Performance thresholds (in milliseconds)
LIST_COMMAND_THRESHOLD=1200  # 1.2s for list commands
MUTATE_COMMAND_THRESHOLD=3000  # 3.0s for create/mutate commands

# Build the binary first if it doesn't exist
if [[ ! -f "$BINARY" ]]; then
    echo -e "${YELLOW}Building mac_tools binary...${NC}"
    cd "$PROJECT_DIR"
    swift build -c release
fi

# Function to measure command latency
measure_latency() {
    local test_name="$1"
    local cmd="$2"
    local runs="${3:-20}"
    local threshold="$4"
    
    echo -e "${BLUE}Measuring latency: $test_name${NC}"
    echo "Command: $cmd"
    echo "Runs: $runs"
    
    local times=()
    local failed_runs=0
    
    for ((i=1; i<=runs; i++)); do
        echo -n "Run $i/$runs... "
        
        local start_time=$(date +%s%3N)
        
        set +e
        eval "$cmd" >/dev/null 2>&1
        local exit_code=$?
        set -e
        
        local end_time=$(date +%s%3N)
        local duration=$((end_time - start_time))
        
        if [[ $exit_code -eq 0 ]]; then
            times+=($duration)
            echo "${duration}ms"
        else
            echo -e "${RED}FAILED${NC}"
            ((failed_runs++))
        fi
    done
    
    if [[ ${#times[@]} -eq 0 ]]; then
        echo -e "${RED}All runs failed for: $test_name${NC}"
        return 1
    fi
    
    # Sort times array
    IFS=$'\n' times=($(sort -n <<<"${times[*]}"))
    unset IFS
    
    # Calculate statistics
    local total_runs=${#times[@]}
    local p50_index=$((total_runs / 2))
    local p90_index=$((total_runs * 9 / 10))
    local p99_index=$((total_runs * 99 / 100))
    
    local min=${times[0]}
    local max=${times[-1]}
    local p50=${times[$p50_index]}
    local p90=${times[$p90_index]}
    local p99=${times[$p99_index]}
    
    # Calculate average
    local sum=0
    for time in "${times[@]}"; do
        sum=$((sum + time))
    done
    local avg=$((sum / total_runs))
    
    echo ""
    echo "Results for $test_name:"
    echo "  Successful runs: $total_runs/$runs"
    echo "  Failed runs: $failed_runs"
    echo "  Min: ${min}ms"
    echo "  Avg: ${avg}ms"
    echo "  P50: ${p50}ms"
    echo "  P90: ${p90}ms"
    echo "  P99: ${p99}ms"
    echo "  Max: ${max}ms"
    
    # Check against threshold
    if [[ $p50 -le $threshold ]]; then
        echo -e "  Status: ${GREEN}PASS${NC} (P50: ${p50}ms ≤ ${threshold}ms threshold)"
        echo ""
        return 0
    else
        echo -e "  Status: ${RED}FAIL${NC} (P50: ${p50}ms > ${threshold}ms threshold)"
        echo ""
        return 1
    fi
}

# Function to run latency tests
run_latency_tests() {
    local failed=0
    
    echo "=== mac_tools Latency Tests ==="
    echo ""
    
    # Create temporary files for file operations
    temp_file=$(mktemp)
    echo "test content for latency testing" > "$temp_file"
    temp_dest="${temp_file}.moved"
    
    # Test 1: TCC request (should be fast)
    measure_latency "TCC Request" "$BINARY tcc_request --calendar" 20 $LIST_COMMAND_THRESHOLD || ((failed++))
    
    # Test 2: Calendar list (list command)
    measure_latency "Calendar List" "$BINARY calendar_list --from=2024-01-01 --to=2024-01-07" 20 $LIST_COMMAND_THRESHOLD || ((failed++))
    
    # Test 3: Mail headers (list command)  
    measure_latency "Mail Headers" "$BINARY mail_list_headers --limit=10" 20 $LIST_COMMAND_THRESHOLD || ((failed++))
    
    # Test 4: Reminders create dry run (mutate command)
    measure_latency "Reminders Create (dry-run)" "$BINARY reminders_create --title='Latency Test Reminder' --dry-run" 20 $MUTATE_COMMAND_THRESHOLD || ((failed++))
    
    # Test 5: Notes append dry run (mutate command)
    measure_latency "Notes Append (dry-run)" "$BINARY notes_append --note-id='latency-test' --text='latency test text' --dry-run" 20 $MUTATE_COMMAND_THRESHOLD || ((failed++))
    
    # Test 6: Files move dry run (mutate command)
    measure_latency "Files Move (dry-run)" "$BINARY files_move --src='$temp_file' --dst='$temp_dest' --dry-run" 20 $MUTATE_COMMAND_THRESHOLD || ((failed++))
    
    # Clean up
    rm -f "$temp_file" "$temp_dest"
    
    echo "=== Latency Tests Complete ==="
    
    if [[ $failed -eq 0 ]]; then
        echo -e "${GREEN}All latency tests passed!${NC}"
        echo "All commands meet performance requirements:"
        echo "  - List commands: ≤ ${LIST_COMMAND_THRESHOLD}ms P50"
        echo "  - Mutate commands: ≤ ${MUTATE_COMMAND_THRESHOLD}ms P50"
        return 0
    else
        echo -e "${RED}$failed latency tests failed${NC}"
        echo "Some commands exceed performance thresholds"
        return 1
    fi
}

# Function to generate performance report
generate_report() {
    echo "=== Performance Report ==="
    echo "Date: $(date)"
    echo "Platform: $(uname -a)"
    echo "Swift Version: $(swift --version | head -1)"
    echo ""
    
    run_latency_tests
}

# Check if running in CI or verbose mode
if [[ "${1:-}" == "--report" ]]; then
    generate_report
else
    run_latency_tests
fi