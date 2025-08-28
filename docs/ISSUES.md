# Kenny System Issues Log

## Current Issues

### ISSUE #14: LLM Query Enhancement Timeout
**Severity**: High
**Component**: QueryEnhancementService
**Description**: LLM query enhancement consistently times out with 500ms limit
**Symptoms**:
- "LLM query enhancement failed, falling back to basic NLP: timeout"
- NSURLErrorDomain Code=-999 "cancelled" errors
- Ollama takes 1.3+ seconds to respond, but timeout is 500ms
**Impact**: AI-powered query enhancement always falls back to basic NLP
**Root Cause**: 500ms timeout is too aggressive for local LLM inference
**Fix Required**: Increase timeout to 2-3 seconds for realistic local LLM performance
**Created**: August 27, 2025

### ISSUE #10: Database Locking - Critical Issue
**Severity**: CRITICAL
**Component**: Database operations across all ingestion tools
**Description**: Multiple database locking errors preventing data ingestion
**Symptoms**:
- `orchestrator_cli ingest --full-sync` fails with "database is locked" errors
- `comprehensive_ingest.py` shows repeated database lock failures during Calendar ingestion
- Database operations fail with "ERROR executing statement 1: database is locked"
**Impact**: Complete failure of data ingestion pipeline, system unusable for updates
**Root Cause**: WAL mode database being accessed by multiple processes simultaneously without proper connection management
**Files Affected**: 
- `orchestrator_cli` (all ingestion commands)
- `comprehensive_ingest.py`
- Database connection handling in Swift code
**Count**: Hundreds of database lock failures observed
**Status**: NEEDS IMMEDIATE ATTENTION - System cannot ingest new data
**Created**: August 26, 2025

### ISSUE #11: Build Warnings - Code Quality
**Severity**: Medium
**Component**: Swift build system
**Description**: Extensive warnings during build process affecting code maintainability
**Symptoms**: 39 compiler warnings including:
- Unused variable warnings (39+ instances)
- String interpolation of optional values (multiple files)
- Non-sendable type captures in @Sendable closures
- Deprecated API usage (`launchApplication` in MailIngester.swift, NotesIngester.swift)
- Unreachable catch blocks in OrchestratorCLI.swift
**Impact**: Code quality degradation, potential runtime issues, maintenance difficulty
**Files Affected**: Most Swift source files in `/src/` directory
**Count**: 39+ warnings across multiple categories
**Status**: Needs cleanup for production readiness
**Created**: August 26, 2025

### ISSUE #12: Database Statistics Discrepancy
**Severity**: Medium  
**Component**: Database reporting and documentation consistency
**Description**: Inconsistent document counts between different reporting methods
**Symptoms**:
- README.md claims 234,411 total documents
- `orchestrator_cli status` reports 234,828 total documents  
- `db_cli stats` reports only 57,545 total documents
- Different database paths being used (`/Library/Application Support/Assistant/assistant.db` vs `kenny.db`)
**Impact**: Unclear system state, potential data integrity questions, monitoring unreliable
**Root Cause**: Tools accessing different databases or using different counting methods
**Status**: Requires investigation and standardization
**Created**: August 26, 2025

### ISSUE #13: Meeting Concierge Empty Results
**Severity**: Low
**Component**: Meeting analysis functionality
**Description**: Meeting analysis commands return no results
**Symptoms**:
- `orchestrator_cli meeting analyze-threads --since-days 7` returns "Found 0 meeting threads"
- May indicate no recent email threads requiring meeting coordination, or search logic issues
**Impact**: Meeting Concierge feature appears non-functional for testing
**Status**: Needs verification if this is expected behavior or actual issue
**Created**: August 26, 2025

### ISSUE #8: Semantic Scoring Integration  
**Severity**: Low
**Component**: Hybrid search scoring
**Description**: BM25 scores working (0.4-1.0), embedding scores showing 0 in some cases
**Impact**: Hybrid search functional but not optimally weighted for all documents
**Status**: Fixed dimension mismatch (768/1536), but may need further optimization
**Created**: August 26, 2025
**Last Updated**: August 26, 2025

### ISSUE #9: Advanced Context Features
**Severity**: Low (Enhancement)
**Component**: Week 7 Context Awareness  
**Description**: Foundation complete, advanced features ready for implementation
**Available Features**:
- Cross-conversation context linking
- Temporal conversation analysis
- Contact relationship mapping  
- Dynamic context windows
**Status**: Ready for implementation in next development phase
**Created**: August 26, 2025

## Resolved Issues Archive

All previously resolved issues (Database Location Confusion, Schema Issues, Email Data Coverage, Embeddings Pipeline, Hybrid Search, NLP Processing, Meeting Concierge) have been moved to HANDOFF.md for historical reference.