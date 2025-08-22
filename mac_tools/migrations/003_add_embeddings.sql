-- Migration: Add embeddings support
-- Version: 003
-- Description: Add tables for storing document chunks and their embeddings

-- Chunks table for storing text segments
CREATE TABLE IF NOT EXISTS chunks (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL,
    text TEXT NOT NULL,
    chunk_index INTEGER NOT NULL,
    start_offset INTEGER NOT NULL,
    end_offset INTEGER NOT NULL,
    metadata_json TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE
);

-- Embeddings table for storing vector representations
CREATE TABLE IF NOT EXISTS embeddings (
    id TEXT PRIMARY KEY,
    chunk_id TEXT NOT NULL,
    model TEXT NOT NULL,
    vector BLOB NOT NULL,  -- Store as binary for efficiency
    dimensions INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_chunks_document_id ON chunks(document_id);
CREATE INDEX IF NOT EXISTS idx_chunks_chunk_index ON chunks(document_id, chunk_index);
CREATE INDEX IF NOT EXISTS idx_embeddings_chunk_id ON embeddings(chunk_id);
CREATE INDEX IF NOT EXISTS idx_embeddings_model ON embeddings(model);

-- View for hybrid search results
CREATE VIEW IF NOT EXISTS searchable_chunks AS
SELECT 
    c.id as chunk_id,
    c.document_id,
    c.text,
    c.chunk_index,
    c.metadata_json,
    d.type as document_type,
    d.title as document_title,
    d.app_source,
    d.source_path,
    e.id as embedding_id,
    e.model as embedding_model,
    e.dimensions
FROM chunks c
JOIN documents d ON c.document_id = d.id
LEFT JOIN embeddings e ON c.id = e.chunk_id;

-- Function to calculate cosine similarity (stored as SQL for reference)
-- Note: Actual similarity calculation will be done in Swift for performance
-- The following would be implemented in application code:
-- CREATE FUNCTION cosine_similarity(a BLOB, b BLOB) RETURNS REAL
-- This is stored here for documentation purposes only