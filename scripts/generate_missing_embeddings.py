#!/usr/bin/env python3
"""
Simple Python script to generate embeddings for documents missing embeddings.
This bypasses the hanging Swift EmbeddingIngester by directly calling Ollama API.
"""

import sqlite3
import requests
import json
import time
import sys
import struct
from typing import List, Tuple, Optional

# Configuration
OLLAMA_URL = "http://localhost:11434"
MODEL = "nomic-embed-text"
DB_PATH = "/Users/joshwlim/Library/Application Support/Assistant/assistant.db"
BATCH_SIZE = 10
TIMEOUT = 30

def test_ollama_connection() -> bool:
    """Test if Ollama is running and has the required model."""
    try:
        response = requests.get(f"{OLLAMA_URL}/api/tags", timeout=5)
        if response.status_code == 200:
            models = response.json()
            model_names = [m['name'] for m in models.get('models', [])]
            return any(MODEL in name for name in model_names)
    except:
        pass
    return False

def get_documents_needing_embeddings(db_path: str) -> List[Tuple[str, str, str]]:
    """Get documents that don't have embeddings yet."""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    query = """
        SELECT d.id, d.type, d.content
        FROM documents d
        LEFT JOIN chunks c ON d.id = c.document_id
        WHERE d.content IS NOT NULL 
          AND d.content <> ''
          AND LENGTH(TRIM(d.content)) > 5
          AND c.id IS NULL
        ORDER BY LENGTH(d.content) ASC
        LIMIT 100
    """
    
    cursor.execute(query)
    results = cursor.fetchall()
    conn.close()
    
    return results

def generate_embedding(text: str) -> Optional[List[float]]:
    """Generate embedding for text using Ollama API."""
    try:
        payload = {
            "model": MODEL,
            "input": text
        }
        
        response = requests.post(
            f"{OLLAMA_URL}/api/embed",
            json=payload,
            timeout=TIMEOUT
        )
        
        if response.status_code == 200:
            data = response.json()
            embeddings = data.get("embeddings", [])
            if embeddings and len(embeddings) > 0:
                return embeddings[0]
    except Exception as e:
        print(f"Error generating embedding: {e}")
    
    return None

def serialize_vector(vector: List[float]) -> bytes:
    """Serialize float vector to bytes for SQLite BLOB storage."""
    return struct.pack(f'{len(vector)}f', *vector)

def store_embedding(db_path: str, document_id: str, text: str, vector: List[float]) -> bool:
    """Store chunk and embedding in database."""
    try:
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()
        
        # Create chunk
        chunk_id = f"{document_id}_chunk_0"
        timestamp = int(time.time() * 1000000000)  # nanoseconds
        
        cursor.execute("""
            INSERT OR REPLACE INTO chunks (
                id, document_id, text, chunk_index, start_offset, end_offset,
                metadata_json, created_at, updated_at
            ) VALUES (?, ?, ?, 0, 0, ?, '{}', ?, ?)
        """, (chunk_id, document_id, text, len(text), timestamp, timestamp))
        
        # Store embedding
        embedding_id = f"{chunk_id}_embedding"
        vector_blob = serialize_vector(vector)
        
        cursor.execute("""
            INSERT OR REPLACE INTO embeddings (
                id, chunk_id, model, vector, dimensions, created_at
            ) VALUES (?, ?, ?, ?, ?, ?)
        """, (embedding_id, chunk_id, MODEL, vector_blob, len(vector), timestamp))
        
        conn.commit()
        conn.close()
        return True
        
    except Exception as e:
        print(f"Error storing embedding for {document_id}: {e}")
        return False

def main():
    print("🚀 Kenny Missing Embeddings Generator")
    print("=" * 40)
    
    # Test Ollama connection
    if not test_ollama_connection():
        print("❌ Error: Ollama not running or nomic-embed-text model not available")
        print("Start Ollama and ensure nomic-embed-text model is installed:")
        print("  ollama serve")
        print("  ollama pull nomic-embed-text")
        sys.exit(1)
    
    print("✅ Ollama connection verified")
    
    # Get documents needing embeddings
    documents = get_documents_needing_embeddings(DB_PATH)
    print(f"📋 Found {len(documents)} documents needing embeddings")
    
    if not documents:
        print("✅ All documents already have embeddings!")
        return
    
    # Process documents
    processed = 0
    failed = 0
    start_time = time.time()
    
    for doc_id, doc_type, content in documents:
        print(f"[{processed + 1}/{len(documents)}] Processing {doc_type}: {content[:50]}...")
        
        # Generate embedding
        embedding = generate_embedding(content)
        if embedding is None:
            print(f"  ❌ Failed to generate embedding")
            failed += 1
            continue
        
        # Store in database
        if store_embedding(DB_PATH, doc_id, content, embedding):
            print(f"  ✅ Stored {len(embedding)}-dim embedding")
            processed += 1
        else:
            print(f"  ❌ Failed to store embedding")
            failed += 1
        
        # Small delay to avoid overwhelming Ollama
        time.sleep(0.1)
    
    duration = time.time() - start_time
    print("\n" + "=" * 40)
    print(f"✅ Embedding generation complete!")
    print(f"   Documents processed: {processed}")
    print(f"   Failed: {failed}")
    print(f"   Duration: {duration:.2f}s")
    print(f"   Average per document: {duration * 1000 / (processed + failed):.0f}ms")

if __name__ == "__main__":
    main()