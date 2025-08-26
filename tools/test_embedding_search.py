#!/usr/bin/env python3
"""Test script to debug embedding search issues"""

import sqlite3
import numpy as np
import struct
import json

def deserialize_embedding(blob):
    """Deserialize a BLOB to a numpy array"""
    if blob is None:
        return None
    # Each float is 4 bytes
    num_floats = len(blob) // 4
    return np.array(struct.unpack(f'{num_floats}f', blob))

def cosine_similarity(a, b):
    """Calculate cosine similarity between two vectors"""
    dot_product = np.dot(a, b)
    norm_a = np.linalg.norm(a)
    norm_b = np.linalg.norm(b)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot_product / (norm_a * norm_b)

def test_embedding_search(db_path, query_text="Courtney"):
    """Test embedding search functionality"""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    # First, get a sample embedding to use as query (from a document with the query text)
    cursor.execute("""
        SELECT e.vector, d.title, d.content
        FROM embeddings e
        JOIN chunks c ON e.chunk_id = c.id
        JOIN documents d ON c.document_id = d.id
        WHERE d.content LIKE ? OR d.title LIKE ?
        LIMIT 1
    """, (f'%{query_text}%', f'%{query_text}%'))
    
    result = cursor.fetchone()
    if not result:
        print(f"No documents found containing '{query_text}'")
        return
    
    query_vector = deserialize_embedding(result[0])
    print(f"Using embedding from document: {result[1][:50]}...")
    print(f"Query vector shape: {query_vector.shape}")
    
    # Now search for similar documents
    cursor.execute("""
        SELECT d.id, d.title, d.content, e.vector, c.text
        FROM documents d
        JOIN chunks c ON d.id = c.document_id
        JOIN embeddings e ON c.id = e.chunk_id
        WHERE e.vector IS NOT NULL
        LIMIT 100
    """)
    
    results = []
    for row in cursor.fetchall():
        doc_id, title, content, vector_blob, chunk_text = row
        doc_vector = deserialize_embedding(vector_blob)
        if doc_vector is not None:
            similarity = cosine_similarity(query_vector, doc_vector)
            results.append({
                'id': doc_id,
                'title': title[:50],
                'similarity': float(similarity),
                'snippet': (chunk_text or content or '')[:100]
            })
    
    # Sort by similarity
    results.sort(key=lambda x: x['similarity'], reverse=True)
    
    print(f"\nTop 10 most similar documents:")
    for i, res in enumerate(results[:10], 1):
        print(f"{i}. Score: {res['similarity']:.4f} - {res['title']}")
        print(f"   Snippet: {res['snippet'][:80]}...")
    
    # Check distribution of similarity scores
    scores = [r['similarity'] for r in results]
    print(f"\nSimilarity score statistics:")
    print(f"  Min: {min(scores):.4f}")
    print(f"  Max: {max(scores):.4f}")
    print(f"  Mean: {np.mean(scores):.4f}")
    print(f"  Std: {np.std(scores):.4f}")
    
    # Count how many have similarity > 0.1
    high_similarity = sum(1 for s in scores if s > 0.1)
    print(f"  Documents with similarity > 0.1: {high_similarity}/{len(scores)}")
    
    conn.close()

if __name__ == "__main__":
    test_embedding_search("/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db")