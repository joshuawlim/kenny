#!/bin/bash

# Simple integration test for Kenny Ollama API
echo "🧪 Testing Kenny Ollama Integration"
echo "=================================="

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test API health
echo -e "${BLUE}1. Testing API Health...${NC}"
if curl -s http://localhost:8080/health | jq '.status' | grep -q "healthy"; then
    echo -e "   ${GREEN}✅ API is healthy${NC}"
else
    echo -e "   ${RED}❌ API health check failed${NC}"
    exit 1
fi

# Test basic chat
echo -e "${BLUE}2. Testing Basic Chat...${NC}"
response=$(curl -s -X POST "http://localhost:8080/chat" \
  -H "Content-Type: application/json" \
  -d '{"message": "Hello Kenny"}')

if echo "$response" | jq -r '.response' | grep -i "hello\|hi\|help" >/dev/null; then
    echo -e "   ${GREEN}✅ Basic chat working${NC}"
else
    echo -e "   ${RED}❌ Basic chat failed${NC}"
    echo "   Response: $(echo "$response" | jq -r '.response')"
fi

# Test tool calling
echo -e "${BLUE}3. Testing Tool Calling...${NC}"
tool_response=$(curl -s -X POST "http://localhost:8080/chat" \
  -H "Content-Type: application/json" \
  -d '{"message": "Search for recent messages"}')

tools_used=$(echo "$tool_response" | jq -r '.tools_used | length')
if [ "$tools_used" -gt 0 ]; then
    echo -e "   ${GREEN}✅ Tool calling working${NC}"
    echo "   Tools used: $(echo "$tool_response" | jq -r '.tools_used[]' | tr '\n' ' ')"
else
    echo -e "   ${YELLOW}⚠️ Tool calling may not be triggered${NC}"
fi

# Test streaming
echo -e "${BLUE}4. Testing SSE Streaming...${NC}"
stream_test=$(curl -s -m 10 "http://localhost:8080/chat/stream?message=Hello&key=demo-key" | head -3)
if echo "$stream_test" | grep -q "data:" && echo "$stream_test" | grep -q "type"; then
    echo -e "   ${GREEN}✅ SSE streaming working${NC}"
else
    echo -e "   ${RED}❌ SSE streaming failed${NC}"
    echo "   Output: $stream_test"
fi

# Test database access
echo -e "${BLUE}5. Testing Database Access...${NC}"
db_response=$(curl -s -X POST "http://localhost:8080/chat" \
  -H "Content-Type: application/json" \
  -d '{"message": "How many documents do you have access to?"}')

if echo "$db_response" | jq -r '.response' | grep -i "document\|data\|57\|thousand" >/dev/null; then
    echo -e "   ${GREEN}✅ Database access working${NC}"
else
    echo -e "   ${YELLOW}⚠️ Database access unclear${NC}"
    echo "   Response: $(echo "$db_response" | jq -r '.response')"
fi

echo ""
echo -e "${GREEN}🎉 Integration test completed!${NC}"
echo "   API: http://localhost:8080"
echo "   Health: http://localhost:8080/health"
echo "   Frontend: http://localhost:3000"