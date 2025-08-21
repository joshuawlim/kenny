#!/bin/bash

# Comprehensive Week 0 test suite - 10/10 success criteria
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_TESTS=50

print_header() {
    echo -e "${YELLOW}=== $1 ===${NC}"
}

test_command() {
    local name="$1"
    local cmd="$2"
    local expected_exit="$3"
    local should_be_json="$4"
    
    echo -n "Testing $name... "
    
    # Run command and capture output/exit code
    set +e
    output=$(eval "$cmd" 2>&1)
    exit_code=$?
    set -e
    
    # Check exit code
    if [ $exit_code -ne $expected_exit ]; then
        echo -e "${RED}FAIL${NC} (exit code $exit_code, expected $expected_exit)"
        echo "  Output: $output"
        ((FAIL_COUNT++))
        return
    fi
    
    # Check JSON validity if required
    if [ "$should_be_json" = "true" ]; then
        if echo "$output" | jq . >/dev/null 2>&1; then
            echo -e "${GREEN}PASS${NC}"
            ((PASS_COUNT++))
        else
            echo -e "${RED}FAIL${NC} (invalid JSON)"
            echo "  Output: $output"
            ((FAIL_COUNT++))
        fi
    else
        echo -e "${GREEN}PASS${NC}"
        ((PASS_COUNT++))
    fi
}

measure_latency() {
    local name="$1"
    local cmd="$2"
    local max_latency="$3"
    
    echo -n "Latency test $name... "
    
    # Run 10 iterations
    local total_time=0
    for i in {1..10}; do
        start_time=$(python3 -c 'import time; print(time.time())')
        eval "$cmd" >/dev/null 2>&1
        end_time=$(python3 -c 'import time; print(time.time())')
        iteration_time=$(python3 -c "print($end_time - $start_time)")
        total_time=$(python3 -c "print($total_time + $iteration_time)")
    done
    
    # Calculate P50 (average for 10 runs)
    avg_time=$(python3 -c "print($total_time / 10)")
    
    if python3 -c "exit(0 if $avg_time <= $max_latency else 1)"; then
        echo -e "${GREEN}PASS${NC} (P50: ${avg_time}s)"
        ((PASS_COUNT++))
    else
        echo -e "${RED}FAIL${NC} (P50: ${avg_time}s > ${max_latency}s)"
        ((FAIL_COUNT++))
    fi
}

# Clear previous logs
rm -f ~/Library/Logs/Assistant/tools.ndjson

print_header "Testing mail_list_headers (10 tests)"
test_command "basic" "mac_tools mail_list_headers" 0 true
test_command "with account" "mac_tools mail_list_headers --account 'Gmail'" 0 true
test_command "with limit" "mac_tools mail_list_headers --limit 5" 0 true
test_command "with since" "mac_tools mail_list_headers --since '2024-01-01T00:00:00Z'" 0 true
test_command "all params" "mac_tools mail_list_headers --account 'test' --since '2024-01-01T00:00:00Z' --limit 10" 0 true
test_command "dry-run" "mac_tools mail_list_headers --dry-run" 0 true
test_command "zero limit" "mac_tools mail_list_headers --limit 0" 0 true
test_command "high limit" "mac_tools mail_list_headers --limit 1000" 0 true
test_command "help" "mac_tools help mail_list_headers" 0 false
measure_latency "mail_list_headers" "mac_tools mail_list_headers --limit 50" 1.2

print_header "Testing calendar_list (10 tests)"
test_command "valid dates" "mac_tools calendar_list --from '2024-01-01T00:00:00Z' --to '2024-01-02T00:00:00Z'" 0 true
test_command "timezone offset" "mac_tools calendar_list --from '2024-01-01T00:00:00-08:00' --to '2024-01-02T00:00:00-08:00'" 0 true
test_command "same day" "mac_tools calendar_list --from '2024-01-01T00:00:00Z' --to '2024-01-01T23:59:59Z'" 0 true
test_command "dry-run" "mac_tools calendar_list --from '2024-01-01T00:00:00Z' --to '2024-01-02T00:00:00Z' --dry-run" 0 true
test_command "invalid from date" "mac_tools calendar_list --from 'bad-date' --to '2024-01-02T00:00:00Z'" 2 true
test_command "invalid to date" "mac_tools calendar_list --from '2024-01-01T00:00:00Z' --to 'bad-date'" 2 true
test_command "both invalid" "mac_tools calendar_list --from 'bad' --to 'also-bad'" 2 true
test_command "missing T" "mac_tools calendar_list --from '2024-01-01 00:00:00' --to '2024-01-02T00:00:00Z'" 2 true
test_command "help" "mac_tools help calendar_list" 0 false
measure_latency "calendar_list" "mac_tools calendar_list --from '2024-01-01T00:00:00Z' --to '2024-01-02T00:00:00Z'" 1.2

print_header "Testing reminders_create (10 tests)"
test_command "dry-run basic" "mac_tools reminders_create --title 'Test' --dry-run" 0 true
test_command "dry-run with due" "mac_tools reminders_create --title 'Test' --due '2024-12-01T12:00:00Z' --dry-run" 0 true
test_command "dry-run with notes" "mac_tools reminders_create --title 'Test' --notes 'Some notes' --dry-run" 0 true
test_command "dry-run full" "mac_tools reminders_create --title 'Test' --due '2024-12-01T12:00:00Z' --notes 'Notes' --tags '[\"work\"]' --dry-run" 0 true
test_command "create without dry-run" "mac_tools reminders_create --title 'Test Direct'" 0 true
test_command "create with confirm (no dry-run)" "mac_tools reminders_create --title 'Test' --confirm" 2 true
test_command "empty title" "mac_tools reminders_create --title '' --dry-run" 0 true
test_command "long title" "mac_tools reminders_create --title 'Very long title that goes on and on and on' --dry-run" 0 true
test_command "help" "mac_tools help reminders_create" 0 false
measure_latency "reminders_create" "mac_tools reminders_create --title 'Latency Test' --dry-run" 3.0

print_header "Testing notes_append (10 tests)"
test_command "dry-run basic" "mac_tools notes_append --note-id 'test123' --text 'Hello' --dry-run" 0 true
test_command "dry-run long text" "mac_tools notes_append --note-id 'test456' --text 'This is a very long text that should be appended to the note' --dry-run" 0 true
test_command "dry-run empty text" "mac_tools notes_append --note-id 'test789' --text '' --dry-run" 0 true
test_command "dry-run special chars" "mac_tools notes_append --note-id 'test' --text 'Special: !@#\$%^&*()' --dry-run" 0 true
test_command "append without dry-run" "mac_tools notes_append --note-id 'direct' --text 'Direct append'" 0 true
test_command "append with confirm (no dry-run)" "mac_tools notes_append --note-id 'test' --text 'Hello' --confirm" 2 true
test_command "unicode text" "mac_tools notes_append --note-id 'unicode' --text 'Hello 世界 🌍' --dry-run" 0 true
test_command "newlines" "mac_tools notes_append --note-id 'newline' --text 'Line 1\nLine 2' --dry-run" 0 true
test_command "help" "mac_tools help notes_append" 0 false
measure_latency "notes_append" "mac_tools notes_append --note-id 'latency' --text 'Speed test' --dry-run" 3.0

print_header "Testing files_move (10 tests)"
test_command "dry-run basic" "mac_tools files_move --src '/tmp/test.txt' --dst '/tmp/moved.txt' --dry-run" 0 true
test_command "dry-run absolute paths" "mac_tools files_move --src '/Users/test/file.txt' --dst '/Users/test/moved.txt' --dry-run" 0 true
test_command "dry-run different dirs" "mac_tools files_move --src '/tmp/source.txt' --dst '/var/tmp/dest.txt' --dry-run" 0 true
test_command "dry-run same file" "mac_tools files_move --src '/tmp/file.txt' --dst '/tmp/file.txt' --dry-run" 0 true
test_command "move without dry-run" "mac_tools files_move --src '/tmp/direct.txt' --dst '/tmp/direct_moved.txt'" 0 true
test_command "move with confirm (no dry-run)" "mac_tools files_move --src '/tmp/test.txt' --dst '/tmp/moved.txt' --confirm" 2 true
test_command "spaces in paths" "mac_tools files_move --src '/tmp/file with spaces.txt' --dst '/tmp/moved file.txt' --dry-run" 0 true
test_command "long paths" "mac_tools files_move --src '/very/long/path/to/source/file.txt' --dst '/another/very/long/path/to/dest/file.txt' --dry-run" 0 true
test_command "help" "mac_tools help files_move" 0 false
measure_latency "files_move" "mac_tools files_move --src '/tmp/speed.txt' --dst '/tmp/speed_moved.txt' --dry-run" 3.0

print_header "Testing dry-run/confirm workflow"
# Test the dry-run -> confirm workflow
HASH=$(mac_tools reminders_create --title 'Workflow Test' --dry-run | jq -r '.operation_hash')
test_command "confirm after dry-run" "mac_tools reminders_create --title 'Workflow Test' --confirm" 0 true

print_header "Testing logging"
# Verify logs contain required fields
if [ -f ~/Library/Logs/Assistant/tools.ndjson ]; then
    LOG_COUNT=$(wc -l < ~/Library/Logs/Assistant/tools.ndjson)
    if [ "$LOG_COUNT" -gt 0 ]; then
        echo -e "${GREEN}PASS${NC} Logging enabled ($LOG_COUNT entries)"
        ((PASS_COUNT++))
    else
        echo -e "${RED}FAIL${NC} No log entries found"
        ((FAIL_COUNT++))
    fi
    
    # Check log structure
    if tail -1 ~/Library/Logs/Assistant/tools.ndjson | jq -e '.tool and .args and .start_ts and .end_ts and .duration_ms and .host and .version and .dry_run' >/dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC} Log structure valid"
        ((PASS_COUNT++))
    else
        echo -e "${RED}FAIL${NC} Log structure invalid"
        ((FAIL_COUNT++))
    fi
else
    echo -e "${RED}FAIL${NC} Log file not created"
    ((FAIL_COUNT+=2))
fi

print_header "Summary"
ACTUAL_TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo -e "${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "${RED}Failed: $FAIL_COUNT${NC}"
echo -e "Total: $ACTUAL_TOTAL"

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "\n${GREEN}🎉 ALL TESTS PASSED! Week 0 requirements met.${NC}"
    exit 0
else
    echo -e "\n${RED}❌ $FAIL_COUNT tests failed. Week 0 requirements NOT met.${NC}"
    exit 1
fi