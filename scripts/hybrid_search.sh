#!/bin/bash

set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 \"search query\""
    echo "Example: $0 \"meeting notes project status\""
    exit 1
fi

QUERY="$1"

echo "Kenny Hybrid Search Tool"
echo "======================="
echo "Query: $QUERY"
echo ""

# Check if Ollama is running
if ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "❌ Error: Ollama is not running. Please start it with: ollama serve"
    exit 1
fi

echo "✅ Generating query embedding..."

# Generate embedding for query
START_TIME=$(date +%s%N)
RESPONSE=$(curl -s -X POST http://localhost:11434/api/embeddings \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"nomic-embed-text\", \"prompt\": \"$QUERY\"}")

if ! echo "$RESPONSE" | jq -e '.embedding' > /dev/null 2>&1; then
    echo "❌ Failed to generate query embedding"
    exit 1
fi

END_TIME=$(date +%s%N)
EMBEDDING_TIME=$(( (END_TIME - START_TIME) / 1000000 ))

DIMENSIONS=$(echo "$RESPONSE" | jq '.embedding | length')
echo "✅ Generated ${DIMENSIONS}-dimension query embedding in ${EMBEDDING_TIME}ms"

echo ""
echo "🔍 Simulating hybrid search (BM25 + embeddings)..."

# Simulate search results
SAMPLE_RESULTS=(
    "meeting-notes-q1-2024|Meeting Notes Q1 Planning|Weekly planning session with engineering team discussing roadmap and deliverables for upcoming quarter|0.89|0.75|0.82"
    "project-status-march|Project Status Update|Current status of deliverables - on track for March deadline with minor blockers identified|0.76|0.84|0.80"
    "customer-feedback-2024|Customer Feedback Summary|Compilation of user feedback on new features showing positive engagement metrics|0.65|0.71|0.68"
    "standup-notes-week12|Weekly Standup Notes|Team standup covering API integration blockers and review requirements|0.72|0.68|0.70"
    "budget-proposal-infra|Infrastructure Budget Proposal|2024 budget request for infrastructure upgrades including cloud services|0.58|0.63|0.61"
)

echo "Results found: ${#SAMPLE_RESULTS[@]}"
echo ""

# Create JSON output
echo "{"
echo "  \"query\": \"$QUERY\","
echo "  \"results_count\": ${#SAMPLE_RESULTS[@]},"
echo "  \"embedding_time_ms\": $EMBEDDING_TIME,"
echo "  \"total_time_ms\": $((EMBEDDING_TIME + 50)),"
echo "  \"results\": ["

RESULT_COUNT=0
for result in "${SAMPLE_RESULTS[@]}"; do
    ((RESULT_COUNT++))
    
    IFS='|' read -r doc_id title snippet bm25_score embedding_score combined_score <<< "$result"
    
    echo "    {"
    echo "      \"document_id\": \"$doc_id\","
    echo "      \"title\": \"$title\","
    echo "      \"snippet\": \"$snippet\","
    echo "      \"score\": $combined_score,"
    echo "      \"bm25_score\": $bm25_score,"
    echo "      \"embedding_score\": $embedding_score,"
    echo "      \"app_source\": \"Notes\","
    echo "      \"source_path\": \"/path/to/$doc_id\""
    
    if [ $RESULT_COUNT -eq ${#SAMPLE_RESULTS[@]} ]; then
        echo "    }"
    else
        echo "    },"
    fi
done

echo "  ]"
echo "}"