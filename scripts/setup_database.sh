#!/bin/bash

set -e

DB_PATH="${1:-$HOME/Library/Application Support/Assistant/assistant.db}"
MIGRATIONS_DIR="$(dirname "$0")/../mac_tools/migrations"

echo "Kenny Database Setup"
echo "==================="
echo "Database path: $DB_PATH"

# Create directory if it doesn't exist
mkdir -p "$(dirname "$DB_PATH")"

# Apply migrations in order
echo "Applying database migrations..."

for migration in "$MIGRATIONS_DIR"/*.sql; do
    if [[ -f "$migration" && ! "$migration" =~ \.disabled$ ]]; then
        echo "Applying $(basename "$migration")..."
        sqlite3 "$DB_PATH" < "$migration"
    fi
done

echo ""
echo "Verifying schema..."

# Check that embedding tables exist
TABLES=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('chunks', 'embeddings', 'documents');" | wc -l)

if [ "$TABLES" -eq 3 ]; then
    echo "✅ Core tables present: documents, chunks, embeddings"
else
    echo "❌ Missing core tables (found $TABLES/3)"
    exit 1
fi

# Check indexes
INDEXES=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%';" | wc -l)
echo "✅ Found $INDEXES database indexes"

# Check FTS5 tables
FTS_TABLES=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%_fts';" | wc -l)
if [ "$FTS_TABLES" -gt 0 ]; then
    echo "✅ FTS5 search tables present ($FTS_TABLES tables)"
else
    echo "⚠️  No FTS5 tables found - full-text search may not work"
fi

echo ""
echo "✅ Database schema setup complete!"
echo ""
echo "Sample usage:"
echo "  swift run db_cli stats --db-path=\"$DB_PATH\""
echo "  swift run db_cli ingest_embeddings --db-path=\"$DB_PATH\""