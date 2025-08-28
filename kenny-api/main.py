#!/usr/bin/env python3
"""
Kenny Backend API - Contact-Centric AI Assistant Backend

Provides contact-threaded views of personal data with LLM tool calling capabilities.
Merges kenny.db (234K documents) with contact_memory.db (contact resolution) to provide
unified contact-centric threading for WhatsApp, Mail, Calendar, Messages, and Contacts.

Architecture:
- Contact-centric data layer merging both databases
- LLM tool calling system wrapping orchestrator_cli Swift commands  
- Server-sent events for streaming LLM responses
- RESTful API with API key authentication for Cloudflare tunnel access
"""

import asyncio
import json
import subprocess
import os
import sqlite3
import logging
from datetime import datetime, timezone
from typing import Optional, List, Dict, Any, AsyncGenerator, Union
import uuid
from pathlib import Path
from contextlib import asynccontextmanager
import aiohttp

from fastapi import FastAPI, HTTPException, Security, Depends, Query, BackgroundTasks
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.responses import StreamingResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field, field_validator, constr
import uvicorn

# Configuration
KENNY_ROOT = Path("/Users/joshwlim/Documents/Kenny")
ORCHESTRATOR_PATH = KENNY_ROOT / "mac_tools" / ".build" / "release" / "orchestrator_cli"
KENNY_DATABASE_PATH = KENNY_ROOT / "mac_tools" / "kenny.db"
CONTACT_DATABASE_PATH = KENNY_ROOT / "kenny-api" / "contact_memory.db"
API_KEY = os.getenv("KENNY_API_KEY")
if not API_KEY:
    raise ValueError("KENNY_API_KEY environment variable is required")

# Startup time tracking
START_TIME = datetime.now(timezone.utc)

# Logging setup
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Security and middleware
security = HTTPBearer()

def verify_api_key(credentials: HTTPAuthorizationCredentials = Security(security)):
    if credentials.credentials != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return credentials

class DatabaseManager:
    """Manages connections to both kenny.db and contact_memory.db"""
    
    def __init__(self):
        self.kenny_db_path = str(KENNY_DATABASE_PATH)
        self.contact_db_path = str(CONTACT_DATABASE_PATH)
    
    def get_kenny_connection(self):
        """Get connection to main kenny.db"""
        return sqlite3.connect(self.kenny_db_path)
    
    def get_contact_connection(self):
        """Get connection to contact_memory.db"""
        return sqlite3.connect(self.contact_db_path)
    
    def execute_with_kenny_db(self, query: str, params: tuple = ()) -> List[Dict]:
        """Execute query against kenny.db and return dict results"""
        with self.get_kenny_connection() as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.execute(query, params)
            return [dict(row) for row in cursor.fetchall()]
    
    def execute_with_contact_db(self, query: str, params: tuple = ()) -> List[Dict]:
        """Execute query against contact_memory.db and return dict results"""
        with self.get_contact_connection() as conn:
            conn.row_factory = sqlite3.Row
            cursor = conn.execute(query, params)
            return [dict(row) for row in cursor.fetchall()]

db_manager = DatabaseManager()

# Models
# Pydantic Models
class ContactIdentity(BaseModel):
    id: str
    type: str  # 'phone', 'email', 'whatsapp_jid', 'contact_record'
    value: str
    source: str
    confidence: float

class ContactSummary(BaseModel):
    kenny_contact_id: str
    display_name: str
    identities: List[ContactIdentity]
    relationship_type: Optional[str] = None
    company: Optional[str] = None
    role: Optional[str] = None
    total_interactions: int
    last_interaction_time: Optional[str] = None
    memory_count: int
    photo_path: Optional[str] = None

class ContactThread(BaseModel):
    kenny_contact_id: str
    display_name: str
    messages: List[Dict[str, Any]]
    total_count: int
    last_message_at: Optional[str] = None
    sources: List[str]

class ContactMemory(BaseModel):
    id: str
    memory_type: str
    title: str
    description: Optional[str] = None
    confidence: float
    extracted_at: str
    importance_score: float
    tags: Optional[List[str]] = None

class SearchRequest(BaseModel):
    query: str
    limit: Optional[int] = 20
    contact_id: Optional[str] = None  # Filter by contact
    sources: Optional[List[str]] = None
    after: Optional[str] = None

class SearchResult(BaseModel):
    id: str
    title: str
    content: str
    source: str
    score: float
    created_at: str
    contact_info: Optional[ContactSummary] = None
    highlights: Optional[Dict[str, Any]] = None

class SearchResponse(BaseModel):
    results: List[SearchResult]
    took_ms: int
    total_results: int
    contact_breakdown: Dict[str, int]  # Contact ID -> result count

class AssistantQuery(BaseModel):
    query: constr(min_length=1, max_length=1000) = Field(..., description="The user's question or request")
    mode: str = Field(default="qa", description="Assistant mode")
    context: Optional[Dict[str, Any]] = Field(default=None, description="Additional context")
    contact_id: Optional[str] = Field(default=None, description="Focus on specific contact")
    
    @field_validator('mode')
    @classmethod
    def validate_mode(cls, v):
        allowed_modes = ['qa', 'search', 'analyze', 'draft', 'summarize']
        if v not in allowed_modes:
            raise ValueError(f'Mode must be one of: {allowed_modes}')
        return v
    
    @field_validator('query')
    @classmethod
    def validate_query(cls, v):
        # SECURITY: Basic sanitization to prevent injection
        if any(char in v for char in ['<script', '<iframe', 'javascript:', 'data:']):
            raise ValueError('Query contains potentially malicious content')
        return v.strip()
    
    @field_validator('contact_id')
    @classmethod
    def validate_contact_id(cls, v):
        if v is not None and (len(v) < 10 or len(v) > 50):
            raise ValueError('Invalid contact ID format')
        return v

class ToolCall(BaseModel):
    name: str
    parameters: Dict[str, Any]
    execution_id: str = Field(default_factory=lambda: str(uuid.uuid4()))

class HealthResponse(BaseModel):
    status: str
    kenny_db_connected: bool
    contact_db_connected: bool
    kenny_db_size_mb: float
    document_count: int
    contact_count: int
    embeddings_coverage: float
    build: str
    uptime_seconds: float

# Contact Data Service Layer
class ContactDataService:
    """Service layer for contact-centric data operations"""
    
    def __init__(self, db_manager: DatabaseManager):
        self.db = db_manager
    
    def get_contact_summary(self, kenny_contact_id: str) -> Optional[ContactSummary]:
        """Get comprehensive contact summary with identities and stats"""
        contact_data = self.db.execute_with_contact_db(
            """
            SELECT kc.kenny_contact_id, kc.display_name, kc.photo_path,
                   cr.relationship_type, cr.company, cr.role,
                   COUNT(DISTINCT ct.document_id) as total_interactions,
                   MAX(ct.extracted_at) as last_interaction_time,
                   COUNT(DISTINCT cm.id) as memory_count
            FROM kenny_contacts kc
            LEFT JOIN contact_relationships cr ON kc.kenny_contact_id = cr.kenny_contact_id
            LEFT JOIN contact_threads ct ON kc.kenny_contact_id = ct.kenny_contact_id  
            LEFT JOIN contact_memories cm ON kc.kenny_contact_id = cm.kenny_contact_id
            WHERE kc.kenny_contact_id = ?
            GROUP BY kc.kenny_contact_id, kc.display_name, cr.relationship_type, cr.company, cr.role
            """,
            (kenny_contact_id,)
        )
        
        if not contact_data:
            return None
            
        contact = contact_data[0]
        
        # Get identities
        identities_data = self.db.execute_with_contact_db(
            """
            SELECT id, identity_type, identity_value, source, confidence
            FROM contact_identities
            WHERE kenny_contact_id = ?
            ORDER BY confidence DESC, created_at DESC
            """,
            (kenny_contact_id,)
        )
        
        identities = [
            ContactIdentity(
                id=row['id'],
                type=row['identity_type'],
                value=row['identity_value'],
                source=row['source'],
                confidence=row['confidence']
            )
            for row in identities_data
        ]
        
        return ContactSummary(
            kenny_contact_id=contact['kenny_contact_id'],
            display_name=contact['display_name'],
            identities=identities,
            relationship_type=contact.get('relationship_type'),
            company=contact.get('company'),
            role=contact.get('role'),
            total_interactions=contact['total_interactions'] or 0,
            last_interaction_time=contact.get('last_interaction_time'),
            memory_count=contact['memory_count'] or 0,
            photo_path=contact.get('photo_path')
        )
    
    def get_contact_thread(self, kenny_contact_id: str, limit: int = 50) -> Optional[ContactThread]:
        """Get contact's message thread by merging documents from kenny.db"""
        contact_summary = self.get_contact_summary(kenny_contact_id)
        if not contact_summary:
            return None
        
        # Get document IDs for this contact from contact_threads
        doc_links = self.db.execute_with_contact_db(
            """
            SELECT document_id, relationship_type, extracted_at, confidence
            FROM contact_threads
            WHERE kenny_contact_id = ?
            ORDER BY extracted_at DESC
            LIMIT ?
            """,
            (kenny_contact_id, limit)
        )
        
        if not doc_links:
            return ContactThread(
                kenny_contact_id=kenny_contact_id,
                display_name=contact_summary.display_name,
                messages=[],
                total_count=0,
                sources=[]
            )
        
        # Get document details from kenny.db
        doc_ids = [link['document_id'] for link in doc_links]
        placeholders = ','.join('?' * len(doc_ids))
        
        documents = self.db.execute_with_kenny_db(
            f"""
            SELECT id, title, content, app_source, created_at, metadata_json
            FROM documents
            WHERE id IN ({placeholders})
            ORDER BY created_at DESC
            """,
            tuple(doc_ids)
        )
        
        # Merge document data with relationship info
        messages = []
        sources = set()
        
        for doc in documents:
            # Find corresponding relationship info
            link_info = next((link for link in doc_links if link['document_id'] == doc['id']), {})
            
            message = {
                'id': doc['id'],
                'title': doc['title'],
                'content': doc['content'],
                'source': doc['app_source'],
                'created_at': doc['created_at'],
                'relationship_type': link_info.get('relationship_type', 'unknown'),
                'link_confidence': link_info.get('confidence', 0.0),
                'metadata': json.loads(doc['metadata_json'] or '{}')
            }
            messages.append(message)
            sources.add(doc['app_source'])
        
        return ContactThread(
            kenny_contact_id=kenny_contact_id,
            display_name=contact_summary.display_name,
            messages=messages,
            total_count=len(messages),
            last_message_at=messages[0]['created_at'] if messages else None,
            sources=list(sources)
        )
    
    def search_contacts(self, query: str, limit: int = 20) -> List[ContactSummary]:
        """Search contacts by name, company, or other attributes"""
        contacts_data = self.db.execute_with_contact_db(
            """
            SELECT DISTINCT kc.kenny_contact_id
            FROM kenny_contacts kc
            LEFT JOIN contact_relationships cr ON kc.kenny_contact_id = cr.kenny_contact_id
            LEFT JOIN contact_identities ci ON kc.kenny_contact_id = ci.kenny_contact_id
            WHERE kc.display_name LIKE ? 
               OR cr.company LIKE ?
               OR cr.role LIKE ?
               OR ci.identity_value LIKE ?
            LIMIT ?
            """,
            (f'%{query}%', f'%{query}%', f'%{query}%', f'%{query}%', limit)
        )
        
        contacts = []
        for row in contacts_data:
            contact = self.get_contact_summary(row['kenny_contact_id'])
            if contact:
                contacts.append(contact)
        
        return contacts
    
    def get_contact_memories(self, kenny_contact_id: str, limit: int = 10) -> List[ContactMemory]:
        """Get memories associated with a contact"""
        memories_data = self.db.execute_with_contact_db(
            """
            SELECT id, memory_type, title, description, confidence,
                   extracted_at, importance_score, tags
            FROM contact_memories
            WHERE kenny_contact_id = ?
            ORDER BY importance_score DESC, extracted_at DESC
            LIMIT ?
            """,
            (kenny_contact_id, limit)
        )
        
        return [
            ContactMemory(
                id=row['id'],
                memory_type=row['memory_type'],
                title=row['title'],
                description=row.get('description'),
                confidence=row['confidence'],
                extracted_at=row['extracted_at'],
                importance_score=row['importance_score'],
                tags=json.loads(row['tags'] or '[]')
            )
            for row in memories_data
        ]

contact_service = ContactDataService(db_manager)

# LLM Service for Ollama Integration
class OllamaLLMService:
    """Service for Ollama LLM API integration"""
    
    def __init__(self, base_url: str = "http://localhost:11434", model: str = "mistral-small3.1:latest"):
        self.base_url = base_url
        self.model = model
        self.timeout = 60  # 60 second timeout for LLM requests
    
    async def generate_response(self, prompt: str, context: str = "", max_tokens: int = 500) -> str:
        """Generate response using Ollama chat API"""
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=self.timeout)) as session:
                # Build the full prompt with context
                full_prompt = self._build_prompt(prompt, context)
                
                payload = {
                    "model": self.model,
                    "messages": [
                        {
                            "role": "system",
                            "content": "You are Kenny, a helpful AI assistant with access to the user's personal data including WhatsApp messages, emails, calendar events, and contacts. Provide concise, accurate responses based on the provided context. If you can't find specific information, suggest alternative ways to help."
                        },
                        {
                            "role": "user",
                            "content": full_prompt
                        }
                    ],
                    "stream": False,
                    "options": {
                        "temperature": 0.7,
                        "top_p": 0.9,
                        "num_predict": max_tokens
                    }
                }
                
                async with session.post(
                    f"{self.base_url}/api/chat",
                    json=payload,
                    headers={"Content-Type": "application/json"}
                ) as response:
                    if response.status == 200:
                        data = await response.json()
                        return data.get("message", {}).get("content", "I apologize, but I couldn't generate a response.")
                    else:
                        error_text = await response.text()
                        logger.error(f"Ollama API error {response.status}: {error_text}")
                        return f"I'm having trouble connecting to the AI service. Please make sure Ollama is running with the {self.model} model."
        
        except asyncio.TimeoutError:
            logger.error("Ollama request timed out")
            return "The AI service is taking too long to respond. Please try again."
        except Exception as e:
            logger.error(f"Ollama request failed: {e}")
            return f"I'm experiencing technical difficulties. Please ensure Ollama is running and try again."
    
    def _build_prompt(self, user_query: str, context: str) -> str:
        """Build the full prompt with context for the LLM"""
        if not context or context == "No specific context found":
            return f"""User Query: {user_query}

I don't have specific relevant information from your data for this query. Please provide a helpful response or suggest how I can better assist you."""
        
        return f"""User Query: {user_query}

Context from your personal data:
{context}

Based on this context from your personal data, please provide a helpful and accurate response to the user's query. If the context doesn't fully answer the question, acknowledge what information is available and suggest follow-up questions or alternative approaches."""
    
    async def select_tools(self, user_query: str, available_tools: List[Dict]) -> List[str]:
        """Use LLM to intelligently select which tools to use for a query"""
        try:
            tools_description = "\n".join([
                f"- {tool['name']}: {tool['description']}" 
                for tool in available_tools
            ])
            
            selection_prompt = f"""User Query: {user_query}

Available tools:
{tools_description}

Based on the user's query, which tools should I use to provide the best response? 
Return ONLY a JSON list of tool names, nothing else. For example: ["search_documents", "analyze_meeting_threads"]

If the query is about general information, use search_documents.
If it's about meetings/calendar, use analyze_meeting_threads.
If it's about a specific contact, use search_contact_specific.
If it's asking for meeting scheduling, use propose_meeting_slots.

Tool selection:"""

            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=15)) as session:
                payload = {
                    "model": self.model,
                    "messages": [
                        {
                            "role": "system",
                            "content": "You are a tool selection assistant. Return only valid JSON arrays of tool names, no explanations or additional text."
                        },
                        {
                            "role": "user",
                            "content": selection_prompt
                        }
                    ],
                    "stream": False,
                    "options": {
                        "temperature": 0.1,  # Low temperature for consistent tool selection
                        "num_predict": 50
                    }
                }
                
                async with session.post(
                    f"{self.base_url}/api/chat",
                    json=payload,
                    headers={"Content-Type": "application/json"}
                ) as response:
                    if response.status == 200:
                        data = await response.json()
                        response_text = data.get("message", {}).get("content", "").strip()
                        
                        # Try to parse JSON response
                        try:
                            tools = json.loads(response_text)
                            if isinstance(tools, list):
                                # Validate that selected tools exist
                                valid_tools = [t['name'] for t in available_tools]
                                selected = [tool for tool in tools if tool in valid_tools]
                                return selected if selected else ["search_documents"]
                        except json.JSONDecodeError:
                            pass
                        
                        # Fallback: extract tool names from response
                        available_names = [t['name'] for t in available_tools]
                        found_tools = [name for name in available_names if name in response_text]
                        return found_tools if found_tools else ["search_documents"]
                    
        except Exception as e:
            logger.warning(f"Tool selection failed: {e}")
        
        # Default fallback
        return ["search_documents"]
    
    async def check_availability(self) -> bool:
        """Check if Ollama service is available"""
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=5)) as session:
                async with session.get(f"{self.base_url}/api/tags") as response:
                    if response.status == 200:
                        data = await response.json()
                        models = data.get("models", [])
                        return any(self.model in model.get("name", "") for model in models)
                    return False
        except Exception:
            return False

llm_service = OllamaLLMService()

# FastAPI App with lifecycle management
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup and shutdown events"""
    logger.info("Starting Kenny API server...")
    
    # Verify database connections
    try:
        kenny_conn = db_manager.get_kenny_connection()
        kenny_conn.close()
        
        contact_conn = db_manager.get_contact_connection()
        contact_conn.close()
        
        logger.info("Database connections verified")
    except Exception as e:
        logger.error(f"Database connection failed: {e}")
        raise
    
    yield
    
    logger.info("Shutting down Kenny API server")

app = FastAPI(
    title="Kenny API",
    description="Contact-Centric AI Assistant Backend",
    version="2.0.0",
    lifespan=lifespan
)

# CORS for tunnel access - SECURITY: Restrict origins in production
ALLOWED_ORIGINS = os.getenv("KENNY_ALLOWED_ORIGINS", "http://localhost:3000").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Accept"],
)

# Streaming LLM Assistant Endpoints

@app.post("/assistant/query", dependencies=[Depends(verify_api_key)])
async def assistant_query(request: AssistantQuery):
    """Stream LLM responses with enhanced tool calling and contact context"""
    
    return StreamingResponse(
        assistant_query_generator(request),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
        }
    )


@app.get("/api/chat/stream")
async def chat_stream(
    message: str = Query(..., description="User message to process"),
    mode: str = Query("qa", description="Assistant mode"),
    contact_id: Optional[str] = Query(None, description="Focus on specific contact"),
    api_key: str = Query(..., description="API key for authentication", alias="key")
):
    """GET endpoint for SSE streaming compatible with EventSource"""
    
    # Verify API key
    if api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")
    
    # Convert query params to AssistantQuery format
    request = AssistantQuery(
        query=message,
        mode=mode,
        contact_id=contact_id
    )
    
    # Use the same generator from the POST endpoint
    return StreamingResponse(
        assistant_query_generator(request),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET",
            "Access-Control-Allow-Headers": "Authorization, Content-Type, Accept"
        }
    )

async def assistant_query_generator(request: AssistantQuery) -> AsyncGenerator[str, None]:
    """Shared generator function for both POST and GET streaming endpoints"""
    try:
        execution_id = str(uuid.uuid4())
        
        # Start with acknowledgment
        yield f"data: {json.dumps({
            'type': 'start',
            'execution_id': execution_id,
            'message': 'Processing your query...',
            'query': request.query
        })}\\n\\n"
        
        # Get available tools
        available_tools = [
            {
                "name": "search_documents",
                "description": "Search across all user documents and messages from WhatsApp, Mail, Messages, Calendar, and Contacts"
            },
            {
                "name": "search_contact_specific", 
                "description": "Search within a specific contact's conversation thread and history"
            },
            {
                "name": "analyze_meeting_threads",
                "description": "Analyze email threads for meeting opportunities and scheduling conflicts"
            },
            {
                "name": "propose_meeting_slots",
                "description": "Propose meeting time slots based on calendar availability"
            },
            {
                "name": "get_recent_messages",
                "description": "Get recent messages from the last N days across all data sources"
            },
            {
                "name": "get_system_status",
                "description": "Get system status and health information"
            }
        ]
        
        # Use LLM to intelligently select tools
        yield f"data: {json.dumps({
            'type': 'tool_selection',
            'message': 'Analyzing your query to determine the best tools to use...'
        })}\\n\\n"
        
        try:
            tools_to_use = await llm_service.select_tools(request.query, available_tools)
            
            # Add contact-specific tool if contact_id provided
            if request.contact_id and "search_contact_specific" not in tools_to_use:
                tools_to_use.append("search_contact_specific")
                
        except Exception as e:
            logger.warning(f"Tool selection failed, using default: {e}")
            tools_to_use = ["search_documents"]
        
        # Execute tools
        tool_results = {}
        for tool_name in tools_to_use:
            yield f"data: {json.dumps({
                'type': 'tool_start',
                'tool': tool_name,
                'status': 'running'
            })}\\n\\n"
            
            # Prepare parameters based on tool
            if tool_name == "search_documents":
                params = {"query": request.query, "limit": 10}
                if request.context and "sources" in request.context:
                    params["sources"] = ",".join(request.context["sources"])
            elif tool_name == "search_contact_specific" and request.contact_id:
                params = {"contact_id": request.contact_id, "query": request.query}
            elif tool_name == "analyze_meeting_threads":
                params = {"since_days": 14}
            elif tool_name == "propose_meeting_slots":
                # Extract participants from query or context
                params = {"participants": request.query, "duration": 60}
            else:
                params = {}
            
            result = await orchestrator_service.execute_tool(tool_name, params)
            tool_results[tool_name] = result
            
            yield f"data: {json.dumps({
                'type': 'tool_complete',
                'tool': tool_name,
                'status': result.get('status', 'unknown'),
                'result_summary': _summarize_tool_result(result)
            })}\\n\\n"
        
        # Build context from tool results
        context_summary = _build_context_summary(tool_results, request.contact_id)
        
        yield f"data: {json.dumps({
            'type': 'context',
            'summary': context_summary
        })}\\n\\n"
        
        # Generate LLM response using Ollama
        response = await _generate_assistant_response(request, tool_results, context_summary)
        
        yield f"data: {json.dumps({
            'type': 'response',
            'message': response
        })}\\n\\n"
        
        yield f"data: {json.dumps({
            'type': 'done',
            'execution_id': execution_id
        })}\\n\\n"
        
    except Exception as e:
        logger.error(f"Assistant query failed: {e}")
        yield f"data: {json.dumps({
            'type': 'error',
            'error': str(e),
            'execution_id': execution_id
        })}\\n\\n"

def _summarize_tool_result(result: Dict[str, Any]) -> str:
    """Create a brief summary of tool execution result"""
    if result.get("status") == "success":
        data = result.get("data", {})
        if "results" in data:
            return f"Found {len(data['results'])} results"
        elif "raw_output" in data:
            return "Command executed successfully"
        else:
            return "Success"
    else:
        return f"Error: {result.get('error', 'Unknown error')}"

def _build_context_summary(tool_results: Dict, contact_id: Optional[str]) -> str:
    """Build context summary from tool results"""
    summaries = []
    
    for tool_name, result in tool_results.items():
        if result.get("status") == "success":
            data = result.get("data", {})
            if tool_name == "search_documents" and "results" in data:
                summaries.append(f"Found {len(data['results'])} relevant documents")
            elif tool_name == "analyze_meeting_threads":
                summaries.append("Analyzed recent email threads for meeting opportunities")
    
    if contact_id:
        contact = contact_service.get_contact_summary(contact_id)
        if contact:
            summaries.append(f"Focused on contact: {contact.display_name}")
    
    return "; ".join(summaries) if summaries else "No specific context found"

async def _generate_assistant_response(request: AssistantQuery, tool_results: Dict, context: str) -> str:
    """Generate assistant response using Ollama LLM with tool results context"""
    
    # Build rich context from tool results
    search_results = []
    context_parts = []
    
    for tool_name, result in tool_results.items():
        if result.get("status") == "success":
            data = result.get("data", {})
            
            if "search" in tool_name and "results" in data:
                search_results.extend(data["results"])
                
                # Add search results to context
                for i, item in enumerate(data["results"][:3]):  # Top 3 results
                    context_parts.append(f"Search Result {i+1}:")
                    context_parts.append(f"  Title: {item.get('title', 'Untitled')}")
                    context_parts.append(f"  Source: {item.get('source', 'Unknown')}")
                    context_parts.append(f"  Content: {item.get('content', '')[:200]}...")
                    context_parts.append("")
    
    # Add contact context if available
    if request.contact_id:
        contact = contact_service.get_contact_summary(request.contact_id)
        if contact:
            context_parts.append(f"Contact Context: {contact.display_name}")
            if contact.company:
                context_parts.append(f"  Company: {contact.company}")
            if contact.role:
                context_parts.append(f"  Role: {contact.role}")
            context_parts.append("")
    
    # Build the full context
    rich_context = "\n".join(context_parts) if context_parts else context
    
    # Generate response using Ollama
    try:
        response = await llm_service.generate_response(request.query, rich_context)
        return response
    except Exception as e:
        logger.error(f"LLM generation failed: {e}")
        # Fallback to basic template response
        if search_results:
            return f"I found {len(search_results)} relevant items for '{request.query}'. The most relevant result is from {search_results[0].get('source', 'unknown source')}: {search_results[0].get('title', 'Untitled')}. Would you like me to explore this further?"
        else:
            return f"I couldn't find specific information about '{request.query}' in your data. Could you try rephrasing your query or provide more details?"

# API Endpoints

@app.get("/health", response_model=HealthResponse)
async def health_check():
    """System health check"""
    try:
        # Check kenny.db
        kenny_connected = KENNY_DATABASE_PATH.exists()
        kenny_size = 0.0
        document_count = 0
        
        if kenny_connected:
            kenny_size = KENNY_DATABASE_PATH.stat().st_size / (1024 * 1024)  # MB
            try:
                docs = db_manager.execute_with_kenny_db("SELECT COUNT(*) as count FROM documents")
                document_count = docs[0]['count'] if docs else 0
            except:
                document_count = 0
        
        # Check contact_memory.db
        contact_connected = CONTACT_DATABASE_PATH.exists()
        contact_count = 0
        
        if contact_connected:
            try:
                contacts = db_manager.execute_with_contact_db("SELECT COUNT(*) as count FROM kenny_contacts")
                contact_count = contacts[0]['count'] if contacts else 0
            except:
                contact_count = 0
        
        # Calculate embeddings coverage (simplified)
        embeddings_coverage = 0.8 if document_count > 0 else 0.0
        
        # Check Ollama availability
        ollama_available = await llm_service.check_availability()
        
        # Calculate uptime
        uptime_seconds = (datetime.now(timezone.utc) - START_TIME).total_seconds()
        
        # Overall status considers both databases and LLM
        overall_status = "ok" if kenny_connected and contact_connected and ollama_available else "degraded"
        if not ollama_available:
            overall_status += f" (Ollama {llm_service.model} unavailable)"
        
        return HealthResponse(
            status=overall_status,
            kenny_db_connected=kenny_connected,
            contact_db_connected=contact_connected,
            kenny_db_size_mb=round(kenny_size, 2),
            document_count=document_count,
            contact_count=contact_count,
            embeddings_coverage=embeddings_coverage,
            build="kenny-api-2.0.0-ollama",
            uptime_seconds=round(uptime_seconds, 1)
        )
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        uptime_seconds = (datetime.now(timezone.utc) - START_TIME).total_seconds()
        return HealthResponse(
            status=f"error: {e}",
            kenny_db_connected=False,
            contact_db_connected=False,
            kenny_db_size_mb=0.0,
            document_count=0,
            contact_count=0,
            embeddings_coverage=0.0,
            build="kenny-api-2.0.0",
            uptime_seconds=round(uptime_seconds, 1)
        )

@app.get("/search", response_model=SearchResponse, dependencies=[Depends(verify_api_key)])
async def search(
    q: str = Query(..., min_length=1, max_length=500, description="Search query"),
    limit: int = Query(20, ge=1, le=100, description="Maximum results to return"),
    sources: Optional[str] = Query(None, max_length=200, description="Comma-separated list of sources"),
    after: Optional[str] = Query(None, max_length=100, description="Cursor for pagination")
):
    """Search across all document sources"""
    start_time = datetime.now()
    
    # Build orchestrator command
    cmd_args = ["search", q, "--limit", str(limit)]
    if sources:
        cmd_args.extend(["--sources", sources])
    
    try:
        result_data = await run_orchestrator_command(*cmd_args)
        
        # Transform orchestrator results to API format
        search_results = []
        for item in result_data.get("results", []):
            search_results.append(SearchResult(
                id=item.get("id", str(uuid.uuid4())),
                title=item.get("title", ""),
                content=item.get("content", ""),
                source=item.get("source", "unknown"),
                score=item.get("score", 0.0),
                created_at=item.get("created_at", ""),
                highlights=item.get("highlights")
            ))
        
        elapsed_ms = int((datetime.now() - start_time).total_seconds() * 1000)
        
        return SearchResponse(
            results=search_results,
            took_ms=elapsed_ms,
            total_results=len(search_results)
        )
    
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Search failed: {e}")

@app.get("/threads", dependencies=[Depends(verify_api_key)])
async def list_threads(
    cursor: Optional[str] = Query(None, description="Pagination cursor"),
    limit: int = Query(50, description="Maximum threads to return"),
    source: Optional[str] = Query(None, description="Filter by source")
):
    """List conversation threads"""
    # This is complex - we need to group documents by thread/conversation
    # For WhatsApp: group by chat_jid from metadata
    # For Email: group by conversation/subject
    # For Messages: group by conversation_id if available
    
    # For now, return a basic implementation that we'll enhance
    try:
        # Get recent documents grouped by source and thread identifiers
        result_data = await run_orchestrator_command("search", "", "--limit", str(limit * 3))
        
        # Group results by thread (simplified)
        threads = {}
        for item in result_data.get("results", []):
            source_name = item.get("source", "unknown")
            
            # Simple thread ID generation - enhance this based on metadata
            thread_key = f"{source_name}_{item.get('id', 'unknown')[:8]}"
            
            if thread_key not in threads:
                threads[thread_key] = {
                    "id": thread_key,
                    "title": item.get("title", "Untitled"),
                    "participants": [],
                    "last_message_at": item.get("created_at", ""),
                    "snippet": item.get("content", "")[:100],
                    "source": source_name.lower(),
                    "message_count": 1
                }
            else:
                threads[thread_key]["message_count"] += 1
        
        thread_list = list(threads.values())[:limit]
        
        return {
            "items": thread_list,
            "nextCursor": None  # TODO: Implement proper pagination
        }
    
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Thread listing failed: {e}")

# Contact-Centric Endpoints

@app.get("/contacts", dependencies=[Depends(verify_api_key)])
async def list_contacts(
    limit: int = Query(50, description="Maximum contacts to return"),
    search: Optional[str] = Query(None, description="Search contacts by name/company"),
    cursor: Optional[str] = Query(None, description="Pagination cursor")
):
    """List contacts with summaries"""
    try:
        if search:
            contacts = contact_service.search_contacts(search, limit)
        else:
            # Get all contacts
            contact_ids = db_manager.execute_with_contact_db(
                "SELECT kenny_contact_id FROM kenny_contacts ORDER BY display_name LIMIT ?",
                (limit,)
            )
            
            contacts = []
            for row in contact_ids:
                contact = contact_service.get_contact_summary(row['kenny_contact_id'])
                if contact:
                    contacts.append(contact)
        
        return {"contacts": contacts}
    
    except Exception as e:
        logger.error(f"List contacts failed: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to list contacts: {str(e)}")

@app.get("/contacts/{kenny_contact_id}", response_model=ContactSummary, dependencies=[Depends(verify_api_key)])
async def get_contact(kenny_contact_id: str):
    """Get detailed contact information"""
    contact = contact_service.get_contact_summary(kenny_contact_id)
    if not contact:
        raise HTTPException(status_code=404, detail="Contact not found")
    return contact

@app.get("/contacts/{kenny_contact_id}/thread", response_model=ContactThread, dependencies=[Depends(verify_api_key)])
async def get_contact_thread(
    kenny_contact_id: str,
    limit: int = Query(50, description="Maximum messages to return")
):
    """Get contact's message thread"""
    thread = contact_service.get_contact_thread(kenny_contact_id, limit)
    if not thread:
        raise HTTPException(status_code=404, detail="Contact thread not found")
    return thread

@app.get("/contacts/{kenny_contact_id}/memories", dependencies=[Depends(verify_api_key)])
async def get_contact_memories(
    kenny_contact_id: str,
    limit: int = Query(10, description="Maximum memories to return")
):
    """Get contact's memories and insights"""
    try:
        memories = contact_service.get_contact_memories(kenny_contact_id, limit)
        return {"memories": memories}
    except Exception as e:
        logger.error(f"Get contact memories failed: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to get memories: {str(e)}")

@app.post("/contacts/{kenny_contact_id}/search", response_model=SearchResponse, dependencies=[Depends(verify_api_key)])
async def search_contact_documents(kenny_contact_id: str, request: SearchRequest):
    """Search within a specific contact's documents"""
    try:
        # Verify contact exists
        contact = contact_service.get_contact_summary(kenny_contact_id)
        if not contact:
            raise HTTPException(status_code=404, detail="Contact not found")
        
        # Execute contact-specific search
        result = await orchestrator_service.execute_tool(
            "search_contact_specific",
            {
                "contact_id": kenny_contact_id,
                "query": request.query,
                "limit": request.limit or 20
            }
        )
        
        if result["status"] != "success":
            raise HTTPException(status_code=500, detail=f"Search failed: {result.get('error')}")
        
        data = result["data"]
        
        # Convert to SearchResponse format
        search_results = []
        for msg in data.get("results", []):
            search_results.append(SearchResult(
                id=msg["id"],
                title=msg.get("title", ""),
                content=msg.get("content", ""),
                source=msg.get("source", "unknown"),
                score=1.0,  # All results are equally relevant within contact
                created_at=msg.get("created_at", ""),
                contact_info=contact
            ))
        
        return SearchResponse(
            results=search_results,
            took_ms=0,  # TODO: measure time
            total_results=len(search_results),
            contact_breakdown={kenny_contact_id: len(search_results)}
        )
    
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Contact search failed: {e}")
        raise HTTPException(status_code=500, detail=f"Contact search failed: {str(e)}")

# Duplicate endpoint removed - using the enhanced version above

# Orchestrator Service Layer
class OrchestratorService:
    """Service layer for orchestrator_cli tool execution"""
    
    def __init__(self, orchestrator_path: str):
        self.orchestrator_path = orchestrator_path
    
    async def execute_command(self, *args) -> Dict[str, Any]:
        """Execute orchestrator command with args"""
        # SECURITY: Validate arguments to prevent command injection
        for arg in args:
            if not isinstance(arg, (str, int, float)):
                raise ValueError(f"Invalid argument type: {type(arg)}")
            arg_str = str(arg)
            if any(char in arg_str for char in [';', '&', '|', '`', '$', '(', ')']):
                raise ValueError(f"Invalid character in argument: {arg_str}")
        
        try:
            cmd = [str(self.orchestrator_path)] + [str(arg) for arg in args]
            
            # SECURITY: Add timeout to prevent hanging processes
            process = await asyncio.wait_for(
                asyncio.create_subprocess_exec(
                    *cmd,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE
                ),
                timeout=30.0  # 30 second timeout
            )
            
            stdout, stderr = await process.communicate()
            
            if process.returncode == 0:
                try:
                    result = json.loads(stdout.decode('utf-8'))
                    return {"status": "success", "data": result}
                except json.JSONDecodeError:
                    return {
                        "status": "success",
                        "data": {"raw_output": stdout.decode('utf-8').strip()}
                    }
            else:
                return {
                    "status": "error",
                    "error": stderr.decode('utf-8').strip() or "Command failed"
                }
        
        except Exception as e:
            return {"status": "error", "error": str(e)}
    
    def _sql_fallback_search(self, query: str, limit: int = 20) -> List[Dict]:
        """Direct SQL search fallback when hybrid search fails"""
        try:
            # Simple SQL search across documents - use OR for broader results
            search_terms = [term.strip() for term in query.lower().split() if len(term.strip()) > 2]
            
            if not search_terms:
                # If no good search terms, return recent documents
                sql = """
                SELECT id, title, content, app_source, created_at
                FROM documents 
                ORDER BY created_at DESC 
                LIMIT ?
                """
                params = (limit,)
            else:
                # Use OR for broader matching
                search_condition = " OR ".join([f"(LOWER(content) LIKE ? OR LOWER(title) LIKE ?)" for _ in search_terms])
                like_params = []
                for term in search_terms:
                    like_params.extend([f'%{term}%', f'%{term}%'])
                
                sql = f"""
                SELECT id, title, content, app_source, created_at
                FROM documents 
                WHERE {search_condition}
                ORDER BY created_at DESC 
                LIMIT ?
                """
                params = tuple(like_params + [limit])
            
            with db_manager.get_kenny_connection() as conn:
                cursor = conn.execute(sql, params)
                rows = cursor.fetchall()
                
                results = []
                for row in rows:
                    results.append({
                        "id": row[0],
                        "title": row[1] or "Untitled",
                        "content": (row[2] or "")[:300],  # Truncate content
                        "source": row[3],
                        "created_at": row[4] or "",
                        "score": 0.8  # Fake score for compatibility
                    })
                
                logger.info(f"SQL fallback found {len(results)} results for '{query}' with terms: {search_terms}")
                return results
                
        except Exception as e:
            logger.error(f"SQL fallback search failed: {e}")
            return []

    async def execute_tool(self, tool_name: str, parameters: Dict[str, Any]) -> Dict[str, Any]:
        """Execute a specific tool with parameters"""
        if tool_name == "search_documents":
            query = parameters.get("query", "")
            limit = parameters.get("limit", 20)
            sources = parameters.get("sources")
            
            # Try orchestrator first
            cmd_args = ["search", query, "--limit", str(limit)]
            if sources:
                cmd_args.extend(["--types", sources])  # Use --types not --sources
            
            result = await self.execute_command(*cmd_args)
            
            # Check if we got results
            if result.get("status") == "success":
                data = result.get("data", {})
                results = data.get("results", [])
                
                if not results:  # No results from orchestrator, use SQL fallback
                    logger.info(f"Orchestrator returned 0 results for '{query}', trying SQL fallback")
                    sql_results = self._sql_fallback_search(query, limit)
                    
                    if sql_results:
                        return {
                            "status": "success", 
                            "data": {
                                "results": sql_results,
                                "search_type": "sql_fallback"
                            }
                        }
            
            return result
        
        elif tool_name == "get_system_status":
            return await self.execute_command("status")
        
        elif tool_name == "analyze_meeting_threads":
            since_days = parameters.get("since_days", 30)
            return await self.execute_command("meeting", "analyze-threads", "--since-days", str(since_days))
        
        elif tool_name == "propose_meeting_slots":
            participants = parameters.get("participants", "")
            duration = parameters.get("duration", 60)
            return await self.execute_command("meeting", "propose-slots", participants, "--duration", str(duration))
        
        elif tool_name == "search_contact_specific":
            contact_id = parameters.get("contact_id")
            query = parameters.get("query", "")
            if not contact_id:
                return {"status": "error", "error": "contact_id required"}
            
            # Get contact thread and search within it
            thread = contact_service.get_contact_thread(contact_id, 100)
            if not thread:
                return {"status": "error", "error": "Contact not found"}
            
            # Filter messages by query if provided
            if query:
                filtered_messages = [
                    msg for msg in thread.messages 
                    if query.lower() in msg.get('content', '').lower() or 
                       query.lower() in msg.get('title', '').lower()
                ]
            else:
                filtered_messages = thread.messages
            
            return {
                "status": "success",
                "data": {
                    "contact_name": thread.display_name,
                    "results": filtered_messages[:parameters.get("limit", 10)],
                    "total_count": len(filtered_messages)
                }
            }
        
        elif tool_name == "get_recent_messages":
            # Handle parameters with proper defaults
            days = parameters.get("days", 7)
            source = parameters.get("source")
            limit = parameters.get("limit", 50)
            
            # Import the function from ollama_kenny
            from ollama_kenny import get_recent_messages
            
            try:
                result = get_recent_messages(days=days, source=source, limit=limit)
                return {"status": "success", "data": result}
            except Exception as e:
                logger.error(f"get_recent_messages failed: {e}")
                return {"status": "error", "error": str(e)}
        
        else:
            return {"status": "error", "error": f"Unknown tool: {tool_name}"}

orchestrator_service = OrchestratorService(ORCHESTRATOR_PATH)

# Available orchestrator tools for LLM
@app.get("/tools", dependencies=[Depends(verify_api_key)])
async def list_available_tools():
    """List available orchestrator_cli tools for LLM use"""
    return {
        "tools": [
            {
                "name": "search_documents",
                "description": "Search across all user documents and messages",
                "parameters": {
                    "query": {"type": "string", "required": True},
                    "limit": {"type": "integer", "default": 20},
                    "sources": {"type": "string", "description": "Comma-separated: WhatsApp,Mail,Messages,Calendar,Contacts"}
                }
            },
            {
                "name": "search_contact_specific",
                "description": "Search within a specific contact's thread",
                "parameters": {
                    "contact_id": {"type": "string", "required": True},
                    "query": {"type": "string", "required": False},
                    "limit": {"type": "integer", "default": 10}
                }
            },
            {
                "name": "analyze_meeting_threads",
                "description": "Analyze email threads for meeting opportunities",
                "parameters": {
                    "since_days": {"type": "integer", "default": 30}
                }
            },
            {
                "name": "propose_meeting_slots",
                "description": "Propose meeting time slots",
                "parameters": {
                    "participants": {"type": "string", "required": True},
                    "duration": {"type": "integer", "default": 60}
                }
            },
            {
                "name": "get_recent_messages",
                "description": "Get recent messages from the last N days",
                "parameters": {
                    "days": {"type": "integer", "default": 7},
                    "source": {"type": "string", "description": "Filter by source: whatsapp, mail, messages, calendar, contacts"},
                    "limit": {"type": "integer", "default": 50}
                }
            },
            {
                "name": "get_system_status",
                "description": "Get system status and health",
                "parameters": {}
            }
        ]
    }

# Tool execution endpoint for LLM
@app.post("/tools/execute", dependencies=[Depends(verify_api_key)])
async def execute_tool(request: ToolCall):
    """Execute orchestrator tool with parameters"""
    try:
        result = await orchestrator_service.execute_tool(request.name, request.parameters)
        return {
            "execution_id": request.execution_id,
            **result
        }
    except Exception as e:
        logger.error(f"Tool execution failed: {e}")
        return {
            "execution_id": request.execution_id,
            "status": "error", 
            "error": str(e)
        }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="info")