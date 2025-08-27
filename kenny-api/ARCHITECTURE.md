# Kenny FastAPI Backend Architecture

## Overview

The Kenny FastAPI backend provides a contact-centric AI assistant API that unifies data from multiple sources through sophisticated database merging and LLM tool calling capabilities. It's designed for tunnel access with streaming responses and contact-threaded views.

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    FastAPI Backend (Port 8080)              │
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────┐ │
│  │   Contact Data  │  │  Enhanced       │  │ Orchestrator │ │
│  │   Service       │  │  Search         │  │ Tool Service │ │
│  │                 │  │  Service        │  │              │ │
│  └─────────────────┘  └─────────────────┘  └──────────────┘ │
│           │                     │                   │       │
│           └─────────────────────┼───────────────────┘       │
│                                 │                           │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │              Database Manager                           │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
           │                                      │
           ▼                                      ▼
┌─────────────────────┐                 ┌─────────────────────┐
│   contact_memory.db │                 │      kenny.db       │
│                     │                 │                     │
│ • 1,323 contacts    │                 │ • 234K documents    │
│ • 1,687 doc links   │                 │ • WhatsApp          │
│ • Contact memories  │                 │ • Mail              │
│ • Identity mapping  │                 │ • Calendar          │
│ • Relationships     │                 │ • Messages          │
└─────────────────────┘                 │ • Contacts          │
                                        └─────────────────────┘
                                                 │
                                                 ▼
                                   ┌─────────────────────┐
                                   │  orchestrator_cli   │
                                   │  (Swift Binary)     │
                                   │                     │
                                   │ • Search            │
                                   │ • Meeting Analysis  │
                                   │ • Status            │
                                   │ • Embeddings        │
                                   └─────────────────────┘
```

## Core Components

### 1. Contact Data Service Layer
- **Purpose**: Merges kenny.db and contact_memory.db for contact-centric views
- **Key Functions**:
  - Contact resolution and identity mapping
  - Thread aggregation by contact
  - Memory and relationship tracking
  - Cross-database document linking

### 2. Enhanced Search Service  
- **Purpose**: Integrates orchestrator search with contact context
- **Features**:
  - Contact-filtered search results
  - Cross-reference document links with contact data
  - Result enrichment with contact summaries
  - Contact breakdown analytics

### 3. Orchestrator Tool Service
- **Purpose**: Wraps Swift orchestrator_cli for LLM tool calling
- **Available Tools**:
  - `search_documents`: Multi-source document search
  - `search_contact_specific`: Contact-filtered search
  - `analyze_meeting_threads`: Email thread analysis
  - `propose_meeting_slots`: Calendar-based scheduling
  - `get_system_status`: Health and statistics

### 4. Database Manager
- **Purpose**: Connection management and query execution
- **Features**:
  - Dual database connections (kenny.db + contact_memory.db)
  - Row factory for dict results
  - Connection pooling and error handling
  - Cross-database query coordination

## API Endpoints

### Core Endpoints

```
GET  /health                    - System health check
GET  /contacts                  - List contacts with search
GET  /contacts/{id}             - Get contact details + memories  
GET  /contacts/{id}/thread      - Get contact's message thread
GET  /threads                   - List contact-based threads
POST /search                    - Enhanced search with contact context
POST /assistant/query           - Streaming LLM assistant (SSE)
GET  /tools                     - List available LLM tools
POST /tools/execute             - Execute specific tool
```

### Authentication
- **Method**: HTTP Bearer token
- **Header**: `Authorization: Bearer <API_KEY>`
- **Environment**: `KENNY_API_KEY` (defaults to dev key)

### Streaming Responses
Server-Sent Events (SSE) format for `/assistant/query`:

```json
// Start
{"type": "start", "execution_id": "uuid", "message": "Processing...", "query": "..."}

// Tool execution
{"type": "tool_start", "tool": "search_documents", "status": "running"}
{"type": "tool_complete", "tool": "search_documents", "status": "success", "result_summary": "Found 5 results"}

// Context building
{"type": "context", "summary": "Found 5 relevant documents; Focused on contact: John Doe"}

// Final response
{"type": "response", "message": "Based on your query..."}

// Completion
{"type": "done", "execution_id": "uuid"}
```

## Data Flow

### Contact-Centric Search Flow
1. **Request**: POST /search with query and optional contact_id
2. **Orchestrator Call**: Execute search via orchestrator_cli
3. **Document Resolution**: Get raw search results from kenny.db
4. **Contact Linking**: Match document IDs to contacts via contact_threads
5. **Enrichment**: Attach contact summaries to results
6. **Response**: Return enriched results with contact breakdown

### Contact Thread Flow  
1. **Request**: GET /contacts/{id}/thread
2. **Contact Lookup**: Get contact summary from contact_memory.db
3. **Document IDs**: Query contact_threads for linked document IDs
4. **Document Details**: Fetch document content from kenny.db
5. **Thread Assembly**: Combine documents with relationship metadata
6. **Response**: Return chronological thread with contact context

### LLM Assistant Flow
1. **Request**: POST /assistant/query (streaming)
2. **Tool Selection**: Determine tools based on query content and mode
3. **Tool Execution**: Run orchestrator tools with streaming updates
4. **Context Building**: Aggregate tool results and contact information
5. **Response Generation**: Create assistant response (ready for LLM integration)
6. **Streaming**: Send real-time updates via Server-Sent Events

## Database Schema Integration

### Contact Memory Schema
```sql
-- Core contact identity
kenny_contacts (kenny_contact_id, display_name, confidence_score, ...)

-- Identity mapping (phones, emails, WhatsApp JIDs)  
contact_identities (kenny_contact_id, identity_type, identity_value, ...)

-- Document linking (references kenny.db document IDs)
contact_threads (kenny_contact_id, document_id, relationship_type, ...)

-- Extracted memories and insights
contact_memories (kenny_contact_id, memory_type, title, description, ...)

-- Relationship context
contact_relationships (kenny_contact_id, relationship_type, company, role, ...)
```

### Kenny DB Schema (Referenced)
```sql  
-- 234K documents from all sources
documents (id, title, content, app_source, created_at, metadata_json, ...)

-- Contacts from system address book
contacts (contact_id, first_name, last_name, primary_phone, primary_email, ...)
```

## Error Handling

### HTTP Status Codes
- `200`: Success
- `400`: Bad Request (invalid parameters)
- `401`: Unauthorized (invalid API key)
- `404`: Not Found (contact/resource doesn't exist)
- `500`: Internal Server Error (orchestrator/database failures)
- `504`: Gateway Timeout (orchestrator command timeout)

### Error Response Format
```json
{
  "error": "Error message",
  "path": "/api/endpoint", 
  "timestamp": "2025-08-27T12:00:00Z",
  "execution_id": "uuid" // for tool executions
}
```

## Performance Considerations

### Database Optimization
- Indexes on contact_threads(kenny_contact_id, document_id)
- Connection pooling for both databases
- Query result caching for frequently accessed contacts
- Pagination for large result sets

### Orchestrator Integration
- Command timeouts (30s default)
- Async execution with proper error handling  
- Result caching for expensive operations
- Rate limiting for tool executions

### Streaming Performance
- Chunked Server-Sent Events
- Non-blocking tool execution
- Progressive result delivery
- Connection keep-alive management

## Security

### API Authentication
- Bearer token authentication
- Environment-based API key configuration
- Request rate limiting (future enhancement)
- CORS configuration for tunnel access

### Database Security
- Read-only access patterns where possible
- SQL injection prevention via parameterized queries
- Connection string security
- Audit logging for sensitive operations

## Deployment

### Environment Setup
```bash
# Required environment variables
export KENNY_API_KEY="your-secure-api-key"

# Database paths (auto-detected)
export KENNY_DB_PATH="/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db"
export CONTACT_DB_PATH="/Users/joshwlim/Documents/Kenny/kenny-api/contact_memory.db"
```

### Dependencies
- FastAPI + Uvicorn
- SQLite3 (built-in)
- Pydantic for data validation
- asyncio for async operations

### Cloudflare Tunnel Integration
- Bind to 0.0.0.0:8080
- Configure tunnel endpoint
- API key authentication for security
- CORS enabled for web frontend

## Integration Points

### Frontend Integration
- Server-Sent Events for real-time responses
- RESTful API for contact and search operations
- Contact-centric data views matching UI expectations
- Progressive loading for large threads

### LLM Service Integration
- Tool calling interface ready for OpenAI/Anthropic format
- Context building with personal data
- Streaming response format
- Contact-aware prompt engineering

### Swift Orchestrator Integration  
- Async subprocess execution
- JSON response parsing
- Error handling and retries
- Command timeout management

This architecture provides a robust, scalable foundation for Kenny's contact-centric AI assistant with proper separation of concerns and integration patterns.