# Kenny Database Recovery Plan
**Status:** CRITICAL - Database Initialization Failures Blocking Week 6+ Development  
**Date:** August 21, 2025  
**Priority:** P0 - Immediate Attention Required  

## Executive Summary

The Kenny project's database initialization system suffers from **critical SQL parsing failures** that prevent clean database creation and recovery. The root cause lies in the `Database.swift` execute method's inability to properly handle multi-line SQL statements, complex triggers, and SQL comments in migration files. While the bash setup script works correctly, the Swift application fails catastrophically when attempting schema initialization, blocking all testing and development.

## Current State Analysis

### Identified Failure Points

1. **Multi-Line SQL Statement Parsing Failure**
   - **Error**: `ERROR preparing statement: incomplete input`
   - **Location**: Migration 001_initial_schema.sql, lines 204-207
   - **Root Cause**: `Database.execute()` splits on semicolons but doesn't handle multi-line CREATE TRIGGER statements
   - **Code Fragment**:
   ```sql
   CREATE TRIGGER documents_fts_insert AFTER INSERT ON documents BEGIN
       INSERT INTO documents_fts(rowid, title, content, snippet)
       VALUES (new.rowid, new.title, new.content, substr(new.content, 1, 200));
   END;
   ```

2. **SQL Comment Block Parsing Failure**  
   - **Error**: `ERROR executing statement: not an error`
   - **Location**: Migration 003_add_embeddings.sql, lines 57-64
   - **Root Cause**: Multi-line comment `/* ... */` creates invalid statement when parsed
   - **Code Fragment**:
   ```sql
   /*
   CREATE FUNCTION cosine_similarity(a BLOB, b BLOB) RETURNS REAL AS
   BEGIN
       -- This would be implemented in application code
       RETURN 0.0;
   END;
   */
   ```

3. **Migration Path Resolution Inconsistency**
   - **Issue**: Swift code searches multiple paths for migration files
   - **Fragility**: Hard-coded fallback to `/Users/joshwlim/Documents/Kenny/mac_tools/migrations`
   - **Risk**: Breaks in different environments or when project structure changes

4. **Non-Idempotent Schema Creation**
   - **Issue**: Some CREATE statements lack `IF NOT EXISTS` clauses
   - **Result**: Cannot safely re-run initialization on existing databases
   - **Impact**: No clean recovery path from partial failures

### Configuration Issues

1. **WAL Mode Initialization Timing**
   - Current order: Open DB → Setup WAL → Run migrations
   - Risk: WAL setup might interfere with schema creation in edge cases

2. **Foreign Key Enforcement**
   - Enabled immediately with `PRAGMA foreign_keys = ON`
   - Risk: May prevent schema creation if tables are created out of dependency order

## Proposed Schema Creation Order

### Phase 1: Database Initialization (Idempotent)
```sql
-- 1.1 Core Configuration
PRAGMA foreign_keys = OFF;  -- Temporarily disable during schema creation
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA mmap_size = 268435456;

-- 1.2 Schema Version Tracking
CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at INTEGER NOT NULL
);
```

### Phase 2: Core Tables (Dependency-Ordered)
```sql
-- 2.1 Root table (no dependencies)
CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    title TEXT NOT NULL,
    content TEXT,
    app_source TEXT NOT NULL,
    source_id TEXT,
    source_path TEXT,
    hash TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    deleted BOOLEAN DEFAULT FALSE,
    metadata_json TEXT,
    UNIQUE(app_source, source_id)
);

-- 2.2 Dependent tables (reference documents.id)
CREATE TABLE IF NOT EXISTS emails (
    document_id TEXT PRIMARY KEY REFERENCES documents(id),
    thread_id TEXT,
    message_id TEXT UNIQUE,
    from_address TEXT,
    -- ... rest of columns
);

CREATE TABLE IF NOT EXISTS messages (
    document_id TEXT PRIMARY KEY REFERENCES documents(id),
    thread_id TEXT,
    -- ... rest of columns  
);

-- Continue for all dependent tables...
```

### Phase 3: Indexes and Optimization
```sql
-- 3.1 Primary indexes
CREATE INDEX IF NOT EXISTS idx_documents_type ON documents(type);
CREATE INDEX IF NOT EXISTS idx_documents_updated ON documents(updated_at);
CREATE INDEX IF NOT EXISTS idx_documents_hash ON documents(hash);

-- 3.2 Foreign key indexes
CREATE INDEX IF NOT EXISTS idx_emails_thread ON emails(thread_id);
CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id);

-- Continue for all indexes...
```

### Phase 4: FTS5 Virtual Tables
```sql
-- 4.1 Documents FTS
CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
    title,
    content,
    snippet,
    content='documents',
    content_rowid='rowid'
);

-- 4.2 Emails FTS  
CREATE VIRTUAL TABLE IF NOT EXISTS emails_fts USING fts5(
    from_name,
    from_address,
    subject,
    snippet,
    content='emails',
    content_rowid='rowid'
);
```

### Phase 5: Triggers (After FTS Tables Exist)
```sql
-- 5.1 Documents FTS Triggers
DROP TRIGGER IF EXISTS documents_fts_insert;
CREATE TRIGGER documents_fts_insert AFTER INSERT ON documents 
BEGIN
    INSERT INTO documents_fts(rowid, title, content, snippet)
    VALUES (new.rowid, new.title, new.content, substr(new.content, 1, 200));
END;

DROP TRIGGER IF EXISTS documents_fts_delete;
CREATE TRIGGER documents_fts_delete AFTER DELETE ON documents 
BEGIN
    INSERT INTO documents_fts(documents_fts, rowid, title, content, snippet)
    VALUES ('delete', old.rowid, old.title, old.content, substr(old.content, 1, 200));
END;

DROP TRIGGER IF EXISTS documents_fts_update;
CREATE TRIGGER documents_fts_update AFTER UPDATE ON documents 
BEGIN
    INSERT INTO documents_fts(documents_fts, rowid, title, content, snippet)
    VALUES ('delete', old.rowid, old.title, old.content, substr(old.content, 1, 200));
    INSERT INTO documents_fts(rowid, title, content, snippet)
    VALUES (new.rowid, new.title, new.content, substr(new.content, 1, 200));
END;
```

### Phase 6: Finalization
```sql
-- 6.1 Re-enable foreign keys
PRAGMA foreign_keys = ON;

-- 6.2 Update schema version
INSERT OR REPLACE INTO schema_migrations (version, applied_at) 
VALUES (3, strftime('%s', 'now'));
```

## FTS5 Implementation Strategy

### Virtual Table Configuration Rationale

1. **Content Tables**: Use `content='table_name'` pattern for external content
   - **Benefit**: Reduces storage overhead by not duplicating content
   - **Trade-off**: Requires careful trigger management for synchronization

2. **Rowid Mapping**: Use `content_rowid='rowid'` for proper linkage  
   - **Critical**: Must match the referenced table's rowid column exactly
   - **Validation**: Test with `SELECT rowid FROM table LIMIT 1` after creation

3. **Column Selection**: Include only searchable text fields in FTS
   - **documents_fts**: title, content, snippet  
   - **emails_fts**: from_name, from_address, subject, snippet
   - **Avoid**: IDs, timestamps, numeric fields (not useful for full-text search)

### Trigger Synchronization Strategy

1. **Drop-and-Recreate Pattern**: Always drop triggers before creating
   - **Safety**: Prevents "trigger already exists" errors
   - **Idempotency**: Enables safe re-runs during recovery

2. **Three-Trigger Pattern**: INSERT, DELETE, UPDATE
   - **INSERT**: Direct insertion into FTS table
   - **DELETE**: Use special 'delete' command to remove from FTS  
   - **UPDATE**: Delete old + insert new (ensures complete refresh)

3. **Error Handling**: FTS operations can fail silently
   - **Validation**: After trigger creation, test with sample INSERT/UPDATE/DELETE
   - **Recovery**: If FTS becomes inconsistent, use `INSERT INTO fts_table(fts_table) VALUES('rebuild')`

### FTS5 Rebuild and Optimization

1. **Manual Rebuild Command**:
```sql
INSERT INTO documents_fts(documents_fts) VALUES('rebuild');
INSERT INTO emails_fts(emails_fts) VALUES('rebuild');
```

2. **Optimization Command**:
```sql  
INSERT INTO documents_fts(documents_fts) VALUES('optimize');
INSERT INTO emails_fts(emails_fts) VALUES('optimize');
```

3. **When to Rebuild**:
   - After bulk data imports
   - If search results seem inconsistent
   - After schema migrations that affect FTS content

## Migration Framework Design

### Forward-Only Migration Convention

1. **File Naming**: `XXX_descriptive_name.sql` where XXX is zero-padded version
2. **Content Structure**:
```sql
-- Migration: Brief description
-- Version: XXX  
-- Description: Detailed explanation of changes

-- DDL statements here (idempotent with IF NOT EXISTS/OR REPLACE)
```

3. **Version Tracking**:
```sql
-- At end of each migration:
INSERT INTO schema_migrations (version, applied_at) 
VALUES (XXX, strftime('%s', 'now'));
```

### Idempotent Schema Creation Scripts

1. **Table Creation**: Always use `CREATE TABLE IF NOT EXISTS`
2. **Index Creation**: Always use `CREATE INDEX IF NOT EXISTS`  
3. **Trigger Creation**: Always use `DROP TRIGGER IF EXISTS` followed by `CREATE TRIGGER`
4. **View Creation**: Always use `CREATE VIEW IF NOT EXISTS`

### Migration State Verification

1. **Pre-Migration Check**:
```sql
SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1;
```

2. **Post-Migration Verification**:
```sql
-- Verify table exists and has expected columns
PRAGMA table_info(documents);

-- Verify indexes exist
SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='documents';

-- Verify FTS tables are queryable
SELECT count(*) FROM documents_fts;

-- Verify triggers exist
SELECT name FROM sqlite_master WHERE type='trigger';
```

## Verification Plan

### Component Verification Commands

1. **Schema Structure Verification**:
```bash
# Verify all core tables exist
sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('documents', 'chunks', 'embeddings');"

# Expected: documents chunks embeddings (3 rows)
```

2. **Index Verification**:
```bash
# Verify indexes exist
sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%';" | wc -l

# Expected: 42+ indexes (current count from working setup)
```

3. **FTS5 Table Verification**:
```bash
# Verify FTS tables are created and functional
sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%_fts';"

# Expected: documents_fts emails_fts (2 rows)

# Test FTS functionality
sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM documents_fts;"
# Should not error (even if 0 results)
```

4. **Trigger Verification**:
```bash
# Verify triggers exist
sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='trigger';"

# Expected: documents_fts_insert documents_fts_delete documents_fts_update
```

5. **Foreign Key Verification**:  
```bash
# Verify foreign keys are enabled and working
sqlite3 "$DB_PATH" "PRAGMA foreign_keys; PRAGMA foreign_key_check;"

# Expected: 1 (enabled), empty result (no violations)
```

### Sanity Queries for Data Integrity

1. **Basic Schema Sanity**:
```sql
-- Test basic table operations
INSERT INTO documents (id, type, title, content, app_source, created_at, updated_at, last_seen_at)
VALUES ('test-doc-1', 'note', 'Test Document', 'This is test content', 'TestApp', 1692633600, 1692633600, 1692633600);

SELECT id, title FROM documents WHERE id = 'test-doc-1';
-- Expected: test-doc-1 | Test Document

DELETE FROM documents WHERE id = 'test-doc-1';
-- Should complete without error
```

2. **FTS Integration Sanity**:
```sql
-- Test FTS triggers work
INSERT INTO documents (id, type, title, content, app_source, created_at, updated_at, last_seen_at)
VALUES ('fts-test-1', 'note', 'FTS Test Document', 'This document tests full-text search functionality', 'TestApp', 1692633600, 1692633600, 1692633600);

-- Verify FTS insertion happened
SELECT COUNT(*) FROM documents_fts WHERE documents_fts MATCH 'full-text';
-- Expected: 1

-- Test FTS search  
SELECT d.title FROM documents_fts JOIN documents d ON documents_fts.rowid = d.rowid WHERE documents_fts MATCH 'functionality';
-- Expected: FTS Test Document

-- Cleanup
DELETE FROM documents WHERE id = 'fts-test-1';
SELECT COUNT(*) FROM documents_fts WHERE documents_fts MATCH 'full-text';  
-- Expected: 0 (deletion trigger worked)
```

## Test Scenarios

### Scenario 1: Cold Start from Empty Database

**Purpose**: Verify complete schema creation from scratch  
**Prerequisites**: Non-existent or empty database file  
**Steps**:
```bash
# Remove existing database
rm -f "$DB_PATH" "$DB_PATH"-shm "$DB_PATH"-wal

# Run initialization
bash scripts/setup_database.sh "$DB_PATH"

# Verify success
sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';"
# Expected: 20+ tables

sqlite3 "$DB_PATH" "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1;"  
# Expected: 3
```

**Success Criteria**:
- ✅ No errors during setup
- ✅ All core tables exist (documents, chunks, embeddings)  
- ✅ FTS tables are queryable
- ✅ Schema version = 3
- ✅ All verification queries pass

### Scenario 2: Re-initialization Over Existing Database

**Purpose**: Test idempotent behavior and safe re-runs  
**Prerequisites**: Existing database with partial or complete schema  
**Steps**:
```bash
# Create initial database
bash scripts/setup_database.sh "$DB_PATH"

# Add some test data
sqlite3 "$DB_PATH" "INSERT INTO documents (...) VALUES (...);"

# Re-run setup (should be safe)
bash scripts/setup_database.sh "$DB_PATH"

# Verify data preservation and schema completeness
sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM documents;"
# Expected: Still has test data
```

**Success Criteria**:
- ✅ No errors on re-run
- ✅ Existing data preserved  
- ✅ Schema fully up-to-date
- ✅ No duplicate tables/indexes/triggers

### Scenario 3: Migration from Partial State (Version 1)

**Purpose**: Test migration system from older schema versions  
**Prerequisites**: Database with only version 1 schema  
**Steps**:
```bash
# Create version 1 database manually
sqlite3 "$DB_PATH" < mac_tools/migrations/001_initial_schema.sql

# Verify current version
sqlite3 "$DB_PATH" "SELECT MAX(version) FROM schema_migrations;"  
# Expected: 1

# Run full setup to migrate to version 3
bash scripts/setup_database.sh "$DB_PATH"

# Verify migration completed
sqlite3 "$DB_PATH" "SELECT MAX(version) FROM schema_migrations;"
# Expected: 3

sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('chunks', 'embeddings');"
# Expected: chunks embeddings (from version 3)
```

**Success Criteria**:
- ✅ Successfully migrates from v1 to v3
- ✅ All v3 features available (chunks, embeddings)
- ✅ No data loss from v1 tables

### Scenario 4: Recovery from Corrupted State

**Purpose**: Test recovery when database is partially corrupted or inconsistent  
**Prerequisites**: Database with missing tables or broken FTS  
**Steps**:
```bash
# Create corrupted state (missing FTS tables)
sqlite3 "$DB_PATH" "DROP TABLE IF EXISTS documents_fts;"
sqlite3 "$DB_PATH" "DROP TABLE IF EXISTS emails_fts;"

# Verify corruption
sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%_fts';"
# Expected: Empty (no FTS tables)

# Attempt recovery
bash scripts/setup_database.sh "$DB_PATH"

# Verify recovery  
sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%_fts';"
# Expected: documents_fts emails_fts
```

**Success Criteria**:
- ✅ Missing components are recreated
- ✅ FTS search functionality restored
- ✅ Existing data remains intact

## Code Fixes Required

### 1. Database.swift execute() Method Enhancement

**Problem**: Cannot handle multi-line SQL statements  
**Location**: `/mac_tools/src/Database.swift:50-76`  
**Solution**: Replace statement splitting logic

```swift
// CURRENT (BROKEN):
let statements = sql.components(separatedBy: ";")
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }

// REPLACEMENT (FIXED):
private func parseSQL(_ sql: String) -> [String] {
    var statements: [String] = []
    var current = ""
    var inString = false
    var inComment = false
    var stringChar: Character?
    
    let lines = sql.components(separatedBy: .newlines)
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        
        // Skip single-line comments  
        if trimmed.hasPrefix("--") { continue }
        
        // Skip empty lines
        if trimmed.isEmpty { continue }
        
        // Handle multi-line comments
        if trimmed.hasPrefix("/*") {
            inComment = true
            continue
        }
        if trimmed.hasSuffix("*/") {
            inComment = false  
            continue
        }
        if inComment { continue }
        
        current += line + "\n"
        
        // Check for statement terminator (semicolon at end of line)
        if trimmed.hasSuffix(";") && !inString {
            statements.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
        }
    }
    
    // Add final statement if exists
    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        statements.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    return statements
}
```

### 2. Migration File Cleaning

**Problem**: Migration files contain unparseable SQL comments  
**Location**: `/mac_tools/migrations/003_add_embeddings.sql:55-64`  
**Solution**: Remove or comment out the SQL function documentation

```sql
-- REMOVE THESE LINES FROM 003_add_embeddings.sql:
-- Function to calculate cosine similarity (stored as SQL for reference)
-- Note: Actual similarity calculation will be done in Swift for performance
/*
CREATE FUNCTION cosine_similarity(a BLOB, b BLOB) RETURNS REAL AS
BEGIN
    -- This would be implemented in application code
    -- Stored here for documentation purposes
    RETURN 0.0;
END;
*/

-- REPLACE WITH:
-- Function to calculate cosine similarity 
-- Note: Actual similarity calculation is implemented in Database.swift cosineSimilarity() method
-- This function would be created here if SQLite supported user-defined functions
```

### 3. Migration Path Resolution Fix  

**Problem**: Brittle path resolution with hard-coded fallbacks  
**Location**: `/mac_tools/src/Database.swift:436-474`  
**Solution**: Standardize on single, reliable path resolution

```swift
private func getProjectRoot() -> String {
    // Priority order for finding migrations:
    // 1. Environment variable (for deployment flexibility)  
    // 2. Standard project structure (mac_tools/migrations)
    // 3. Current directory fallback
    
    if let envPath = ProcessInfo.processInfo.environment["KENNY_MIGRATIONS_PATH"] {
        if FileManager.default.fileExists(atPath: envPath) {
            return (envPath as NSString).deletingLastPathComponent
        }
    }
    
    let currentDir = FileManager.default.currentDirectoryPath
    let standardPath = (currentDir as NSString).appendingPathComponent("mac_tools/migrations")
    
    if FileManager.default.fileExists(atPath: standardPath) {
        return (standardPath as NSString).deletingLastPathComponent
    }
    
    // Final fallback - assume we're already in mac_tools
    let localPath = (currentDir as NSString).appendingPathComponent("migrations")  
    if FileManager.default.fileExists(atPath: localPath) {
        return currentDir
    }
    
    fatalError("Could not locate migrations directory. Set KENNY_MIGRATIONS_PATH environment variable or ensure mac_tools/migrations exists.")
}
```

### 4. Enhanced Error Messages

**Problem**: Generic "Failed to create basic schema" doesn't indicate root cause  
**Location**: Various points in Database.swift migration logic  
**Solution**: Provide specific error context

```swift
// CURRENT (UNHELPFUL):
print("CRITICAL: Basic schema creation failed")

// REPLACEMENT (INFORMATIVE):
print("CRITICAL: Schema creation failed at statement:")
print("  Statement: \(statement)")  
print("  SQLite Error: \(String(cString: sqlite3_errmsg(db)))")
print("  Migration File: \(migrationFile)")
print("  Suggested Fix: Check SQL syntax for multi-line statements and comments")
```

## Risk Assessment and Mitigation

### High-Risk Areas

1. **FTS5 Virtual Table Dependencies**
   - **Risk**: FTS tables created before content tables exist
   - **Mitigation**: Strict dependency ordering in schema creation
   - **Verification**: Test FTS table creation in isolation

2. **Trigger Creation Race Conditions**  
   - **Risk**: Triggers reference non-existent FTS tables  
   - **Mitigation**: Create triggers only after all tables exist
   - **Verification**: Test trigger functionality with sample data

3. **Foreign Key Constraint Violations**
   - **Risk**: Circular dependencies prevent table creation
   - **Mitigation**: Disable foreign keys during schema creation
   - **Recovery**: Clear dependency resolution order

4. **WAL Mode Compatibility**
   - **Risk**: WAL mode conflicts with schema modifications
   - **Mitigation**: Set WAL mode early, before schema creation
   - **Testing**: Verify works across SQLite versions

### Mitigation Strategies

1. **Atomic Schema Creation**: Wrap entire schema creation in transaction
2. **Detailed Logging**: Log every DDL statement before execution  
3. **Staged Rollout**: Test each migration phase independently
4. **Backup Strategy**: Automatically backup database before any schema changes
5. **Environment Validation**: Verify SQLite version supports all features used

## Success Metrics

### Immediate Success (Week 5 Recovery)

- [ ] `bash scripts/setup_database.sh` completes without errors
- [ ] `swift run db_cli init` completes without fatal errors  
- [ ] Database contains all expected tables (documents, chunks, embeddings)
- [ ] FTS5 search returns results for test queries
- [ ] All verification queries pass without errors

### Long-term Success (Week 6+ Enablement)

- [ ] Database supports full ingestion of 1000+ documents without corruption
- [ ] Search performance meets targets (<1.2s for complex queries)  
- [ ] Schema migrations apply cleanly in production environments
- [ ] Zero data loss during schema updates or recovery procedures
- [ ] Database initialization is deterministic across development machines

## Implementation Priority

### P0 (Critical Path - Complete First)
1. Fix SQL parsing in Database.swift execute() method
2. Clean migration files of problematic SQL comments
3. Test cold start database creation

### P1 (Essential - Complete Before Week 6)  
1. Implement idempotent schema creation
2. Add detailed error logging and recovery messages
3. Create automated verification test suite

### P2 (Important - Complete During Week 6)
1. Enhance migration path resolution
2. Add database backup before schema changes  
3. Performance test with realistic data volumes

### P3 (Nice to Have - Background Priority)
1. Add schema validation commands to CLI
2. Create database recovery utilities
3. Implement automated corruption detection

This recovery plan provides a comprehensive path to resolve the database initialization failures and establish a robust foundation for Kenny's continued development. The critical path items must be completed before any Week 6+ work can proceed reliably.