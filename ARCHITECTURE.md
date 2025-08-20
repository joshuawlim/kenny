# Kenny Architecture

This document describes the technical architecture of Kenny, a local-first personal AI assistant for macOS.

## Design Principles

1. **Local-First**: All processing happens on-device with no cloud dependencies
2. **Privacy-Preserving**: User data never leaves the Mac except through explicit user actions
3. **Deterministic**: All operations are reproducible and auditable
4. **Fast**: Sub-3s response times for common workflows
5. **Reliable**: 90%+ success rate on canonical workflows

## System Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Kenny Personal Assistant                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐ │
│  │      CLI        │  │   Orchestrator  │  │     Background Jobs     │ │
│  │   Interface     │◀─┤   (Future)      │─▶│   Ingest, Cleanup,      │ │
│  │                 │  │                 │  │   Daily Briefing        │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────────────┘ │
│           │                      │                         │            │
│           ▼                      ▼                         ▼            │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐ │
│  │   Tool Layer    │  │  Local LLM      │  │    Job Scheduler        │ │
│  │   mac_tools     │  │  (Future)       │  │    (Future)             │ │
│  │                 │  │                 │  │                         │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────────────┘ │
│           │                      │                         │            │
│           ▼                      ▼                         ▼            │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                      Data & Search Layer                            │ │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌───────────────────┐   │ │
│  │  │   SQLite DB     │  │      FTS5       │  │   Relationships   │   │ │
│  │  │   + WAL Mode    │◀─┤   Full-Text     │◀─┤     Graph         │   │ │
│  │  │                 │  │     Search      │  │                   │   │ │
│  │  └─────────────────┘  └─────────────────┘  └───────────────────┘   │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│           │                      │                         │            │
│           ▼                      ▼                         ▼            │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                      Apple App Integration                          │ │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────────┐   │ │
│  │  │  Mail   │ │Calendar │ │Contacts │ │Messages │ │ Notes/Files │   │ │
│  │  │AppleScrp│ │EventKit │ │CNContact│ │SQLite DB│ │  AppleScript│   │ │
│  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────────┘   │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

## Layer Details

### 1. Tool Layer (`mac_tools`)

The tool layer provides the interface between the AI system and macOS applications. It's implemented as a Swift CLI with 5 core commands.

**Key Features:**
- JSON-only input/output for deterministic parsing
- Dry-run mode for all mutating operations
- Hash-based confirmation to prevent accidental execution
- Comprehensive NDJSON logging
- Sub-100ms latency for most operations

**Commands:**
```bash
mac_tools mail_list_headers --account "Gmail" --limit 50
mac_tools calendar_list --from "2024-01-01T00:00:00Z" --to "2024-12-31T23:59:59Z"
mac_tools reminders_create --title "Call dentist" --due "2024-02-01T10:00:00Z" --dry-run
mac_tools notes_append --note-id "ABC123" --text "New insight..." --confirm
mac_tools files_move --src "/tmp/report.pdf" --dst "~/Documents/" --dry-run
```

**Dry-Run/Confirm Flow:**
```
1. User: mac_tools reminders_create --title "Task" --dry-run
2. Tool: {"dry_run": true, "operation_hash": "abc123", "would_create": {...}}
3. User: mac_tools reminders_create --title "Task" --confirm  
4. Tool: Validates hash exists within 5min window, then executes
```

### 2. Data & Search Layer

The data layer uses SQLite with FTS5 for fast, local search across all user content.

**Database Design:**
```sql
-- Unified document model
documents (id, type, title, content, app_source, source_id, hash, timestamps)
  
-- App-specific extensions  
emails (document_id, from_address, thread_id, attachments, ...)
events (document_id, start_time, attendees, location, ...)
contacts (document_id, phone_numbers, addresses, ...)
messages (document_id, thread_id, service, is_from_me, ...)
files (document_id, file_path, mime_type, extracted_content, ...)
notes (document_id, folder, word_count, ...)
reminders (document_id, due_date, is_completed, priority, ...)

-- Cross-app relationships
relationships (from_document_id, to_document_id, type, strength)
```

**FTS5 Integration:**
```sql
-- Virtual table for full-text search
CREATE VIRTUAL TABLE documents_fts USING fts5(
    title, content, snippet,
    content='documents',
    content_rowid='rowid'
);

-- Search with snippets
SELECT d.title, snippet(documents_fts, 1, '<mark>', '</mark>', '...', 32)
FROM documents_fts 
JOIN documents d ON documents_fts.rowid = d.rowid
WHERE documents_fts MATCH 'project meeting calendar'
ORDER BY bm25(documents_fts);
```

**Performance Optimizations:**
- WAL mode for concurrent reads during writes
- Strategic indexes on common query patterns
- Memory-mapped I/O (256MB mmap_size)
- Incremental sync using content hashes

### 3. Apple App Integration

Each macOS app requires a different integration approach based on available APIs.

**Integration Matrix:**

| App | Method | API | Access Level |
|-----|--------|-----|-------------|
| Contacts | Native | CNContactStore | Full |
| Calendar | Native | EventKit | Full |
| Reminders | Native | EventKit | Full |
| Mail | Script | AppleScript | Read-only |
| Notes | Script | AppleScript | Read-only |
| Messages | Direct | SQLite DB | Read-only |
| Files | Native | FileManager | Full |
| WhatsApp | Direct | SQLite DB | Read-only |

**Ingester Architecture:**
```swift
protocol AppIngester {
    func ingestData(isFullSync: Bool, since: Date?) async throws -> IngestStats
}

// Example: Contacts
class ContactsIngester: AppIngester {
    func ingestData(isFullSync: Bool, since: Date?) async throws -> IngestStats {
        // 1. Request permissions
        // 2. Fetch contacts using CNContactStore  
        // 3. Extract searchable content
        // 4. Insert to documents + contacts tables
        // 5. Create relationships with emails/messages
        // 6. Return statistics
    }
}
```

**Change Detection:**
- Content hashes for detecting modifications
- Timestamps for incremental sync windows
- Tombstone records for deletions
- Provenance tracking for audit trails

### 4. Security & Privacy Model

**Trust Levels:**
```
TRUSTED     - User input, local files owned by user
UNTRUSTED   - Email content, web downloads, external docs  
RESTRICTED  - Network content, executable code
```

**Permission Model:**
- Request minimal permissions needed
- Explicit user confirmation for mutations
- Audit log for all data access
- No network egress except Apple services

**Guardrails:**
```swift
// Untrusted content cannot invoke tools
if contentOrigin == .untrusted && action.isMutating {
    throw SecurityError.confirmationRequired
}

// All mutations require dry-run first
if !dryRunHashExists(operationHash) && action.isMutating {
    throw ValidationError.dryRunRequired  
}
```

### 5. Logging & Audit

**Tool Execution Logs:** `~/Library/Logs/Assistant/tools.ndjson`
```json
{
  "tool": "reminders_create",
  "args": {"title": "Call dentist", "due": "2024-02-01T10:00:00Z"},
  "result": {"created": true, "reminder_id": "ABC123"},
  "error": null,
  "start_ts": "2024-01-15T10:30:00Z",
  "end_ts": "2024-01-15T10:30:02Z", 
  "duration_ms": 2000,
  "host": "MacBook-Pro.local",
  "version": "0.0.1",
  "dry_run": false,
  "confirmed": true
}
```

**Data Ingestion Logs:** `~/Library/Logs/Assistant/ingest.ndjson`
```json
{
  "job_type": "full_ingest",
  "source": "contacts", 
  "items_processed": 150,
  "items_created": 145,
  "items_updated": 5,
  "errors": 0,
  "duration_ms": 500,
  "timestamp": 1705320600
}
```

## Data Flow Examples

### 1. Cross-App Search Query
```
User: "Find emails about project meetings"

1. Parse query → "project meetings"
2. FTS5 search: documents_fts MATCH "project meetings" 
3. Filter: type IN ('email', 'event', 'message')
4. Join: documents + emails for email-specific fields
5. Rank: BM25 + recency boost
6. Return: snippets with highlights + deep links
```

### 2. Email → Reminder Creation
```
User: "Create reminder from this email"

1. Extract: email content, subject, sender
2. Parse: due date heuristics ("next Friday", "by EOD")
3. Plan: {"intent": "create_reminder", "title": "...", "due": "..."}
4. Confirm: Show plan, wait for user approval
5. Execute: mac_tools reminders_create --confirm
6. Link: Create relationship email ↔ reminder
7. Audit: Log full execution chain
```

### 3. Incremental Data Sync
```
Background Job: Every 15 minutes

1. Query: last_ingest_times per app from jobs table
2. For each app:
   - Get items modified since last run
   - Calculate content hashes  
   - Skip unchanged items
   - Update modified items
   - Mark deleted items as tombstones
3. Update: FTS5 indexes for changed content
4. Log: Sync statistics and errors
```

## Future Architecture (Week 3-10)

### Local LLM Integration
```swift
struct LLMConfig {
    let modelPath: String          // Local .gguf file
    let contextWindow: Int         // 8K tokens
    let temperature: Float         // 0.1 for deterministic tools
    let stopSequences: [String]    // JSON completion markers
}

// Function calling with strict schemas
let tools = [
    "reminders_create": ReminderCreateSchema,
    "calendar_list": CalendarListSchema,
    "search_content": SearchContentSchema
]
```

### Orchestrator (Plan → Confirm → Execute)
```swift
struct ExecutionPlan {
    let id: String
    let steps: [PlanStep]
    let preconditions: [String]
    let affectedObjects: [String]
    let rollbackPlan: [PlanStep]
    let estimatedDuration: TimeInterval
}

struct PlanStep {
    let tool: String
    let arguments: [String: Any]
    let expectedOutput: JSONSchema
    let riskLevel: RiskLevel
}
```

### Background Job System
```swift
enum JobType {
    case ingestFull(sources: [AppSource])
    case ingestIncremental(since: Date)
    case dailyBriefing(time: Date)
    case cleanup(olderThan: Date)
    case maintenance
}

struct Job {
    let id: String
    let type: JobType
    let scheduledFor: Date
    let maxAttempts: Int
    let payload: [String: Any]
}
```

## Performance Characteristics

### Current (Week 1-2)
- Tool execution: 36ms average (P50)
- Database queries: <1ms for simple searches
- Full text search: <10ms for 10K documents
- Data ingestion: 1000 items in 7ms

### Targets (Week 10)
- Tool-free queries: ≤1.2s average
- Simple tool calls: ≤3s average  
- Daily briefing: ≤3s total
- Full ingest: ≤15min for 10K items
- Incremental sync: ≤30s

### Optimization Strategies
- Prepared statements for common queries
- Connection pooling for high-frequency operations
- Batch operations for bulk ingestion
- Lazy loading for large result sets
- Caching for frequently accessed data

## Error Handling & Recovery

### Error Categories
```swift
enum KennyError {
    case permissionDenied(app: String)
    case dataCorruption(source: String)
    case networkUnavailable
    case toolExecutionFailed(tool: String, reason: String)
    case planValidationFailed(issues: [String])
    case confirmationTimeout
}
```

### Recovery Strategies
- Automatic retry with exponential backoff
- Graceful degradation when apps unavailable  
- Rollback mechanisms for failed operations
- User notification for manual intervention
- Comprehensive error logging for debugging

## Testing Strategy

### Unit Tests
- Database operations and schema migrations
- Individual app ingesters
- Search query parsing and execution
- Tool command validation

### Integration Tests  
- End-to-end data ingestion workflows
- Cross-app relationship building
- Permission request handling
- Error scenarios and recovery

### Performance Tests
- Bulk data ingestion benchmarks
- Search latency under load
- Concurrent access patterns
- Memory usage profiling

This architecture is designed to scale from the current Week 1-2 implementation through the full 10-week roadmap while maintaining the core principles of privacy, reliability, and performance.