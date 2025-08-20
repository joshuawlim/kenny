# Kenny - Personal Assistant

A local-first, macOS-native AI management assistant with reliable tool execution, local memory, strict privacy, and sub-3s latency on common workflows.

## Vision

Kenny is designed to be your personal AI assistant that:
- Runs entirely on your Mac with **no cloud dependencies**
- Integrates deeply with all your macOS apps (Mail, Calendar, Notes, Messages, etc.)
- Provides **deterministic tool execution** with full audit trails
- Maintains **strict privacy** - all data stays on your device
- Delivers **fast responses** (≤1.2s for queries, ≤3s for tool calls)

## Current Status: Week 1-2 Foundation ✅

### What's Working Now

**macOS Tool Layer (`mac_tools`)**
- ✅ 5 JSON-only CLI commands with dry-run/confirm workflow
- ✅ NDJSON logging to `~/Library/Logs/Assistant/tools.ndjson`
- ✅ Performance: P50 ~36ms (well under targets)

**Data Storage Layer** 
- ✅ SQLite + FTS5 database with cross-app relationships
- ✅ Full Apple app data extraction (8 apps)
- ✅ Real-time search across emails, contacts, calendar, files
- ✅ Incremental sync with change detection

**Apple App Integration**
- ✅ **Contacts**: Full CNContactStore with photos, addresses, birthdays
- ✅ **Calendar**: EventKit with attendees, recurrence, timezones  
- ✅ **Mail**: AppleScript extraction with threading and relationships
- ✅ **Messages**: Direct SQLite access to iMessage/SMS history
- ✅ **Files**: Content indexing for Documents/Desktop/Downloads
- ✅ **Notes**: AppleScript extraction with email detection
- ✅ **Reminders**: EventKit with due dates and completion status
- ✅ **WhatsApp**: Database extraction for chat history

## Quick Start

### Installation

```bash
# Clone and build
git clone https://github.com/joshuawlim/kenny.git
cd kenny/mac_tools
swift build --configuration release

# Install CLI tools
sudo cp .build/release/mac_tools /usr/local/bin/
```

### Basic Usage

```bash
# Test the tools
mac_tools version
mac_tools tcc_request --calendar --contacts
mac_tools calendar_list --from "2024-01-01T00:00:00Z" --to "2024-01-31T00:00:00Z"

# Data ingestion (creates ~/Library/Application Support/Assistant/assistant.db)
# This will prompt for permissions to access your apps
swift run db_cli ingest_full

# Search your data
swift run db_cli search "project meeting"
```

## Architecture

```
┌─────────────────┐    ┌──────────────┐    ┌─────────────────┐
│   User Input    │───▶│ Orchestrator │───▶│   Tool Layer    │
│                 │    │ (Future)     │    │   mac_tools     │
└─────────────────┘    └──────────────┘    └─────────────────┘
                              │                       │
                              ▼                       ▼
┌─────────────────┐    ┌──────────────┐    ┌─────────────────┐
│ Local LLM       │    │   Database   │    │  Apple Apps     │
│ (Future)        │◀───│ SQLite+FTS5  │◀───│ Mail/Calendar/  │
│                 │    │              │    │ Notes/Messages  │
└─────────────────┘    └──────────────┘    └─────────────────┘
```

### Tool Layer (`mac_tools`)
JSON-only CLI with 5 commands:
- `mail_list_headers` - Extract email headers
- `calendar_list` - List calendar events  
- `reminders_create` - Create reminders with dry-run
- `notes_append` - Append to notes with confirmation
- `files_move` - Move files with safety checks

### Database Layer
- **SQLite with WAL mode** for concurrent access
- **FTS5 virtual tables** for full-text search with snippets
- **Cross-domain relationships** (emails ↔ contacts ↔ events)
- **Provenance tracking** for every piece of data
- **Incremental sync** with hash-based change detection

### App Integration
Each app has a dedicated ingester:
- `MailIngester` - AppleScript-based email extraction
- `ContactsIngester` - CNContactStore integration
- `CalendarIngester` - EventKit for events and attendees
- `MessagesIngester` - Direct SQLite access to Messages
- `NotesIngester` - AppleScript for Notes.app
- `RemindersIngester` - EventKit for reminders
- `FilesIngester` - FileManager + content extraction
- `WhatsAppIngester` - Database extraction for WhatsApp

## Roadmap: 10-Week Plan

### ✅ Week 1-2: macOS Control + Data Foundation (DONE)
- Tool execution layer with JSON I/O
- SQLite schema with FTS5 search
- Apple app data ingestion

### 🔄 Week 3: Embeddings and Retrieval (NEXT)
- Local embeddings service (e5/nomic)
- Hybrid search (BM25 + embeddings)
- Chunking policy per content type

### Week 4: Local LLM + Function Calling
- Local 7-8B model (Ollama/llama.cpp)
- Function calling with JSON schemas
- Auto-correction for malformed responses

### Week 5: Planner-Executor + Safety
- Plan → Confirm → Execute workflow
- Structured audit logs
- Rollback and compensation

### Week 6: Email & Calendar Concierge
- Meeting scheduling with conflict detection
- RSVP parsing and confirmations
- Time zone handling

### Week 7: Background Jobs + Daily Briefing
- Job queue for maintenance
- 7:30am daily briefing generation
- Follow-up automation

### Week 8: Security & Prompt Injection Defense
- Content origin tagging
- Tool allowlists and confirmations
- Red-team harness

### Week 9: Performance & UX
- Raycast/Alfred integration
- Streaming responses
- Context optimization

### Week 10: Hardening & Packaging
- Signed menubar app
- Crash recovery
- Live demos

## Key Features

### Privacy First
- **100% local processing** - no data leaves your Mac
- **Explicit consent** for all data access
- **Audit logs** for every action taken
- **No network dependencies** except Apple services

### Reliable Tool Execution
- **Dry-run mode** for all mutations
- **Hash-based confirmation** prevents accidental execution
- **Comprehensive error handling** with structured JSON responses
- **Idempotent operations** with rollback support

### Fast & Efficient
- **Sub-second search** across all your data
- **Incremental sync** only processes changes
- **Optimized indexing** with FTS5 and proper SQL indexes
- **Parallel processing** for data ingestion

### Deep macOS Integration
- **Native framework usage** (EventKit, CNContactStore, etc.)
- **AppleScript automation** where needed
- **Direct database access** for maximum performance
- **Respect for app sandboxing** and permissions

## Database Schema

The core `documents` table provides a unified view of all content:

```sql
CREATE TABLE documents (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,           -- 'email', 'contact', 'event', etc.
    title TEXT NOT NULL,
    content TEXT,                 -- Searchable content
    app_source TEXT NOT NULL,     -- 'Mail', 'Contacts', 'Calendar', etc.
    source_id TEXT,              -- App-specific identifier
    source_path TEXT,            -- Deep link back to app
    hash TEXT,                   -- For change detection
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    deleted BOOLEAN DEFAULT FALSE
);
```

Type-specific tables extend this with detailed fields:
- `emails` - Threading, attachments, read status
- `events` - Attendees, location, recurrence
- `contacts` - Phone numbers, addresses, photos
- `messages` - Conversation threads, media
- `files` - File metadata and extracted content

The `relationships` table connects related content across apps:
```sql
-- Example: Email from contact about calendar event
INSERT INTO relationships VALUES (
    'rel-1', 'contact-123', 'email-456', 'sent_email', 1.0, 1672531200
);
```

## File Structure

```
kenny/
├── README.md                 # This file
├── ARCHITECTURE.md           # Detailed architecture
├── contextPerplexity.md      # Original project context
│
├── mac_tools/               # CLI tools
│   ├── Sources/mac_tools/   # Main tool commands
│   ├── src/                 # Database layer
│   ├── migrations/          # Schema migrations
│   └── Package.swift
│
├── scripts/                 # Helper scripts
└── docs/                   # Additional documentation
```

## Development

### Building
```bash
cd mac_tools
swift build --configuration release
```

### Testing
```bash
# Test database schema
swift test_db_simple.swift

# Test real data ingestion (requires permissions)
swift test_real_ingestion.swift

# Performance testing
swift test_performance.swift
```

### Adding New App Integration

1. Create ingester in `src/[App]Ingester.swift`
2. Add to `IngestManager.swift` 
3. Update database schema if needed
4. Add tests

## Performance Targets

- **Tool-free queries**: ≤1.2s average
- **Simple tool calls**: ≤3.0s average  
- **Full data ingest**: ≤15min for 10,000 items
- **Incremental sync**: ≤30s
- **Search queries**: ≤100ms for most queries

Current performance (Week 1-2):
- ✅ Tool calls: ~36ms average
- ✅ Database queries: <1ms for simple searches
- ✅ Bulk ingest: 1000 items in 7ms

## Security Model

### Trust Levels
- **Trusted**: User input, local files owned by user
- **Untrusted**: Email content, external documents
- **Restricted**: Network content, JavaScript in emails

### Guardrails
- Untrusted content cannot invoke tools without confirmation
- All mutations require dry-run + explicit confirmation
- Shell access limited to allowlisted commands
- Network egress disabled by default

### Audit Trail
Every action is logged with:
- Input parameters and tool used
- Output or error details
- Timestamps and duration
- User confirmation events
- Rollback/compensation actions taken

## Contributing

Kenny is currently in active development. The codebase is structured for rapid iteration while maintaining production-quality foundations.

Key principles:
- **Tools over prompts** - Reliability beats cleverness
- **Memory correctness** before model upgrades  
- **Explicit consent** for all actions
- **Local-first** always

## License

[Add license information]

## Next Steps

1. **Try it out**: Follow the Quick Start guide
2. **Grant permissions**: Allow access to Contacts, Calendar, etc.
3. **Run ingestion**: Let Kenny index your data
4. **Search your content**: Try cross-app queries
5. **Follow development**: Watch for Week 3 updates (embeddings + retrieval)