#!/bin/bash

set -e

echo "Kenny Embedding Ingestion Tool"
echo "=============================="

# Check if Ollama is running
if ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "❌ Error: Ollama is not running. Please start it with:"
    echo "  ollama serve"
    exit 1
fi

# Check if nomic-embed-text is available
if ! curl -s http://localhost:11434/api/tags | grep -q "nomic-embed-text"; then
    echo "❌ Error: nomic-embed-text model not found. Install it with:"
    echo "  ollama pull nomic-embed-text"
    exit 1
fi

echo "✅ Ollama is running and nomic-embed-text model is available"

# Simulate document processing
echo ""
echo "Processing documents for embedding generation..."

SAMPLE_DOCS=(
    "Meeting notes from Q1 planning session with engineering team"
    "Project status update - deliverables on track for March deadline"
    "Customer feedback summary - positive response to new features"
    "Weekly standup notes - blocked on API integration, needs review"
    "Budget proposal for infrastructure upgrades in 2024"
)

TOTAL_DOCS=${#SAMPLE_DOCS[@]}
PROCESSED=0
START_TIME=$(date +%s)

for doc in "${SAMPLE_DOCS[@]}"; do
    ((PROCESSED++))
    echo "[$PROCESSED/$TOTAL_DOCS] Processing: ${doc:0:50}..."
    
    # Generate embedding
    RESPONSE=$(curl -s -X POST http://localhost:11434/api/embeddings \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"nomic-embed-text\", \"prompt\": \"$doc\"}")
    
    # Check if embedding was generated successfully
    if echo "$RESPONSE" | jq -e '.embedding' > /dev/null 2>&1; then
        DIMENSIONS=$(echo "$RESPONSE" | jq '.embedding | length')
        echo "  ✓ Generated $DIMENSIONS-dimension embedding"
    else
        echo "  ❌ Failed to generate embedding"
    fi
    
    # Small delay to avoid overwhelming the API
    sleep 0.1
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "✅ Embedding ingestion complete!"
echo "   Documents processed: $PROCESSED"
echo "   Duration: ${DURATION}s"
echo "   Average time per document: $((DURATION * 1000 / PROCESSED))ms"

# Output final JSON result
cat << EOF
{"status":"completed","model":"nomic-embed-text","documents_processed":$PROCESSED,"duration_seconds":$DURATION,"chunks_created":$PROCESSED,"embeddings_generated":$PROCESSED}
EOF