#!/bin/bash

# smoke.sh - Smoke tests for mac_tools CLI
# Verifies JSON outputs and basic functionality

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY="$PROJECT_DIR/.build/release/mac_tools"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Build the binary first if it doesn't exist
if [[ ! -f "$BINARY" ]]; then
    echo -e "${YELLOW}Building mac_tools binary...${NC}"
    cd "$PROJECT_DIR"
    swift build -c release
fi

# Function to run a command and verify JSON output
run_test() {
    local test_name="$1"
    local cmd="$2"
    local expected_exit_code="${3:-0}"
    
    echo -e "${YELLOW}Running: $test_name${NC}"
    echo "Command: $cmd"
    
    set +e
    output=$(eval "$cmd" 2>&1)
    exit_code=$?
    set -e
    
    # Check exit code
    if [[ $exit_code -ne $expected_exit_code ]]; then
        echo -e "${RED}FAIL: Expected exit code $expected_exit_code, got $exit_code${NC}"
        echo "Output: $output"
        return 1
    fi
    
    # Verify JSON output
    if ! echo "$output" | jq . >/dev/null 2>&1; then
        echo -e "${RED}FAIL: Invalid JSON output${NC}"
        echo "Output: $output"
        return 1
    fi
    
    echo -e "${GREEN}PASS${NC}"
    echo "JSON output validated successfully"
    echo ""
    return 0
}

# Function to run tests
run_smoke_tests() {
    local failed=0
    
    echo "=== mac_tools Smoke Tests ==="
    echo ""
    
    # Test 1: Version and help
    run_test "Version check" "$BINARY --version" || ((failed++))
    run_test "Help output" "$BINARY --help" || ((failed++))
    
    # Test 2: TCC permissions request (should work without actual permissions)
    run_test "TCC request dry run" "$BINARY tcc_request --calendar --reminders" || ((failed++))
    
    # Test 3: Calendar list (may fail due to permissions, but should return JSON error)
    run_test "Calendar list" "$BINARY calendar_list --from=2024-01-01 --to=2024-01-31" 1 || ((failed++))
    
    # Test 4: Mail headers (may fail due to permissions, but should return JSON error)
    run_test "Mail headers" "$BINARY mail_list_headers --limit=5" 1 || ((failed++))
    
    # Test 5: Reminders create dry run
    run_test "Reminders create dry run" "$BINARY reminders_create --title='Test Reminder' --dry-run" || ((failed++))
    
    # Test 6: Notes append dry run
    run_test "Notes append dry run" "$BINARY notes_append --note-id='test' --text='test text' --dry-run" || ((failed++))
    
    # Test 7: Files move dry run
    # Create a temporary file first
    temp_file=$(mktemp)
    echo "test content" > "$temp_file"
    temp_dest="${temp_file}.moved"
    
    run_test "Files move dry run" "$BINARY files_move --src='$temp_file' --dst='$temp_dest' --dry-run" || ((failed++))
    
    # Clean up
    rm -f "$temp_file" "$temp_dest"
    
    # Test 8: Invalid commands should return JSON errors
    run_test "Invalid command" "$BINARY nonexistent_command" 1 || ((failed++))
    
    # Test 9: Missing required arguments
    run_test "Missing title argument" "$BINARY reminders_create --dry-run" 1 || ((failed++))
    
    echo "=== Smoke Tests Complete ==="
    
    if [[ $failed -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}$failed tests failed${NC}"
        return 1
    fi
}

# Check dependencies
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required for JSON validation${NC}"
    echo "Install with: brew install jq"
    exit 1
fi

# Run the tests
run_smoke_tests