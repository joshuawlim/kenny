# mac_tools

A Swift command-line tool for deterministic macOS automation with JSON I/O, providing controlled access to Mail, Calendar, Reminders, Notes, Files, and Messages ingestion.

## Features

- **Pure JSON I/O**: All commands output structured JSON with no extraneous text
- **Dry-run/Confirm Pattern**: All mutating operations require explicit confirmation
- **Comprehensive Logging**: NDJSON logging with performance metrics
- **TCC Permission Management**: Proactive permission requesting and validation
- **Deterministic Output**: Consistent, sorted results for reliable automation
- **Bulk Data Ingestion**: High-performance batch processing for Messages and other data sources
- **Full-Text Search**: FTS5-powered search across ingested Messages with sub-25ms response times

## Requirements

- macOS 14.0+
- Swift 5.9+
- Xcode 15.0+ (for building)

## Installation

### Build from Source

```bash
git clone <repository-url>
cd mac_tools
swift build -c release
```

The binary will be available at `.build/release/mac_tools`.

### First Run Setup

1. **Grant Permissions**: Run the TCC request command to proactively request permissions:
```bash
./mac_tools tcc_request --all
```

2. **Manual Permission Steps**:
   - **Calendar & Reminders**: Automatically requested by the tool
   - **Mail & Notes**: Require manual approval via System Settings → Privacy & Security
   - **Files**: Granted through file access dialogs or Full Disk Access

## Commands

### Calendar

List calendar events within a date range:

```bash
# List all events for the next week
./mac_tools calendar_list

# List events for specific date range
./mac_tools calendar_list --from=$(date -u +"%Y-%m-%dT%H:%M:%SZ") --to=$(date -u -v+7d +"%Y-%m-%dT%H:%M:%SZ")

# Filter by specific calendars
./mac_tools calendar_list --calendars='["Work","Personal"]'
```

**Output Example:**
```json
{
  "events": [
    {
      "id": "event-123",
      "calendar_id": "calendar-456",
      "title": "Team Meeting",
      "start": "2024-01-15T10:00:00Z",
      "end": "2024-01-15T11:00:00Z",
      "all_day": false,
      "location": "Conference Room A",
      "attendees": [
        {"name": "John Doe", "email": "john@example.com", "status": "accepted"}
      ],
      "last_modified": "2024-01-10T15:30:00Z"
    }
  ]
}
```

### Mail

List mail message headers (no message bodies):

```bash
# List recent messages
./mac_tools mail_list_headers --limit=10

# Filter by account and date
./mac_tools mail_list_headers --account="Work" --since=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ") --limit=50
```

**Output Example:**
```json
{
  "messages": [
    {
      "id": "message-789",
      "account": "Work",
      "mailbox": "INBOX",
      "from": {"name": "Jane Smith", "email": "jane@company.com"},
      "to": [{"name": "You", "email": "you@company.com"}],
      "subject": "Project Update",
      "date": "2024-01-15T14:30:00Z",
      "thread_id": null,
      "snippet": "The project is progressing well..."
    }
  ]
}
```

### Reminders

Create reminders with dry-run/confirm pattern:

```bash
# Step 1: Dry run to see what would be created
./mac_tools reminders_create --title="Buy groceries" --due=$(date -u -v+3d +"%Y-%m-%dT18:00:00Z") --dry-run

# Step 2: Confirm with the plan hash from dry run
./mac_tools reminders_create --title="Buy groceries" --due=$(date -u -v+3d +"%Y-%m-%dT18:00:00Z") --confirm --plan-hash="abc123..."
```

**Dry Run Output:**
```json
{
  "dry_run": true,
  "plan_hash": "a1b2c3d4e5f6...",
  "intent": "create_reminder",
  "args": {
    "title": "Buy groceries",
    "due": "$(date -u -v+3d +\"%Y-%m-%dT18:00:00Z\")"
  }
}
```

**Confirm Output:**
```json
{
  "dry_run": false,
  "plan_hash": "a1b2c3d4e5f6...",
  "reminder": {
    "id": "reminder-456",
    "title": "Buy groceries",
    "due": "$(date -u -v+3d +\"%Y-%m-%dT18:00:00Z\")",
    "list": "Reminders",
    "created_at": "2024-01-15T16:45:00Z"
  }
}
```

### Notes

Append text to existing notes:

```bash
# Step 1: Dry run
./mac_tools notes_append --note-id="note-123" --text="New entry: Meeting notes" --dry-run

# Step 2: Confirm
./mac_tools notes_append --note-id="note-123" --text="New entry: Meeting notes" --confirm --plan-hash="def456..."
```

### Files

Move files with collision detection:

```bash
# Step 1: Dry run
./mac_tools files_move --src="/path/to/source.txt" --dst="/path/to/destination.txt" --dry-run

# Step 2: Confirm (with optional overwrite)
./mac_tools files_move --src="/path/to/source.txt" --dst="/path/to/destination.txt" --confirm --plan-hash="ghi789..." --overwrite
```

### Messages Ingestion

Bulk ingest Messages data from Apple's chat.db with configurable batch processing:

```bash
# Basic Messages ingestion
./mac_tools db_cli ingest messages

# Bulk ingestion with custom batch size
./mac_tools db_cli ingest messages --batch-size=1000 --max-messages=50000

# Search ingested Messages (FTS5-powered)
./mac_tools db_cli search "search term" --db-path=kenny.db
```

**Performance Metrics:**
- Processes 26,000+ messages in seconds
- Configurable batch sizes (default: 500 messages per batch)
- Transaction isolation prevents data loss on failures
- Sub-25ms search response times with FTS5 indexing

### TCC Permissions

Request system permissions:

```bash
# Request all permissions
./mac_tools tcc_request --all

# Request specific permissions
./mac_tools tcc_request --calendar --reminders --notes
```

## Global Options

All commands support these global options:

- `--log-file PATH`: Custom log file path (default: `~/Library/Logs/Assistant/tools.ndjson`)
- `--tz TIMEZONE`: IANA timezone identifier (default: system timezone)
- `--now ISO8601`: Override current time for testing
- `--json-schema-strict`: Reject unknown JSON fields
- `--version`: Show version information
- `--help`: Show help information

## Error Handling

All errors are returned as JSON with structured error codes:

```json
{
  "error": {
    "code": "TCC_NOT_GRANTED",
    "message": "Permission not granted for Calendar. Please grant access in System Settings > Privacy & Security",
    "details": {}
  }
}
```

**Error Codes:**
- `TCC_NOT_GRANTED`: Permission not granted for required service
- `VALIDATION_ERROR`: Invalid input parameters or data
- `RUNTIME_ERROR`: Unexpected runtime error
- `ARG_ERROR`: Invalid command arguments

## Logging

All operations are logged to NDJSON format with performance metrics:

```json
{
  "tool": "calendar_list",
  "args": {"from": "$(date -u +\"%Y-%m-%dT%H:%M:%SZ\")", "to": "$(date -u -v+31d +\"%Y-%m-%dT%H:%M:%SZ\")"},
  "result": {"events": [...]},
  "error": null,
  "start_ts": "2024-01-15T10:00:00.123Z",
  "end_ts": "2024-01-15T10:00:01.456Z",
  "duration_ms": 1333,
  "host": {"machine": "MacBook-Pro", "os": "macOS 14.2", "app_ver": "1.0.0"},
  "dry_run": false,
  "confirmed": false,
  "plan_hash": null
}
```

## Performance

### Benchmarks

Target performance thresholds on M-series Macs:
- **List commands**: ≤ 1.2s P50 latency
- **Mutate commands**: ≤ 3.0s P50 latency

Run performance tests:
```bash
./scripts/latency.sh
```

### Optimization Notes

- EventKit operations are cached when possible
- AppleScript bridges are optimized for minimal overhead
- JSON parsing uses stream processing for large datasets
- File operations use FileManager for optimal performance

## Testing

### Smoke Tests

Verify basic functionality and JSON compliance:
```bash
./scripts/smoke.sh
```

### Latency Tests

Measure performance across 20 runs:
```bash
./scripts/latency.sh --report
```

## Known Limitations

1. **Mail Bodies**: Only headers are accessible; message bodies require additional permissions
2. **Complex Mail Search**: Basic filtering only; no full-text search capabilities
3. **Notes Search**: Cannot search notes by content; requires note ID
4. **Calendar Complexity**: Recurring events are returned as individual instances
5. **Background Operation**: No daemon mode; each command is stateless

## Security

- All text input is sanitized to remove HTML/scripts
- AppleScript outputs are treated as untrusted and parsed strictly
- File operations use secure-scoped URLs when available
- No network operations are performed
- Logging excludes sensitive data

## Troubleshooting

### Permission Issues

1. **Calendar/Reminders**: Run `tcc_request --calendar --reminders`
2. **Mail**: Go to System Settings → Privacy & Security → Automation → Terminal → Mail
3. **Notes**: Go to System Settings → Privacy & Security → Automation → Terminal → Notes
4. **Files**: Consider enabling Full Disk Access for broader file system access

### Performance Issues

1. **Slow Calendar Queries**: Reduce date range or filter by specific calendars
2. **Mail Timeouts**: Reduce limit or filter by account
3. **AppleScript Delays**: Restart affected applications if they become unresponsive

### JSON Parsing Errors

1. Ensure commands are run with proper shell quoting
2. Use `--json-schema-strict` to catch malformed input early
3. Check log files for detailed error information

## Data Ingestion Roadmap

The Messages ingestion system serves as the foundation for a systematic approach to ingesting all macOS data sources. The following data types are prioritized for implementation:

### Completed
- **Messages**: Bulk ingestion with batch processing, FTS5 search, transaction isolation

### Next Implementation Targets (In Priority Order)
1. **Contacts**: Address Book data ingestion
2. **Mail**: Email headers and metadata processing  
3. **Calendar**: Event and reminder data extraction
4. **WhatsApp**: Third-party messaging data integration

### CLI Ingestion Architecture Options
Two approaches under consideration for the rebuild:
- **Sequential Processing**: Process each data type individually with isolated transactions
- **Parallel Processing**: Concurrent ingestion of all data types with coordinated error handling

## Development

### Building

```bash
# Debug build
swift build

# Release build  
swift build -c release

# Run tests
swift test
```

### Project Structure

```
Sources/mac_tools/
├── main.swift              # Command dispatch
├── Core/                   # Core utilities
│   ├── Logger.swift        # NDJSON logging
│   ├── JsonIO.swift        # JSON I/O handling
│   ├── Validation.swift    # Input validation
│   ├── PlanHash.swift      # Dry-run/confirm logic
│   └── TCC.swift          # Permission management
├── Commands/               # Command implementations
│   ├── CalendarList.swift
│   ├── MailListHeaders.swift
│   ├── RemindersCreate.swift
│   ├── NotesAppend.swift
│   ├── FilesMove.swift
│   └── TCCRequest.swift
├── Ingestion/             # Data ingestion system
│   ├── IngestManager.swift   # Orchestrates all ingestion
│   ├── MessagesIngester.swift # Messages bulk processing
│   ├── DatabaseCLI.swift     # Database command interface
│   └── kenny.db             # Target ingestion database
└── Bridges/               # AppleScript bridges
    ├── MailBridge.applescript
    └── NotesBridge.applescript
```

## License

[Your License Here]

## Contributing

[Contributing Guidelines Here]