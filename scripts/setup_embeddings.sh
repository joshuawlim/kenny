#!/bin/bash

set -e

echo "Setting up embedding models for Kenny..."

if ! command -v ollama &> /dev/null; then
    echo "Error: Ollama is not installed. Please install it first:"
    echo "  brew install ollama"
    echo "  or download from: https://ollama.ai"
    exit 1
fi

if ! pgrep -x "ollama" > /dev/null; then
    echo "Starting Ollama service..."
    ollama serve &
    sleep 3
fi

echo "Pulling embedding models..."

echo "1. Pulling nomic-embed-text (768 dimensions, 274MB)..."
ollama pull nomic-embed-text

echo "2. Checking for other embedding models..."
echo "Currently only nomic-embed-text is supported and installed."

echo ""
echo "Testing embedding generation..."

TEST_RESPONSE=$(curl -s http://localhost:11434/api/embeddings -d '{
  "model": "nomic-embed-text",
  "prompt": "Hello, this is a test"
}')

if echo "$TEST_RESPONSE" | grep -q "embedding"; then
    echo "✅ Embedding service is working!"
    echo ""
    echo "Embedding dimensions:"
    echo "$TEST_RESPONSE" | jq '.embedding | length'
else
    echo "❌ Failed to generate embeddings. Response:"
    echo "$TEST_RESPONSE"
    exit 1
fi

echo ""
echo "Setup complete! You can now run:"
echo "  swift run db_cli ingest_embeddings"
echo ""
echo "To test hybrid search:"
echo "  swift run db_cli hybrid_search 'your search query'"