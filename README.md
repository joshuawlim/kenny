# Kenny - Personal Assistant

A local-first, macOS-native AI management assistant with reliable tool execution, local memory, strict privacy, and sub-3s latency on common workflows.

## Vision

Kenny is designed to be your personal AI assistant that:
- Runs entirely on your Mac with **no cloud dependencies**
- Integrates deeply with all your macOS apps (Mail, Calendar, Notes, Messages, etc.)
- Provides **deterministic tool execution** with full audit trails
- Maintains **strict privacy** - all data stays on your device
- Delivers **fast responses** (≤1.2s for queries, ≤3s for tool calls)

## Current Status: Week 1-5 Foundation ✅

### What's Working Now (August 2024)

**Week 1-2: macOS Tool Layer & Data Foundation ✅**
- ✅ JSON-only CLI commands with dry-run/confirm workflow
- ✅ SQLite + FTS5 database with cross-app relationships
- ✅ Full Apple app data extraction (8 apps) with incremental sync
- ✅ Performance: P50 ~36ms (well under targets)

**Week 3: Embeddings & Retrieval ✅**
- ✅ Local embeddings service (nomic-embed-text via Ollama)
- ✅ Hybrid search (BM25 + embeddings) with 27ms average latency
- ✅ Content-aware chunking per document type
- ✅ 768-dimension normalized vectors

**Week 4: Assistant Core & Function Calling ✅**
- ✅ Intelligent tool selection from natural language
- ✅ JSON schema validation for all tool parameters
- ✅ Structured error handling and retry logic
- ✅ Deterministic rule-based reasoning (LLM-ready architecture)

**Week 5: Orchestrator & Safety Infrastructure ✅**
- ✅ Central coordination layer for request processing
- ✅ Plan-execute-audit workflow with compensation
- ✅ Structured logging with rotation/retention
- ✅ Real data ingestion (fixed placeholder issues)

### Apple App Integration Status
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
sudo cp .build/release/db_cli /usr/local/bin/
sudo cp .build/release/assistant_core /usr/local/bin/
sudo cp .build/release/orchestrator_cli /usr/local/bin/
```

### Testing Week 1-5 Capabilities

#### 1. Basic Tool Layer Testing
```bash
# Test the core CLI tools
mac_tools version
mac_tools tcc_request --calendar --contacts

# Test individual app integrations
mac_tools calendar_list --from "2024-01-01T00:00:00Z" --to "2024-01-31T00:00:00Z"
mac_tools reminders_create --title "Test reminder" --dry-run
```

#### 2. Database & Ingestion Testing
```bash
# Set up database and permissions
./scripts/setup_database.sh

# Run full data ingestion (requires app permissions)
db_cli ingest_full

# Test search capabilities
db_cli search "project meeting"
db_cli stats
```

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
assistant_core test

# Individual query testing
assistant_core query "show my calendar for today"
assistant_core query "create a reminder to review budget"
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