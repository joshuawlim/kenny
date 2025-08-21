#!/bin/bash

# Week 0 smoke tests - only test what's actually implemented
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

test_json() {
    local name="$1"
    local cmd="$2"
    local expected_exit="$3"
    
    echo -n "Testing $name... "
    output=$(eval "$cmd" 2>&1)
    exit_code=$?
    
    if [ $exit_code -eq $expected_exit ]; then
        if echo "$output" | jq . >/dev/null 2>&1; then
            echo -e "${GREEN}PASS${NC}"
            ((PASS_COUNT++))
        else
            echo -e "${RED}FAIL${NC} (invalid JSON)"
            echo "  Output: $output"
            ((FAIL_COUNT++))
        fi
    else
        echo -e "${RED}FAIL${NC} (exit code $exit_code, expected $expected_exit)"
        echo "  Output: $output"
        ((FAIL_COUNT++))
    fi
}

echo "=== Week 0 mac_tools Tests ==="

# Test version
test_json "version" "mac_tools version" 0

# Test tcc_request with various flags
test_json "tcc_request (calendar)" "mac_tools tcc_request --calendar" 0
test_json "tcc_request (multiple)" "mac_tools tcc_request --calendar --notes --reminders" 0

# Test calendar_list with valid ISO8601
test_json "calendar_list (valid ISO8601)" \
    "mac_tools calendar_list --from '2024-01-01T00:00:00Z' --to '2024-01-02T00:00:00Z'" 0

# Test calendar_list with invalid dates (should return error JSON)
test_json "calendar_list (invalid dates)" \
    "mac_tools calendar_list --from 'bad-date' --to 'also-bad'" 2

# Test help doesn't output JSON (should fail JSON check but that's expected)
echo -n "Testing help output... "
if mac_tools --help 2>&1 | grep -q "SUBCOMMANDS"; then
    echo -e "${GREEN}PASS${NC} (help works)"
    ((PASS_COUNT++))
else
    echo -e "${RED}FAIL${NC}"
    ((FAIL_COUNT++))
fi

echo ""
echo "=== Summary ==="
echo -e "${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "${RED}Failed: $FAIL_COUNT${NC}"

exit $FAIL_COUNT