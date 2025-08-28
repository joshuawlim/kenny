# Kenny Test Suite

Comprehensive test suite for the 5 critical Kenny fixes, covering both Python (kenny-api) and Swift (mac_tools) codebases.

## Test Structure

```
tests/
├── python/                 # Python kenny-api tests
│   ├── test_fuzzy_matching.py
│   ├── test_parameter_signatures.py  
│   └── test_contact_search.py
├── swift/                  # Swift mac_tools tests
│   ├── test_hybrid_search.swift
│   ├── test_unified_orchestrator.swift
│   └── test_contact_entity_graph.swift
├── integration/            # Cross-system integration tests
│   ├── test_cross_platform.py
│   └── test_tool_compatibility.py
├── performance/            # Performance and load tests
│   ├── test_search_performance.py
│   └── test_threshold_optimization.py
└── e2e/                   # End-to-end workflow tests
    └── test_search_workflows.py
```

## Fixes Under Test

### 1. Tool Parameter Signature Mismatch Fix
- **Files**: `main.py`, `ollama_kenny.py`
- **Tests**: `test_parameter_signatures.py`
- **Coverage**: Parameter compatibility, error handling, function signatures

### 2. Fuzzy Contact Matching Implementation  
- **Files**: `ollama_kenny.py`, `requirements.txt`
- **Tests**: `test_fuzzy_matching.py`, `test_contact_search.py`
- **Coverage**: Algorithm correctness, performance, edge cases

### 3. Search Result Threshold Optimization
- **Files**: `HybridSearch.swift`
- **Tests**: `test_hybrid_search.swift`, `test_threshold_optimization.py`
- **Coverage**: Threshold logic, performance impact, result quality

### 4. Unified Search Orchestrator
- **Files**: `UnifiedSearchOrchestrator.swift` 
- **Tests**: `test_unified_orchestrator.swift`, `test_cross_platform.py`
- **Coverage**: Architecture, integration points, error handling

### 5. Contact Entity Graph
- **Files**: `ContactEntityGraph.swift`
- **Tests**: `test_contact_entity_graph.swift`
- **Coverage**: Graph algorithms, database schema, performance

## Running Tests

### Prerequisites
```bash
# Install Python dependencies
pip install -r kenny-api/requirements.txt
pip install pytest pytest-asyncio pytest-benchmark

# Ensure Swift toolchain is available
swift --version
```

### Run All Tests
```bash
# Run complete test suite
./run_tests.sh

# Run specific test categories
./run_tests.sh --python-only
./run_tests.sh --swift-only  
./run_tests.sh --integration-only
./run_tests.sh --performance-only
```

### Individual Test Files
```bash
# Python tests
pytest tests/python/test_fuzzy_matching.py -v
pytest tests/python/test_parameter_signatures.py -v

# Swift tests  
swift test --filter test_hybrid_search
swift test --filter test_unified_orchestrator

# Performance tests
pytest tests/performance/ --benchmark-only
```

## Test Data Requirements

Tests use controlled test data to ensure reproducibility:

- **Contact Test Data**: 100+ synthetic contact records with known variations
- **Search Test Data**: 1000+ synthetic documents across all sources
- **Integration Test Data**: Cross-platform contact mappings and conversation threads
- **Performance Test Data**: Scaled datasets (10K, 50K, 100K records) for load testing

## Success Criteria

### Functional Tests
- ✅ All parameter signatures are compatible between Python and Swift
- ✅ Fuzzy matching achieves >95% accuracy on known test cases
- ✅ Search thresholds return results for 100% of valid queries
- ✅ Unified orchestrator handles all error conditions gracefully
- ✅ Contact entity graph maintains referential integrity

### Performance Tests
- ✅ Fuzzy matching processes 1000 names in <1 second
- ✅ Hybrid search returns results in <500ms for 95th percentile
- ✅ Unified orchestrator completes searches in <2 seconds
- ✅ Contact graph queries scale linearly with dataset size
- ✅ Progressive threshold fallback improves recall by >20%

### Integration Tests
- ✅ Cross-platform contact resolution works end-to-end
- ✅ Tool parameter compatibility verified across all functions
- ✅ Search orchestrator handles all 3 search paths correctly
- ✅ Error handling works consistently across Python/Swift boundary

## Issue Tracking

Each test file includes detailed error reporting and performance metrics. Failed tests generate:

1. **Detailed error logs** with stack traces and context
2. **Performance metrics** showing regression points
3. **Data dumps** of failing test cases for debugging
4. **Recommendations** for fixes based on test analysis

## Continuous Integration

Tests are designed for CI/CD integration with:
- Parallel execution support
- Detailed reporting in JSON format
- Performance regression detection
- Automated failure notifications
- Coverage reporting for both Python and Swift code