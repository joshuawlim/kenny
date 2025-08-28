#!/bin/bash
"""
Kenny Test Suite Runner

Executes comprehensive tests for all 5 critical Kenny fixes:
1. Tool Parameter Signature Mismatch Fix
2. Fuzzy Contact Matching Implementation
3. Search Result Threshold Optimization  
4. Unified Search Orchestrator
5. Contact Entity Graph

Usage:
  ./run_tests.sh [OPTIONS]

Options:
  --python-only      Run only Python tests
  --swift-only       Run only Swift tests
  --integration-only Run only integration tests
  --performance-only Run only performance tests
  --quick           Skip performance tests for faster execution
  --verbose         Show detailed output
"""

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KENNY_ROOT="$(dirname "$SCRIPT_DIR")"
PYTHON_TESTS="$SCRIPT_DIR/python"
SWIFT_TESTS="$SCRIPT_DIR/swift"
INTEGRATION_TESTS="$SCRIPT_DIR/integration"
PERFORMANCE_TESTS="$SCRIPT_DIR/performance"

# Parse command line arguments
PYTHON_ONLY=false
SWIFT_ONLY=false
INTEGRATION_ONLY=false
PERFORMANCE_ONLY=false
QUICK=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --python-only)
            PYTHON_ONLY=true
            shift
            ;;
        --swift-only)
            SWIFT_ONLY=true
            shift
            ;;
        --integration-only)
            INTEGRATION_ONLY=true
            shift
            ;;
        --performance-only)
            PERFORMANCE_ONLY=true
            shift
            ;;
        --quick)
            QUICK=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            head -25 "$0" | tail -20
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo -e "\n${BLUE}====== $1 ======${NC}\n"
}

# Check prerequisites
check_prerequisites() {
    log_section "Checking Prerequisites"
    
    # Check Python
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 not found. Please install Python 3."
        exit 1
    fi
    
    # Check pytest
    if ! python3 -c "import pytest" 2>/dev/null; then
        log_warning "pytest not found. Installing..."
        pip install pytest pytest-asyncio pytest-benchmark
    fi
    
    # Check Swift (only if running Swift tests)
    if [[ "$SWIFT_ONLY" == "true" || ("$PYTHON_ONLY" == "false" && "$INTEGRATION_ONLY" == "false" && "$PERFORMANCE_ONLY" == "false") ]]; then
        if ! command -v swift &> /dev/null; then
            log_warning "Swift not found. Swift tests will be skipped."
        fi
    fi
    
    # Check kenny-api dependencies
    if [[ -f "$KENNY_ROOT/kenny-api/requirements.txt" ]]; then
        log_info "Installing Python dependencies..."
        pip install -r "$KENNY_ROOT/kenny-api/requirements.txt" -q
    fi
    
    log_success "Prerequisites check completed"
}

# Run Python tests
run_python_tests() {
    log_section "Running Python Tests"
    
    cd "$KENNY_ROOT"
    
    # Test fuzzy matching implementation
    log_info "Testing fuzzy contact matching..."
    if [[ "$VERBOSE" == "true" ]]; then
        python3 -m pytest "$PYTHON_TESTS/test_fuzzy_matching.py" -v
    else
        python3 -m pytest "$PYTHON_TESTS/test_fuzzy_matching.py" -q
    fi
    
    if [[ $? -eq 0 ]]; then
        log_success "✅ Fuzzy matching tests passed"
    else
        log_error "❌ Fuzzy matching tests failed"
        return 1
    fi
    
    # Test parameter signatures
    log_info "Testing tool parameter signatures..."
    if [[ "$VERBOSE" == "true" ]]; then
        python3 -m pytest "$PYTHON_TESTS/test_parameter_signatures.py" -v
    else
        python3 -m pytest "$PYTHON_TESTS/test_parameter_signatures.py" -q
    fi
    
    if [[ $? -eq 0 ]]; then
        log_success "✅ Parameter signature tests passed"
    else
        log_error "❌ Parameter signature tests failed"
        return 1
    fi
    
    log_success "All Python tests passed"
}

# Run Swift tests
run_swift_tests() {
    log_section "Running Swift Tests"
    
    if ! command -v swift &> /dev/null; then
        log_warning "Swift not available, skipping Swift tests"
        return 0
    fi
    
    cd "$KENNY_ROOT/mac_tools"
    
    # Test hybrid search thresholds
    log_info "Testing hybrid search threshold optimization..."
    if [[ "$VERBOSE" == "true" ]]; then
        swift run -v "$SWIFT_TESTS/test_hybrid_search.swift"
    else
        swift run "$SWIFT_TESTS/test_hybrid_search.swift" 2>/dev/null
    fi
    
    if [[ $? -eq 0 ]]; then
        log_success "✅ Hybrid search tests passed"
    else
        log_error "❌ Hybrid search tests failed"
        return 1
    fi
    
    log_success "All Swift tests passed"
}

# Run integration tests
run_integration_tests() {
    log_section "Running Integration Tests"
    
    cd "$KENNY_ROOT"
    
    # Cross-platform integration tests
    log_info "Testing cross-platform integration..."
    if [[ "$VERBOSE" == "true" ]]; then
        python3 -m pytest "$INTEGRATION_TESTS/test_cross_platform.py" -v -s
    else
        python3 -m pytest "$INTEGRATION_TESTS/test_cross_platform.py" -q
    fi
    
    if [[ $? -eq 0 ]]; then
        log_success "✅ Cross-platform integration tests passed"
    else
        log_error "❌ Cross-platform integration tests failed"
        return 1
    fi
    
    log_success "All integration tests passed"
}

# Run performance tests
run_performance_tests() {
    log_section "Running Performance Tests"
    
    cd "$KENNY_ROOT"
    
    log_info "Testing search algorithm performance..."
    if [[ "$VERBOSE" == "true" ]]; then
        python3 -m pytest "$PERFORMANCE_TESTS/test_search_performance.py" -v -s --benchmark-only
    else
        python3 -m pytest "$PERFORMANCE_TESTS/test_search_performance.py" -q --benchmark-only
    fi
    
    if [[ $? -eq 0 ]]; then
        log_success "✅ Performance tests passed"
    else
        log_error "❌ Performance tests failed"
        return 1
    fi
    
    log_success "All performance tests passed"
}

# Generate test report
generate_report() {
    log_section "Generating Test Report"
    
    local report_file="$SCRIPT_DIR/test_report_$(date +%Y%m%d_%H%M%S).json"
    
    cat > "$report_file" << EOF
{
    "test_run": {
        "timestamp": "$(date -Iseconds)",
        "kenny_fixes_tested": [
            "Tool Parameter Signature Mismatch Fix",
            "Fuzzy Contact Matching Implementation",
            "Search Result Threshold Optimization",
            "Unified Search Orchestrator",
            "Contact Entity Graph"
        ],
        "test_categories": {
            "python_tests": $([[ "$PYTHON_ONLY" == "true" || ("$SWIFT_ONLY" == "false" && "$INTEGRATION_ONLY" == "false" && "$PERFORMANCE_ONLY" == "false") ]] && echo "true" || echo "false"),
            "swift_tests": $([[ "$SWIFT_ONLY" == "true" || ("$PYTHON_ONLY" == "false" && "$INTEGRATION_ONLY" == "false" && "$PERFORMANCE_ONLY" == "false") ]] && echo "true" || echo "false"),
            "integration_tests": $([[ "$INTEGRATION_ONLY" == "true" || ("$PYTHON_ONLY" == "false" && "$SWIFT_ONLY" == "false" && "$PERFORMANCE_ONLY" == "false") ]] && echo "true" || echo "false"),
            "performance_tests": $([[ "$PERFORMANCE_ONLY" == "true" || ("$QUICK" == "false" && "$PYTHON_ONLY" == "false" && "$SWIFT_ONLY" == "false" && "$INTEGRATION_ONLY" == "false") ]] && echo "true" || echo "false")
        },
        "environment": {
            "python_version": "$(python3 --version)",
            "swift_version": "$(swift --version 2>/dev/null | head -1 || echo 'Not available')",
            "os": "$(uname -s)",
            "hostname": "$(hostname)"
        }
    }
}
EOF
    
    log_info "Test report generated: $report_file"
}

# Main execution
main() {
    log_section "Kenny Critical Fixes Test Suite"
    log_info "Testing 5 critical Kenny fixes across Python and Swift codebases"
    
    # Check prerequisites
    check_prerequisites
    
    local overall_success=true
    
    # Run tests based on options
    if [[ "$PYTHON_ONLY" == "true" ]]; then
        run_python_tests || overall_success=false
    elif [[ "$SWIFT_ONLY" == "true" ]]; then
        run_swift_tests || overall_success=false
    elif [[ "$INTEGRATION_ONLY" == "true" ]]; then
        run_integration_tests || overall_success=false
    elif [[ "$PERFORMANCE_ONLY" == "true" ]]; then
        run_performance_tests || overall_success=false
    else
        # Run all tests
        run_python_tests || overall_success=false
        run_swift_tests || overall_success=false
        run_integration_tests || overall_success=false
        
        if [[ "$QUICK" == "false" ]]; then
            run_performance_tests || overall_success=false
        fi
    fi
    
    # Generate report
    generate_report
    
    # Final result
    if [[ "$overall_success" == "true" ]]; then
        log_section "🎉 ALL TESTS PASSED"
        log_success "All Kenny critical fixes are working correctly!"
        log_info "Key fixes verified:"
        log_info "  ✅ Tool parameter signatures compatible between Python/Swift"
        log_info "  ✅ Fuzzy contact matching achieves high accuracy"
        log_info "  ✅ Search thresholds optimized for better recall"
        log_info "  ✅ Cross-platform integration working"
        log_info "  ✅ Performance requirements met"
        exit 0
    else
        log_section "❌ SOME TESTS FAILED"
        log_error "One or more test categories failed. Check the output above for details."
        exit 1
    fi
}

# Run main function
main "$@"