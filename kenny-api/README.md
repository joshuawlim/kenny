# Kenny FastAPI Backend

Contact-centric AI assistant backend that unifies 234K documents across WhatsApp, Mail, Calendar, Messages, and Contacts through sophisticated database merging and LLM tool calling.

## Quick Start

```bash
# 1. Navigate to the API directory
cd /Users/joshwlim/Documents/Kenny/kenny-api

# 2. Start the server (builds dependencies if needed)
./start.sh

# 3. Test the API (in another terminal)
python3 test_api.py
```

The server runs on `http://localhost:8080` and is ready for Cloudflare tunnel access.

## Architecture Overview

```
Frontend (Next.js) ←→ FastAPI Backend ←→ Swift Orchestrator
                           ↓
                    Database Manager
                     ↙          ↘
         contact_memory.db    kenny.db
         (Contact threading)  (234K documents)
```

### Key Features

- **Contact-Centric Threading**: Messages grouped by person, not platform
- **Cross-Database Integration**: Merges contact memory with document data  
- **LLM Tool Calling**: Wraps orchestrator_cli Swift commands for AI use
- **Streaming Responses**: Server-Sent Events for real-time LLM interactions
- **Enhanced Search**: Contact-aware search with relationship context

## API Endpoints

### Authentication
All endpoints require Bearer token authentication:
```bash
curl -H "Authorization: Bearer $KENNY_API_KEY" http://localhost:8080/health
```

### Core Endpoints

#### Health Check
```bash
GET /health
```
Returns system status, database connections, and document counts.

#### Contacts
```bash
# List contacts with search
GET /contacts?q=john&limit=20

# Get contact details + memories
GET /contacts/{contact_id}

# Get contact's message thread
GET /contacts/{contact_id}/thread?limit=50
```

#### Search
```bash
POST /search
Content-Type: application/json

{
  "query": "meeting tomorrow",
  "limit": 20,
  "contact_id": "optional-contact-filter",
  "sources": ["WhatsApp", "Mail"]
}
```

#### Contact Threads
```bash
# List contact-based conversation threads
GET /threads?limit=20&active_only=true
```

#### LLM Assistant (Streaming)
```bash
POST /assistant/query
Content-Type: application/json

{
  "query": "What did John say about the meeting?",
  "mode": "search",
  "contact_id": "optional-contact-focus"
}
```

Returns Server-Sent Events stream:
```
data: {"type": "start", "execution_id": "uuid", "message": "Processing..."}
data: {"type": "tool_start", "tool": "search_documents", "status": "running"}
data: {"type": "tool_complete", "tool": "search_documents", "status": "success"}
data: {"type": "response", "message": "Based on your query..."}
data: {"type": "done", "execution_id": "uuid"}
```

#### Tool System
```bash
# List available tools
GET /tools

# Execute specific tool
POST /tools/execute
Content-Type: application/json

{
  "name": "search_documents",
  "parameters": {
    "query": "quarterly report",
    "limit": 10
  }
}
```

## Database Architecture

### Contact Memory Database (`contact_memory.db`)
```sql
-- 1,323 contacts with identity resolution
kenny_contacts (kenny_contact_id, display_name, confidence_score, ...)

-- Phone/email/WhatsApp identity mapping  
contact_identities (kenny_contact_id, identity_type, identity_value, ...)

-- Links to kenny.db documents (1,687 links)
contact_threads (kenny_contact_id, document_id, relationship_type, ...)

-- AI-extracted memories and insights
contact_memories (kenny_contact_id, memory_type, title, description, ...)

-- Relationship context (work, family, etc.)
contact_relationships (kenny_contact_id, relationship_type, company, ...)
```

### Kenny Database (`kenny.db`)
```sql
-- 234K documents from all sources
documents (id, title, content, app_source, created_at, metadata_json, ...)

-- System contacts
contacts (contact_id, first_name, last_name, primary_phone, ...)
```

## LLM Tool Integration

The backend provides a tool calling interface ready for LLM integration:

### Available Tools

1. **search_documents**: Multi-source document search
2. **search_contact_specific**: Search filtered by contact  
3. **analyze_meeting_threads**: Email thread analysis for scheduling
4. **propose_meeting_slots**: Calendar-based meeting suggestions
5. **get_system_status**: Health and statistics

### Example Tool Call
```python
# From LLM service
tool_call = {
    "name": "search_contact_specific", 
    "parameters": {
        "contact_id": "uuid-for-john-doe",
        "query": "project deadline"
    }
}

# API handles orchestrator execution
result = await orchestrator_service.execute_tool(
    tool_call["name"], 
    tool_call["parameters"]
)
```

## Development

### Setup
```bash
# Install Python dependencies
pip3 install fastapi uvicorn pydantic

# Ensure Swift orchestrator is built
cd ../mac_tools
swift build -c release

# Initialize contact memory database (if needed)
cd ../kenny-api  
python3 contact_resolver.py
```

### Environment Variables
```bash
# Required
export KENNY_API_KEY="your-secure-api-key"

# Optional (auto-detected)
export KENNY_DB_PATH="/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db"
export CONTACT_DB_PATH="/Users/joshwlim/Documents/Kenny/kenny-api/contact_memory.db"
```

### Testing
```bash
# Full API test suite
python3 test_api.py

# Manual health check
curl -H "Authorization: Bearer $KENNY_API_KEY" http://localhost:8080/health

# Search test
curl -X POST http://localhost:8080/search \
  -H "Authorization: Bearer $KENNY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "meeting", "limit": 3}'
```

## Deployment

### Local Development
```bash
./start.sh  # Runs on localhost:8080
```

### Cloudflare Tunnel
```bash
# The server binds to 0.0.0.0:8080 for tunnel access
cloudflared tunnel --url http://localhost:8080
```

### Production Considerations
- Set strong `KENNY_API_KEY`
- Configure CORS origins properly
- Add rate limiting middleware
- Set up proper logging and monitoring
- Consider database connection pooling for high load

## Architecture Benefits

### Contact-Centric Design
- **Unified Threading**: See all interactions with a person across platforms
- **Relationship Context**: Understand who someone is and how you know them
- **Memory Integration**: AI-extracted insights about each contact
- **Cross-Platform Search**: Find information regardless of where it came from

### LLM Integration Ready
- **Tool Calling Interface**: Drop-in compatible with OpenAI/Anthropic formats
- **Streaming Responses**: Real-time updates during processing
- **Context Building**: Automatic personal data context for queries
- **Contact Awareness**: Queries can focus on specific relationships

### Performance Optimized
- **Async Architecture**: Non-blocking operations throughout
- **Database Indexing**: Optimized for contact-centric queries  
- **Connection Pooling**: Efficient database resource management
- **Streaming Execution**: Progressive result delivery

## Troubleshooting

### Common Issues

**Server won't start**
```bash
# Check orchestrator binary
ls -la ../mac_tools/.build/release/orchestrator_cli

# Rebuild if missing
cd ../mac_tools && swift build -c release
```

**Database connection errors**
```bash
# Check database files exist
ls -la kenny.db ../mac_tools/kenny.db contact_memory.db

# Reinitialize contact memory if needed
python3 contact_resolver.py
```

**API authentication fails**
```bash
# Check API key environment variable
echo $KENNY_API_KEY

# Set temporary key
export KENNY_API_KEY="test-key-123"
```

**Contact threads empty**
```bash
# Run contact resolution to link documents
python3 contact_resolver.py

# Check contact database
sqlite3 contact_memory.db "SELECT COUNT(*) FROM contact_threads;"
```

### Logs and Debugging
- Server logs go to stdout (visible when running `./start.sh`)
- Enable debug logging by setting log level to DEBUG in main.py
- Check orchestrator command execution with `swift run orchestrator_cli status`

## Next Steps

1. **LLM Integration**: Connect to OpenAI/Anthropic APIs for real assistant responses
2. **Memory Enhancement**: Improve AI memory extraction and relationship inference  
3. **Real-time Updates**: WebSocket connections for live data updates
4. **Advanced Threading**: Better conversation grouping algorithms
5. **Performance Tuning**: Database query optimization and caching layers

The architecture is designed to scale from local development to production deployment while maintaining the contact-centric approach that makes Kenny unique.