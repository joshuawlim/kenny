# Kenny Database Schema Triage Session
**Date:** August 21, 2025  
**Session Type:** Database Schema Recovery Analysis  
**Status:** Analysis Complete - Critical Issues Identified  

## Session Overview

Conducted comprehensive analysis of Kenny's database initialization failures. The project has been blocked by "Failed to create basic schema" errors that prevent clean database startup and testing of ingestion fixes. Investigation revealed fundamental SQL parsing issues in the Swift Database class that prevent proper schema initialization.

## Key Decisions Made

### Database Initialization Strategy
- **Decision**: Multi-phase schema creation with strict dependency ordering
- **Rationale**: Current approach attempts to run complex migration files through broken SQL parser
- **Implementation**: Phase 1 (config) → Phase 2 (tables) → Phase 3 (indexes) → Phase 4 (FTS) → Phase 5 (triggers) → Phase 6 (finalization)

### SQL Parsing Architecture  
- **Decision**: Replace naive semicolon-splitting with proper SQL statement parser
- **Rationale**: Multi-line CREATE TRIGGER statements and SQL comments break current parsing logic
- **Critical Fix**: Must handle multi-line statements, SQL comments, and proper statement boundaries

### Migration File Cleanup
- **Decision**: Remove unparseable SQL documentation comments from migration files
- **Rationale**: Multi-line `/* ... */` comments in 003_add_embeddings.sql cause parsing failures
- **Approach**: Convert to standard `--` comments or remove entirely

### FTS5 Implementation Pattern
- **Decision**: Use external content tables with careful trigger synchronization
- **Rationale**: Reduces storage overhead but requires robust trigger management
- **Key Pattern**: Drop-and-recreate triggers to ensure idempotency

### Error Handling Enhancement
- **Decision**: Replace generic error messages with specific diagnostic information
- **Rationale**: "Failed to create basic schema" provides no actionable debugging info
- **Implementation**: Include specific SQL statement, SQLite error, migration file context

## Technical Findings

### Root Cause Analysis

1. **Primary Failure**: `Database.execute()` method cannot parse multi-line SQL statements
   - **Specific Error**: `ERROR preparing statement: incomplete input`
   - **Location**: Lines 204-207 in 001_initial_schema.sql (CREATE TRIGGER statements)
   - **Impact**: All trigger creation fails, FTS system non-functional

2. **Secondary Failure**: SQL comment blocks create invalid statements  
   - **Specific Error**: `ERROR executing statement: not an error`
   - **Location**: Lines 57-64 in 003_add_embeddings.sql (cosine_similarity documentation)
   - **Impact**: Migration 3 partially fails, embeddings system unstable

3. **Tertiary Issue**: Non-idempotent schema creation prevents recovery
   - **Issue**: Missing `IF NOT EXISTS` clauses on some DDL statements
   - **Impact**: Cannot safely re-run initialization after partial failures

### Working Components Identified

- **Bash Setup Script**: `scripts/setup_database.sh` works correctly when run directly
- **Core Table Structure**: Schema design is sound, FTS5 configuration is appropriate
- **Swift CLI Framework**: DatabaseCLI compiles and runs, issue is in Database core class
- **Migration File Organization**: Numbering scheme and file structure are correct

### Performance Impact

- **Current State**: Database initialization fails completely, blocking all testing
- **Expected Recovery Time**: 2-4 hours to implement critical fixes
- **Testing Requirements**: All 4 test scenarios must pass before marking as resolved

## Risks Identified

### Critical Risks (P0)
1. **Development Blockage**: Cannot test any ingestion fixes until database initializes
2. **Data Loss Potential**: Non-idempotent schema creation could corrupt existing test data
3. **Environment Fragility**: Hard-coded paths break in different deployment environments

### High Risks (P1)  
1. **FTS Search Failure**: Broken triggers mean search returns 0 results even with good data
2. **Migration System Fragility**: Future schema changes will fail with current SQL parser
3. **Silent Failures**: Poor error messages hide root causes of initialization problems

### Medium Risks (P2)
1. **Performance Degradation**: Inefficient schema creation order could slow startup
2. **Maintenance Burden**: Complex recovery procedures needed for common failures
3. **Testing Gaps**: Cannot validate schema correctness without working initialization

## Open Questions

### Technical Clarification Needed
1. **SQLite Version Compatibility**: Which minimum SQLite version must be supported? (Affects FTS5 features available)
2. **WAL Mode Timing**: Should WAL be enabled before or after schema creation? (Current: after, but timing may matter)
3. **Foreign Key Strategy**: Is temporary disable/re-enable safe, or should we use deferred foreign keys?

### Architecture Decisions Required
1. **Migration Rollback Strategy**: Should we implement backward migration capability, or stick to forward-only?
2. **Schema Validation Framework**: Do we need automated schema consistency checks, or rely on manual verification?
3. **Error Recovery Automation**: Should database corruption auto-trigger rebuild, or require manual intervention?

### Testing Strategy Questions  
1. **Real Data Testing**: Should schema recovery be tested with actual user data, or synthetic data sufficient?
2. **Cross-Platform Compatibility**: Does schema work identically on different macOS versions?
3. **Concurrent Access**: How does schema initialization behave with multiple processes accessing database?

## Next Actions (Priority Order)

### Immediate Actions (Complete Before Any Other Work)
1. **Fix SQL Parser**: Implement proper multi-line statement parsing in Database.swift execute() method
2. **Clean Migration Files**: Remove problematic SQL comments from 003_add_embeddings.sql  
3. **Test Cold Start**: Verify `swift run db_cli init` works end-to-end
4. **Verify FTS**: Confirm FTS5 tables are created and triggers work correctly

### Short-term Actions (Complete This Week)
1. **Add Idempotency**: Ensure all DDL statements use IF NOT EXISTS pattern
2. **Enhance Error Messages**: Provide specific context for all schema creation failures
3. **Implement Test Suite**: All 4 recovery scenarios must pass automatically  
4. **Document Recovery Procedures**: Clear instructions for common failure modes

### Medium-term Actions (Complete During Week 6)
1. **Path Resolution Hardening**: Remove hard-coded paths, use environment variables
2. **Performance Optimization**: Measure and optimize schema creation time
3. **Backup Integration**: Auto-backup before any schema modifications
4. **Cross-environment Testing**: Verify works on different development machines

## Implementation Notes

### Code Changes Required
- **Database.swift**: Replace execute() method with proper SQL parser (~50 lines)
- **003_add_embeddings.sql**: Remove lines 57-64 (SQL function documentation)  
- **All migration files**: Add IF NOT EXISTS to CREATE statements where missing
- **Error handling**: Add specific error context throughout migration system

### Testing Strategy
- **Unit Tests**: Each phase of schema creation must be testable independently
- **Integration Tests**: All 4 recovery scenarios automated in test suite
- **Performance Tests**: Schema creation must complete under 5 seconds
- **Regression Tests**: Existing functionality preserved after fixes

### Risk Mitigation Applied
- **Atomic Operations**: Wrap schema creation in transactions where possible
- **Detailed Logging**: Every DDL statement logged before execution
- **Graceful Degradation**: Partial failures should not corrupt existing data  
- **Clear Recovery Path**: Every error condition has documented resolution procedure

## Session Outcome

Successfully diagnosed the root cause of Kenny's database initialization failures. The issue is **not** in the schema design or SQLite configuration, but in the Swift application's inability to properly parse complex SQL statements from migration files. 

**Critical Path Forward**: Fix the SQL parser in Database.swift, clean the migration files, and implement proper error handling. All other database-related development is blocked until these core parsing issues are resolved.

**Confidence Level**: High - root causes clearly identified with specific fixes mapped out. Recovery plan provides deterministic path to working database initialization within 2-4 hours of focused development effort.

---

*Next session: Implementation of SQL parser fixes and validation of recovery procedures*