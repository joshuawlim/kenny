#!/usr/bin/env python3
"""
Kenny Ollama Integration - Simplified Direct Ollama Chat with Tools
Uses Mistral with tool calling to query kenny.db
"""

import json
import sqlite3
import asyncio
import uuid
import re
from pathlib import Path
from typing import List, Dict, Any, Optional
from datetime import datetime

from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import ollama
from ollama import AsyncClient

# Configuration
KENNY_DB = Path("/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db")
CONTACT_DB = Path("/Users/joshwlim/Documents/Kenny/kenny-api/contact_memory.db")
MODEL = "mistral-small3.1:latest"  # Or "mistral:latest" for 7B

# Kenny System Prompt
KENNY_SYSTEM_PROMPT = """You are Kenny, a helpful AI assistant with access to the user's personal data.

You have access to a database containing:
- 57,000+ documents from WhatsApp messages, emails, calendar events, messages, and contacts
- 1,300+ contact profiles with relationships and interaction history

When users ask questions, you can search through their data to provide accurate, personalized responses.
Be concise but thorough. Reference specific information from the search results when available.

If you cannot find specific information, acknowledge this and offer to help in other ways."""

app = FastAPI(title="Kenny Ollama API")

# CORS Configuration
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000", "*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Session Memory Storage (in-memory for now)
session_memory: Dict[str, List[Dict[str, Any]]] = {}

def get_session_id() -> str:
    """Generate a new session ID"""
    return str(uuid.uuid4())

def add_to_session(session_id: str, message: Dict[str, Any]):
    """Add message to session memory"""
    if session_id not in session_memory:
        session_memory[session_id] = []
    session_memory[session_id].append(message)
    
    # Keep only last 20 messages to prevent memory overflow
    if len(session_memory[session_id]) > 20:
        session_memory[session_id] = session_memory[session_id][-20:]

def get_session_context(session_id: str) -> List[Dict[str, Any]]:
    """Get session conversation history"""
    return session_memory.get(session_id, [])

def fuzzy_match_name(query: str, full_name: str) -> float:
    """
    Calculate fuzzy match score between query and full name
    Returns score from 0.0 to 1.0 (higher is better match)
    """
    query = query.lower().strip()
    full_name = full_name.lower().strip()
    
    # Exact match
    if query == full_name:
        return 1.0
    
    # Split names into parts
    query_parts = re.split(r'\s+', query)
    name_parts = re.split(r'\s+', full_name)
    
    # Check if all query parts appear in name parts
    matches = 0
    for q_part in query_parts:
        for n_part in name_parts:
            if q_part in n_part or n_part in q_part:
                matches += 1
                break
    
    # Calculate base score
    base_score = matches / len(query_parts) if query_parts else 0
    
    # Bonus for partial matches within words
    if query in full_name:
        base_score += 0.2
    
    # Bonus for starting matches
    if full_name.startswith(query) or any(part.startswith(query) for part in name_parts):
        base_score += 0.1
        
    return min(base_score, 1.0)

# Database Functions (Tools for Ollama)
def search_documents(query: str, limit: int = 10, source: Optional[str] = None) -> Dict[str, Any]:
    """
    Search through user's documents in kenny.db
    
    Args:
        query: Search query text
        limit: Maximum number of results to return (default 10)
        source: Optional filter by source (whatsapp, mail, messages, calendar, contacts)
    
    Returns:
        Dictionary containing search results with title, content, source, and metadata
    """
    try:
        conn = sqlite3.connect(KENNY_DB)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        
        sql = """
        SELECT id, title, content, app_source, created_at, metadata_json
        FROM documents
        WHERE (title LIKE ? OR content LIKE ?)
        """
        params = [f'%{query}%', f'%{query}%']
        
        if source:
            sql += " AND app_source = ?"
            params.append(source)
            
        sql += f" ORDER BY created_at DESC LIMIT {limit}"
        
        cursor.execute(sql, params)
        results = cursor.fetchall()
        conn.close()
        
        documents = []
        for row in results:
            documents.append({
                'id': row['id'],
                'title': row['title'] or 'Untitled',
                'content': row['content'][:500],  # Truncate for context
                'source': row['app_source'],
                'created_at': row['created_at'],
                'metadata': json.loads(row['metadata_json'] or '{}')
            })
        
        return {
            'status': 'success',
            'count': len(documents),
            'results': documents,
            'query': query
        }
        
    except Exception as e:
        return {
            'status': 'error',
            'error': str(e),
            'results': []
        }

def search_contacts(name: str) -> Dict[str, Any]:
    """
    Search for contacts by name or company using fuzzy matching
    
    Args:
        name: Contact name or company to search for
    
    Returns:
        Dictionary containing matching contact information, sorted by relevance
    """
    try:
        conn = sqlite3.connect(CONTACT_DB)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        
        # First get all contacts for fuzzy matching
        cursor.execute("""
            SELECT kc.kenny_contact_id, kc.display_name, 
                   cr.company, cr.role,
                   ci.identity_value, ci.identity_type
            FROM kenny_contacts kc
            LEFT JOIN contact_relationships cr ON kc.kenny_contact_id = cr.kenny_contact_id
            LEFT JOIN contact_identities ci ON kc.kenny_contact_id = ci.kenny_contact_id
        """)
        
        results = cursor.fetchall()
        conn.close()
        
        # Group by contact and calculate fuzzy match scores
        contacts = {}
        scored_contacts = []
        
        for row in results:
            contact_id = row['kenny_contact_id']
            if contact_id not in contacts:
                # Calculate fuzzy match score for name
                name_score = fuzzy_match_name(name, row['display_name'] or '')
                company_score = fuzzy_match_name(name, row['company'] or '') if row['company'] else 0
                
                # Use the higher score
                match_score = max(name_score, company_score)
                
                contacts[contact_id] = {
                    'id': contact_id,
                    'name': row['display_name'],
                    'company': row['company'],
                    'role': row['role'],
                    'identities': [],
                    'match_score': match_score
                }
            
            # Add identity if available
            if row['identity_value']:
                contacts[contact_id]['identities'].append({
                    'type': row['identity_type'],
                    'value': row['identity_value']
                })
        
        # Filter contacts with score > 0.3 and sort by score
        filtered_contacts = [c for c in contacts.values() if c['match_score'] > 0.3]
        filtered_contacts.sort(key=lambda x: x['match_score'], reverse=True)
        
        # Remove match_score from results (internal use only)
        for contact in filtered_contacts:
            del contact['match_score']
        
        # Limit results
        filtered_contacts = filtered_contacts[:10]
        
        return {
            'status': 'success',
            'count': len(filtered_contacts),
            'results': filtered_contacts,
            'fuzzy_search': True
        }
        
    except Exception as e:
        return {
            'status': 'error',
            'error': str(e),
            'results': []
        }

def get_recent_messages(days: int = 7, source: Optional[str] = None) -> Dict[str, Any]:
    """
    Get recent messages from the last N days
    
    Args:
        days: Number of days to look back (default 7)
        source: Optional filter by source
    
    Returns:
        Dictionary containing recent messages
    """
    try:
        conn = sqlite3.connect(KENNY_DB)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        
        sql = """
        SELECT title, content, app_source, created_at
        FROM documents
        WHERE datetime(created_at) >= datetime('now', ?)
        """
        params = [f'-{days} days']
        
        if source:
            sql += " AND app_source = ?"
            params.append(source)
            
        sql += " ORDER BY created_at DESC LIMIT 50"
        
        cursor.execute(sql, params)
        results = cursor.fetchall()
        conn.close()
        
        messages = []
        for row in results:
            messages.append({
                'title': row['title'] or 'Message',
                'content': row['content'][:200],
                'source': row['app_source'],
                'created_at': row['created_at']
            })
        
        return {
            'status': 'success',
            'count': len(messages),
            'days': days,
            'results': messages
        }
        
    except Exception as e:
        return {
            'status': 'error',
            'error': str(e),
            'results': []
        }

# Define tools for Ollama
AVAILABLE_TOOLS = [
    {
        'type': 'function',
        'function': {
            'name': 'search_documents',
            'description': 'Search through user documents from WhatsApp, Mail, Messages, Calendar, and Contacts',
            'parameters': {
                'type': 'object',
                'required': ['query'],
                'properties': {
                    'query': {
                        'type': 'string',
                        'description': 'The search query'
                    },
                    'limit': {
                        'type': 'integer',
                        'description': 'Maximum number of results (default 10)',
                        'default': 10
                    },
                    'source': {
                        'type': 'string',
                        'description': 'Filter by source: whatsapp, mail, messages, calendar, contacts',
                        'enum': ['whatsapp', 'mail', 'messages', 'calendar', 'contacts']
                    }
                }
            }
        }
    },
    {
        'type': 'function',
        'function': {
            'name': 'search_contacts',
            'description': 'Search for contacts by name or company',
            'parameters': {
                'type': 'object',
                'required': ['name'],
                'properties': {
                    'name': {
                        'type': 'string',
                        'description': 'Contact name or company to search for'
                    }
                }
            }
        }
    },
    {
        'type': 'function',
        'function': {
            'name': 'get_recent_messages',
            'description': 'Get recent messages from the last N days',
            'parameters': {
                'type': 'object',
                'properties': {
                    'days': {
                        'type': 'integer',
                        'description': 'Number of days to look back (default 7)',
                        'default': 7
                    },
                    'source': {
                        'type': 'string',
                        'description': 'Filter by source',
                        'enum': ['whatsapp', 'mail', 'messages', 'calendar', 'contacts']
                    }
                }
            }
        }
    }
]

# Map function names to actual functions
FUNCTION_MAP = {
    'search_documents': search_documents,
    'search_contacts': search_contacts,
    'get_recent_messages': get_recent_messages
}

class ChatRequest(BaseModel):
    message: str = Field(..., description="User message")
    context: Optional[List[Dict[str, str]]] = Field(default=None, description="Previous conversation context")
    session_id: Optional[str] = Field(default=None, description="Session ID for conversation memory")

@app.get("/health")
async def health():
    """Health check endpoint"""
    return {
        "status": "healthy",
        "model": MODEL,
        "kenny_db": KENNY_DB.exists(),
        "contact_db": CONTACT_DB.exists()
    }

@app.post("/chat")
async def chat_endpoint(request: ChatRequest):
    """
    Chat with Kenny using Ollama and tool calling
    """
    try:
        # Generate session ID if not provided
        session_id = request.session_id or get_session_id()
        
        # Build message history starting with system prompt
        messages = [
            {'role': 'system', 'content': KENNY_SYSTEM_PROMPT}
        ]
        
        # Add session context (conversation history)
        session_context = get_session_context(session_id)
        messages.extend(session_context)
        
        # Add context if provided (legacy support)
        if request.context:
            messages.extend(request.context)
            
        # Add current user message
        user_message = {'role': 'user', 'content': request.message}
        messages.append(user_message)
        
        # Store user message in session
        add_to_session(session_id, user_message)
        
        # First call to Ollama with tools
        response = ollama.chat(
            model=MODEL,
            messages=messages,
            tools=AVAILABLE_TOOLS,
            format='json' if 'json' in request.message.lower() else None
        )
        
        # Check if model wants to use tools
        if hasattr(response, 'message') and hasattr(response.message, 'tool_calls') and response.message.tool_calls:
            tool_results = []
            
            for tool_call in response.message.tool_calls:
                func_name = tool_call.function.name
                func_args = tool_call.function.arguments
                
                if func_name in FUNCTION_MAP:
                    # Execute the function
                    result = FUNCTION_MAP[func_name](**func_args)
                    tool_results.append({
                        'tool': func_name,
                        'result': result
                    })
                    
                    # Add tool response to messages
                    messages.append(response.message.model_dump())
                    messages.append({
                        'role': 'tool',
                        'content': json.dumps(result),
                        'name': func_name
                    })
            
            # Get final response with tool results
            final_response = ollama.chat(
                model=MODEL,
                messages=messages
            )
            
            # Store assistant response in session
            assistant_response = {'role': 'assistant', 'content': final_response.message.content}
            add_to_session(session_id, assistant_response)
            
            return {
                'response': final_response.message.content,
                'tools_used': [t['tool'] for t in tool_results],
                'tool_results': tool_results,
                'session_id': session_id
            }
        
        # No tools needed, return direct response
        assistant_response = {'role': 'assistant', 'content': response.message.content}
        add_to_session(session_id, assistant_response)
        
        return {
            'response': response.message.content,
            'tools_used': [],
            'tool_results': [],
            'session_id': session_id
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/chat/stream")
async def chat_stream(message: str, key: str = "demo-key", session_id: Optional[str] = None):
    """
    SSE streaming endpoint for chat
    """
    if key != "demo-key":
        raise HTTPException(status_code=401, detail="Invalid API key")
    
    async def generate():
        try:
            # Generate session ID if not provided
            current_session_id = session_id or get_session_id()
            
            # Send start event
            yield f"data: {json.dumps({'type': 'start', 'message': 'Processing...', 'session_id': current_session_id})}\n\n"
            
            # Build message history with session context
            messages = [
                {'role': 'system', 'content': KENNY_SYSTEM_PROMPT}
            ]
            
            # Add session context
            session_context = get_session_context(current_session_id)
            messages.extend(session_context)
            
            # Add current user message
            user_message = {'role': 'user', 'content': message}
            messages.append(user_message)
            
            # Store user message in session
            add_to_session(current_session_id, user_message)
            
            # First call with tools
            client = AsyncClient()
            response = await client.chat(
                model=MODEL,
                messages=messages,
                tools=AVAILABLE_TOOLS
            )
            
            # Process tool calls if needed
            if hasattr(response, 'message') and hasattr(response.message, 'tool_calls') and response.message.tool_calls:
                for tool_call in response.message.tool_calls:
                    func_name = tool_call.function.name
                    func_args = tool_call.function.arguments
                    
                    yield f"data: {json.dumps({'type': 'tool_start', 'tool': func_name})}\n\n"
                    
                    if func_name in FUNCTION_MAP:
                        result = FUNCTION_MAP[func_name](**func_args)
                        
                        yield f"data: {json.dumps({'type': 'tool_complete', 'tool': func_name, 'result_summary': f'Found {result.get("count", 0)} results'})}\n\n"
                        
                        # Add to messages
                        messages.append(response.message.model_dump())
                        messages.append({
                            'role': 'tool',
                            'content': json.dumps(result),
                            'name': func_name
                        })
                
                # Get final response
                final_response = await client.chat(
                    model=MODEL,
                    messages=messages
                )
                
                # Store assistant response in session
                assistant_response = {'role': 'assistant', 'content': final_response.message.content}
                add_to_session(current_session_id, assistant_response)
                
                yield f"data: {json.dumps({'type': 'response', 'message': final_response.message.content})}\n\n"
            else:
                # Direct response without tools
                assistant_response = {'role': 'assistant', 'content': response.message.content}
                add_to_session(current_session_id, assistant_response)
                
                yield f"data: {json.dumps({'type': 'response', 'message': response.message.content})}\n\n"
            
            yield f"data: {json.dumps({'type': 'done', 'session_id': current_session_id})}\n\n"
            
        except Exception as e:
            yield f"data: {json.dumps({'type': 'error', 'error': str(e)})}\n\n"
    
    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "Access-Control-Allow-Origin": "*"
        }
    )

if __name__ == "__main__":
    import uvicorn
    print(f"🚀 Starting Kenny Ollama API with {MODEL}")
    print(f"📊 Kenny DB: {KENNY_DB.exists()}")
    print(f"👥 Contact DB: {CONTACT_DB.exists()}")
    uvicorn.run(app, host="0.0.0.0", port=8080)