#!/bin/bash

# Kenny API Startup Script
# Ensures all dependencies are ready and starts the FastAPI server

set -e

KENNY_ROOT="/Users/joshwlim/Documents/Kenny"
KENNY_API_DIR="$KENNY_ROOT/kenny-api"
MAC_TOOLS_DIR="$KENNY_ROOT/mac_tools"

echo "🚀 Starting Kenny API Server..."

# Check if we're in the right directory
cd "$KENNY_API_DIR"

# Check for required files
echo "📋 Checking dependencies..."

# Check orchestrator_cli binary
ORCHESTRATOR_PATH="$MAC_TOOLS_DIR/.build/release/orchestrator_cli"
if [ ! -f "$ORCHESTRATOR_PATH" ]; then
    echo "❌ orchestrator_cli not found at $ORCHESTRATOR_PATH"
    echo "   Building Swift orchestrator..."
    cd "$MAC_TOOLS_DIR"
    swift build -c release
    cd "$KENNY_API_DIR"
    
    if [ ! -f "$ORCHESTRATOR_PATH" ]; then
        echo "❌ Swift build failed. Please check mac_tools directory."
        exit 1
    fi
fi

echo "✅ orchestrator_cli found"

# Check kenny.db
KENNY_DB="$MAC_TOOLS_DIR/kenny.db"
if [ ! -f "$KENNY_DB" ]; then
    echo "❌ kenny.db not found at $KENNY_DB"
    echo "   Please ensure your main database exists"
    exit 1
fi

echo "✅ kenny.db found ($(du -h "$KENNY_DB" | cut -f1))"

# Check/initialize contact_memory.db
CONTACT_DB="$KENNY_API_DIR/contact_memory.db"
if [ ! -f "$CONTACT_DB" ]; then
    echo "🔄 contact_memory.db not found. Running contact resolution..."
    python3 contact_resolver.py
    
    if [ ! -f "$CONTACT_DB" ]; then
        echo "❌ Contact resolution failed"
        exit 1
    fi
fi

echo "✅ contact_memory.db found"

# Set API key if not already set
if [ -z "$KENNY_API_KEY" ]; then
    export KENNY_API_KEY="kenny-dev-key-$(date +%s)"
    echo "🔑 Generated temporary API key: $KENNY_API_KEY"
else
    echo "🔑 Using API key: ${KENNY_API_KEY:0:10}..."
fi

# Check Python dependencies
echo "📦 Checking Python dependencies..."
python3 -c "import fastapi, uvicorn, pydantic" 2>/dev/null || {
    echo "❌ Missing Python dependencies. Installing..."
    pip3 install fastapi uvicorn pydantic
}

echo "✅ Python dependencies ready"

# Test orchestrator connection
echo "🔍 Testing orchestrator connection..."
"$ORCHESTRATOR_PATH" status >/dev/null 2>&1 || {
    echo "⚠️  Orchestrator status check failed - this might be expected on first run"
}

# Display system info
echo ""
echo "📊 System Information:"
echo "   Kenny DB: $(sqlite3 "$KENNY_DB" "SELECT COUNT(*) FROM documents" 2>/dev/null || echo "N/A") documents"
echo "   Contact DB: $(sqlite3 "$CONTACT_DB" "SELECT COUNT(*) FROM kenny_contacts" 2>/dev/null || echo "N/A") contacts"
echo "   API Key: $KENNY_API_KEY"
echo "   Server: http://localhost:8080"
echo ""

# Start the server
echo "🌟 Starting FastAPI server..."
python3 main.py

# Note: The server runs on http://0.0.0.0:8080 for tunnel access
# Health check: curl -H "Authorization: Bearer $KENNY_API_KEY" http://localhost:8080/health