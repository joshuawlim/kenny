# Kenny - Personal Assistant

A local-first, macOS-native AI management assistant with reliable tool execution, local memory, strict privacy, and sub-3s latency on common workflows.

## Vision

Kenny is designed to be your personal AI assistant that:
- Runs entirely on your Mac with **no cloud dependencies**
- Integrates deeply with all your macOS apps (Mail, Calendar, Notes, Messages, etc.)
- Provides **deterministic tool execution** with full audit trails
- Maintains **strict privacy** - all data stays on your device
- Delivers **fast responses** (≤1.2s for queries, ≤3s for tool calls)

## Current Status: Week 5 CRITICAL ISSUES ❌

### 🚨 CRITICAL ISSUES DISCOVERED (August 21, 2025)

During Week 5 validation with real user data, fundamental system failures were discovered:

**❌ Data Ingestion Completely Broken:**
- Expected: 5,495+ emails, 30,102+ messages, hundreds of contacts
- Actual: 0 emails, 19 messages, 1 event, 0 contacts, 0 files
- Root Cause: Date filtering bugs exclude all recent data

**❌ Search System Non-Functional:**
- All searches return 0 results despite data in database
- Cannot find "Courtney", "Mrs Jacobs", "spa" from visible user data
- Root Cause: Documents created with empty titles/content

**❌ Database Migration Failures:**
- "Failed to create basic schema" prevents testing fixes
- System cannot restart with clean database

### What Was Claimed Working (Now Invalid)

**Week 1-2: macOS Tool Layer & Data Foundation ❌**
- ✅ JSON-only CLI commands with dry-run/confirm workflow
- ❌ SQLite + FTS5 database (schema migrations broken)
- ❌ Full Apple app data extraction (ingesters broken)
- ❌ Performance claims invalid (tested with minimal/synthetic data)

**Week 3: Embeddings & Retrieval ❌**
- ✅ Local embeddings service (nomic-embed-text via Ollama)
- ❌ Hybrid search meaningless without data ingestion
- ❌ Content-aware chunking not tested with real data
- ❌ Vector processing irrelevant without searchable content

**Week 4: Assistant Core & Function Calling ❌**
- ✅ Tool selection logic exists
- ❌ Cannot test with real data due to ingestion failures
- ❌ Error handling untested in real scenarios
- ❌ Architecture unusable without data layer

**Week 5: Orchestrator & Safety Infrastructure ❌**
- ❌ Cannot orchestrate without functional data retrieval
- ❌ Plan-execute workflow untested with real data
- ❌ Real data ingestion completely broken

### Apple App Integration Status (Actual)
- ❌ **Contacts**: Ingester finds 0 contacts (should be dozens)
- ❌ **Calendar**: Only 1 event ingested (should be many more)
- ❌ **Mail**: 0 emails ingested (user has 5,495+ emails visible)
- ❌ **Messages**: 19 messages ingested (should be 30,102+)
- ❌ **Files**: 0 files ingested (should be hundreds)
- ❌ **Notes**: 0 notes ingested
- ❌ **Reminders**: 0 reminders ingested
- ❌ **WhatsApp**: Creating empty records instead of real chat data

### Real Data Available (Confirmed)
- **Messages Database**: 30,102 messages at `~/Library/Messages/chat.db`
- **Mail App**: 5,495+ emails visible in Primary inbox
- **Contacts**: "Courtney", "Mrs Jacobs" and others visible in screenshots
- **WhatsApp/iMessage**: Active conversations with family groups visible

## Quick Start

### Installation

```bash
# Clone and build
git clone https://github.com/joshuawlim/kenny.git
cd kenny/mac_tools
swift build --configuration release

# Install CLI tools
sudo cp .build/release/mac_tools /usr/local/bin/
sudo cp .build/release/db_cli /usr/local/bin/
sudo cp .build/release/assistant_core /usr/local/bin/
sudo cp .build/release/orchestrator_cli /usr/local/bin/
```

### Testing Week 1-5 Capabilities

**Note**: Run all commands from the Kenny root directory (not inside mac_tools/)

#### 1. Basic Tool Layer Testing
```bash
# Test the core CLI tools
mac_tools/.build/release/mac_tools --version
mac_tools/.build/release/mac_tools tcc_request --calendar --contacts

# Test individual app integrations (note: calendar_list is placeholder, use database search)
mac_tools/.build/release/mac_tools reminders_create --title "Test reminder" --dry-run
mac_tools/.build/release/mac_tools tcc_request --calendar --reminders  # Request permissions first
```

#### 2. Database & Ingestion Testing ❌ BROKEN
```bash
# ❌ Database initialization fails with "Failed to create basic schema"
./scripts/setup_database.sh  # FAILS

# ✅ Permission requests work
mac_tools/.build/release/mac_tools tcc_request --calendar --contacts --reminders

# ❌ Ingestion fails to find real data
mac_tools/.build/release/db_cli ingest_full  # Returns "Error" or silent failure

# ❌ Search returns 0 results despite data existing
mac_tools/.build/release/db_cli search "Courtney"  # Should find messages, returns 0
mac_tools/.build/release/db_cli search "spa"       # Should find "spa by 3" message, returns 0  
mac_tools/.build/release/db_cli search "Mrs Jacobs" # Should find emails, returns 0
mac_tools/.build/release/db_cli stats  # Shows 0 emails, 19 messages, 1 event (should be thousands)
```

**Current Status**: System finds virtually no user data despite thousands of items being available.

#### 3. Embeddings & Hybrid Search Testing
```bash
# Set up Ollama and embeddings model
./scripts/setup_embeddings.sh

# Generate embeddings for your data
./scripts/ingest_embeddings.sh

# Test hybrid search (BM25 + embeddings)
./scripts/hybrid_search.sh "email about budget"
```

#### 4. Assistant Core Testing
```bash
# Test natural language to tool selection
mac_tools/.build/release/assistant_core test

# Individual query testing
mac_tools/.build/release/assistant_core query "show my calendar for today"
mac_tools/.build/release/assistant_core query "create a reminder to review budget"
```

#### 5. Orchestrator Testing
```bash
# Test request coordination
orchestrator_cli search --query "team meeting" --hybrid
orchestrator_cli ingest --sources mail,calendar --full-sync
orchestrator_cli status
```

### Database Location
- **Main database**: `~/Library/Application Support/Assistant/assistant.db`
- **Logs**: `~/.kenny/logs/` (with automatic rotation)
- **Cache**: `~/Library/Caches/Assistant/`

## Architecture

```
┌─────────────────┐    ┌──────────────┐    ┌─────────────────┐
│   User Input    │───▶│ Orchestrator │───▶│   Tool Layer    │
│                 │    │ (Week 5)     │    │   mac_tools     │
└─────────────────┘    └──────────────┘    └─────────────────┘
                              │                       │
                              ▼                       ▼
┌─────────────────┐    ┌──────────────┐    ┌─────────────────┐
│ Local LLM       │    │   Database   │    │  Apple Apps     │
│ (Week 6+)       │◀───│ SQLite+FTS5  │◀───│ Mail/Calendar/  │
│                 │    │ +Embeddings  │    │ Notes/Messages  │
└─────────────────┘    └──────────────┘    └─────────────────┘
```

### Core Components

**Tool Layer (`mac_tools`)**
- JSON-only CLI with 7 commands covering major workflows
- Dry-run and confirmation safety mechanisms
- Performance: P50 ~36ms, P95 ~58ms

**Database Layer**
- SQLite with WAL mode for concurrent access
- FTS5 virtual tables for full-text search with snippets
- Vector embeddings table for semantic search
- Cross-domain relationships (emails ↔ contacts ↔ events)
- Incremental sync with hash-based change detection

**Orchestrator Layer (Week 5)**
- Central request routing and coordination
- Plan → Execute → Audit workflow
- Background job processing
- Structured logging with rotation

**Assistant Core (Week 4)**
- Natural language to tool mapping
- JSON schema validation
- Intelligent retry and error handling

## Roadmap: Weeks 6-10

### 🔄 Week 6: Email & Calendar Concierge (NEXT)
- Meeting scheduling with conflict detection
- RSVP parsing and automatic confirmations
- Time zone handling and calendar integration
- Email-based workflow automation

### Week 7: Background Jobs + Daily Briefing
- Cron-like job scheduling system
- 7:30am daily briefing generation
- Follow-up automation and reminders
- Maintenance job queue

### Week 8: Security & Prompt Injection Defense
- Content origin tagging and validation
- Tool allowlists and user confirmations
- Red-team harness for security testing
- Audit trail forensics

### Week 9: Performance & UX Polish
- Raycast/Alfred integration
- Sub-500ms query optimization
- Memory usage optimization
- Advanced caching strategies

### Week 10: Mobile Companion & Deployment
- iOS companion app for remote triggers
- Deployment automation and updates
- Production hardening
- Documentation and user onboarding

## Repository Structure

```
kenny/
├── README.md                    # This file
├── ARCHITECTURE.md              # Detailed technical architecture
├── CHANGELOG.md                 # Version history
├── docs/                        # Documentation
│   ├── status/                  # Weekly status reports
│   ├── README_EMBEDDINGS.md     # Embeddings setup guide
│   └── contextPerplexity.md     # Development context
├── mac_tools/                   # Core Swift package
│   ├── Package.swift            # Swift package definition
│   ├── Sources/                 # CLI entry points
│   ├── src/                     # Core implementation
│   ├── migrations/              # Database schema
│   └── scripts/                 # Build and test scripts
├── scripts/                     # Setup and maintenance scripts
├── tests/                       # Integration tests
│   └── integration/             # End-to-end test suites
└── tools/                       # External integrations
    ├── whatsapp/                # WhatsApp logger
    └── whatsapp-mcp/            # WhatsApp MCP server
```

## Performance Benchmarks

- **Tool execution**: P50 36ms, P95 58ms (target: <100ms)
- **Database queries**: P50 12ms, P95 28ms
- **Embedding generation**: P50 27ms (target: <100ms)
- **Hybrid search**: P50 45ms (target: <200ms)
- **Full data ingest**: ~2-5 minutes (depends on data volume)

## Development

### Prerequisites
- macOS 13+ with Xcode Command Line Tools
- Swift 5.9+
- Ollama (for embeddings)
- SQLite 3.x

### Building
```bash
cd mac_tools
swift build --configuration release
swift test  # Run unit tests
```

### Contributing
See [ARCHITECTURE.md](ARCHITECTURE.md) for technical details and development guidelines.

## Privacy & Security

- **100% local**: All data processing happens on your Mac
- **No network calls**: Except to local Ollama instance
- **Encrypted storage**: Database files use macOS file-level encryption
- **Audit logging**: Complete trail of all operations
- **Permission-based**: Uses standard macOS permission dialogs

## License

MIT License - see LICENSE file for details.

---

**Status**: Week 1-5 Complete ✅ | **Next**: Week 6 Email & Calendar Concierge