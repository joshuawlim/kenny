# Kenny Ollama Integration

## Overview
Kenny now uses Ollama with Mistral 3.1 Small for direct LLM conversations with tool calling capabilities. This replaces the previous complex architecture with a simplified, more reliable approach.

## Architecture

```
Frontend (React/Next.js) ←→ Kenny Ollama API (Python/FastAPI) ←→ Ollama (Mistral 3.1 Small) ←→ kenny.db + contact_memory.db
```

### Key Components:
1. **Ollama Server** - Runs Mistral 3.1 Small locally on port 11434
2. **Kenny Ollama API** - Python FastAPI server with tool calling on port 8080
3. **Next.js Frontend** - React chat interface on port 3000

## Available Tools

Kenny can call these functions to access your data:

- **`search_documents(query, limit, source)`** - Search through 57K+ documents from WhatsApp, Mail, Messages, Calendar, and Contacts
- **`search_contacts(name)`** - Find contacts by name or company
- **`get_recent_messages(days, source)`** - Get recent activity from last N days

## Quick Start

### Option 1: Service Manager (Recommended)
```bash
# Start all services automatically
../scripts/service-manager.sh start

# Check status
../scripts/service-manager.sh status

# Open terminals for manual control
../scripts/service-manager.sh terminals

# Stop everything
../scripts/service-manager.sh stop
```

### Option 2: Manual Start
```bash
# 1. Start Ollama
ollama serve

# 2. Start Kenny API
cd kenny-api
python3 ollama_kenny.py

# 3. Start Frontend
cd v0-kenny-frontend
npm run dev
```

## Testing

Run the integration test to verify everything works:
```bash
../tests/test_integration.sh
```

This tests:
- ✅ API health
- ✅ Basic chat functionality
- ✅ Tool calling capabilities
- ✅ SSE streaming
- ✅ Database access

## Endpoints

### Kenny Ollama API (Port 8080)
- `GET /health` - Health check and system status
- `POST /chat` - Send message and get response with tool results
- `GET /chat/stream` - SSE streaming endpoint for real-time responses

### Frontend (Port 3000)
- Chat interface with real-time streaming responses
- Shows tool usage and processing steps

## Configuration

### Environment Variables
- `NEXT_PUBLIC_KENNY_API_KEY=demo-key` (Frontend)
- `KENNY_API_KEY=demo-key` (API, set automatically)

### Model Settings
- **Model**: `mistral-small3.1:latest`
- **Tool Support**: Full function calling capabilities
- **Response Format**: JSON for structured data

## Features

### What Works Now:
- ✅ Direct Ollama conversation with Mistral 3.1
- ✅ Tool calling to query kenny.db and contact_memory.db
- ✅ Real-time streaming responses
- ✅ Search through 57K+ personal documents
- ✅ Contact lookup and recent message retrieval
- ✅ Kenny system prompt with personality

### Improvements Over Previous Architecture:
- 🚀 **Faster** - Direct Ollama integration, no Swift orchestrator overhead
- 🎯 **Simpler** - Single Python API file vs complex multi-service architecture
- 🔧 **More Reliable** - Native Mistral tool calling vs custom prompt engineering
- 📊 **Better Logging** - Clear tool usage and response tracking

## Troubleshooting

### Common Issues:
1. **Port conflicts**: Use `../scripts/stop-all.sh` to kill all Kenny processes
2. **Ollama not running**: Start with `ollama serve` first
3. **Model not found**: Pull with `ollama pull mistral-small3.1:latest`
4. **Frontend 401 errors**: Check API keys match between frontend/.env.local and API

### Debug Commands:
```bash
# Check Ollama status
curl http://localhost:11434/api/version

# Test API health
curl http://localhost:8080/health

# Test direct chat
curl -X POST http://localhost:8080/chat -H "Content-Type: application/json" -d '{"message": "Hello"}'

# View API logs
tail -f /tmp/kenny-api.log
```

## Development

### File Structure:
```
kenny-api/
├── ollama_kenny.py          # Main API server
├── main.py                  # Legacy API (deprecated)
└── contact_memory.db        # Contact database

v0-kenny-frontend/
├── app/page.tsx             # Main chat interface
└── .env.local              # Environment config

Scripts:
├── scripts/service-manager.sh  # Service management
├── scripts/stop-all.sh        # Emergency stop
└── tests/test_integration.sh   # Integration tests
```

### Making Changes:
1. Edit `ollama_kenny.py` for API changes
2. Edit `v0-kenny-frontend/app/page.tsx` for UI changes
3. Restart services with `../scripts/service-manager.sh restart`
4. Run `../tests/test_integration.sh` to verify changes

---

## Migration from Previous Architecture

The new Ollama integration replaces:
- ❌ Swift orchestrator_cli tool calling
- ❌ Complex FastAPI LLM service wrapper  
- ❌ Multi-step tool selection and execution

With:
- ✅ Direct Ollama Python library integration
- ✅ Native Mistral tool calling
- ✅ Simplified single-file API

All your data remains the same - only the LLM integration has been simplified and improved.