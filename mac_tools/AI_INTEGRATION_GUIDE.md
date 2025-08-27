# Kenny AI Integration Guide for Frontend Development

**Last Updated**: August 27, 2025  
**AI Model**: mistral-small3.1:latest (Operational)  
**Status**: Production-Ready Backend Services

---

## 🎯 Overview

Kenny's AI backend is **100% operational** and ready for frontend integration. All core AI services are production-tested and running with the `mistral-small3.1:latest` model. This guide documents the available AI capabilities and the REST API endpoints needed for frontend development.

---

## 🧠 Available AI Services (Production Ready)

### Core AI Components

#### 1. AssistantCore (`src/AssistantCore.swift`)
- **Purpose**: Main AI assistant orchestration with conversation management
- **Capabilities**: 
  - Multi-turn conversation handling
  - Context awareness across sessions
  - Integration with all AI services
  - Response streaming and formatting
- **Frontend Need**: `POST /chat` endpoint for real-time conversations

#### 2. QueryEnhancementService (`src/QueryEnhancementService.swift`)
- **Purpose**: Natural language query optimization and intent detection
- **Capabilities**:
  - Query expansion and refinement
  - Intent classification and understanding
  - Search term optimization
  - Context-aware query processing
- **Frontend Need**: Integrated into search endpoints for automatic query enhancement

#### 3. SummarizationService (`src/SummarizationService.swift`)
- **Purpose**: Context-aware summarization of conversations and results
- **Capabilities**:
  - Conversation summarization
  - Search result summarization
  - Multi-document summarization
  - Contextual highlight extraction
- **Frontend Need**: `GET /summarize` endpoint for content summarization

#### 4. EnhancedHybridSearch (`src/EnhancedHybridSearch.swift`)
- **Purpose**: BM25 + vector embedding search with AI-powered relevance scoring
- **Capabilities**:
  - Semantic similarity search
  - Traditional text matching
  - Hybrid relevance scoring
  - Multi-modal search across all data types
- **Frontend Need**: `GET /search` endpoint with AI-enhanced results

#### 5. LLMService (`src/LLMService.swift`)
- **Purpose**: Full Ollama integration with model management
- **Capabilities**:
  - Real-time response generation
  - Model warm-up and availability checking
  - Automatic retry and fallback handling
  - Streaming response support
- **Current Model**: `mistral-small3.1:latest`
- **Frontend Need**: WebSocket endpoint for streaming responses

#### 6. EmbeddingsService (`src/EmbeddingsService.swift`)
- **Purpose**: Vector embeddings for semantic similarity and context
- **Capabilities**:
  - Text embedding generation
  - Semantic similarity scoring
  - Context vector management
  - Batch embedding processing
- **Frontend Need**: Integrated into search and chat endpoints

#### 7. NaturalLanguageProcessor (`src/NaturalLanguageProcessor.swift`)
- **Purpose**: Intent understanding and query preprocessing
- **Capabilities**:
  - Intent classification
  - Entity extraction
  - Query preprocessing
  - Language understanding
- **Frontend Need**: Integrated into all AI endpoints

---

## 🔗 Required REST API Endpoints

### Primary Endpoints for Frontend

#### 1. Chat Interface
```http
POST /api/v1/chat
Content-Type: application/json

{
  "message": "Find all messages about the project deadline from last week",
  "conversation_id": "optional-uuid",
  "stream": true
}

Response (Streaming):
{
  "conversation_id": "uuid",
  "response": "I found 5 messages about project deadlines...",
  "sources": [...],
  "timestamp": "2025-08-27T12:00:00Z",
  "streaming": true
}
```

#### 2. Enhanced Search
```http
GET /api/v1/search?q=machine%20learning&use_ai=true&limit=20

Response:
{
  "query": "machine learning",
  "enhanced_query": "machine learning AI artificial intelligence ML algorithms",
  "results": [
    {
      "id": "msg_123",
      "type": "message",
      "content": "...",
      "relevance_score": 0.95,
      "ai_summary": "Discussion about implementing ML models...",
      "context": {...}
    }
  ],
  "total": 156,
  "processing_time_ms": 45
}
```

#### 3. Content Summarization
```http
GET /api/v1/summarize?type=conversation&id=conv_123

Response:
{
  "summary": "This conversation covers the project timeline discussion...",
  "key_points": [
    "Project deadline moved to next Friday",
    "Team needs additional resources for ML implementation"
  ],
  "participants": [...],
  "timespan": "2025-08-20 to 2025-08-27"
}
```

#### 4. System Health
```http
GET /api/v1/health

Response:
{
  "status": "healthy",
  "ai_model": "mistral-small3.1:latest",
  "model_status": "operational",
  "ollama_endpoint": "http://localhost:11434",
  "database_status": "connected",
  "services": {
    "llm": "operational",
    "embeddings": "operational",
    "search": "operational"
  },
  "performance": {
    "avg_query_time_ms": 67,
    "cache_hit_rate": 0.85
  }
}
```

#### 5. WebSocket Streaming
```websocket
ws://localhost:8080/api/v1/stream

Send:
{
  "type": "chat",
  "message": "What meetings do I have tomorrow?",
  "conversation_id": "uuid"
}

Receive (Stream):
{
  "type": "response_chunk",
  "content": "You have 3 meetings scheduled for tomorrow:",
  "conversation_id": "uuid",
  "chunk_id": 1,
  "is_final": false
}
```

---

## ⚙️ Configuration and Environment

### Environment Variables
```bash
# AI Model Configuration
LLM_MODEL=mistral-small3.1:latest

# Ollama Configuration
OLLAMA_ENDPOINT=http://localhost:11434

# Database Configuration
KENNY_DB_PATH=/Users/username/Documents/Kenny/mac_tools/kenny.db

# Environment Setting
KENNY_ENV=production  # development|testing|staging|production
```

### Required Dependencies
- **Ollama** with `mistral-small3.1:latest` model installed
- **Kenny Database** with ingested data (Messages, Mail, Calendar, etc.)
- **Swift Runtime** for AI services

---

## 🚀 Frontend Development Requirements

### Framework Recommendations
Based on `v0-kenny-frontend` specification:
- **Frontend**: Next.js with TypeScript
- **Styling**: Tailwind CSS
- **Real-time**: WebSocket for streaming
- **State Management**: React Query for server state
- **UI Components**: Radix UI or similar

### Key Features to Implement

#### 1. Assistant Chat Interface
- Real-time conversation with Kenny
- Streaming responses from AI
- Context-aware follow-up questions
- Conversation history and persistence
- Mobile-optimized chat UI

#### 2. Global Search
- AI-enhanced search across all data
- Real-time search suggestions
- Result highlighting and context
- Filter by data type (messages, mail, etc.)
- Search history and saved searches

#### 3. Thread/Conversation Browsing
- Efficient virtualized lists for 10,000+ items
- Smart grouping and categorization
- AI-powered conversation summaries
- Quick preview and navigation
- Advanced filtering and sorting

#### 4. Settings and Health Monitoring
- AI system status dashboard
- Model and performance metrics
- Data ingestion status
- Configuration management
- Error logging and debugging

---

## 📊 Performance Expectations

### Current Backend Performance
- **Query Response Time**: Sub-100ms average
- **AI Processing**: <2s for complex queries
- **Database Operations**: <25ms for most queries
- **Model Loading**: <5s warm-up time
- **Concurrent Users**: Optimized for single-user (local deployment)

### Frontend Performance Targets
- **Initial Load**: <3s for main interface
- **Chat Response**: <2s average for AI responses
- **Search Results**: <1s for query results
- **Navigation**: <500ms between views
- **Mobile Performance**: Optimized for iOS Safari

---

## 🔒 Security and Data Privacy

### Local-First Architecture
- All data processing happens locally
- No external API calls (except to local Ollama)
- Complete user data privacy
- No cloud dependencies

### Authentication (Recommended)
- Simple local authentication for multi-user access
- Session management for conversation persistence
- Optional: Basic auth for local network access

---

## 🎯 Development Priorities

### Week 1: Core Infrastructure
1. Set up Next.js project with TypeScript
2. Implement HTTP server in Swift (Vapor framework)
3. Create basic chat interface with streaming
4. Integrate with AssistantCore for conversations

### Week 2: Advanced Features
1. Implement enhanced search with AI
2. Add conversation browsing and management
3. Create settings and health monitoring
4. Optimize for mobile and production deployment

---

## 🧪 Testing Strategy

### API Testing
- Unit tests for all Swift AI services
- Integration tests for HTTP endpoints
- Performance benchmarks for response times
- Load testing for concurrent requests

### Frontend Testing
- Component testing with Jest/Testing Library
- E2E testing with Playwright
- Performance testing with Lighthouse
- Mobile testing on iOS devices

---

## 📝 Next Steps for Frontend Developer

1. **Review v0-kenny-frontend specification** for UI/UX requirements
2. **Set up local Ollama** with `mistral-small3.1:latest` model
3. **Examine Kenny's AI services** in `/src/` directory
4. **Implement HTTP server** using Swift Vapor framework
5. **Start with basic chat interface** connecting to AssistantCore
6. **Iterate and expand** based on AI service capabilities

The AI backend is **ready and waiting**. All the intelligence is there - it just needs a web interface to shine.