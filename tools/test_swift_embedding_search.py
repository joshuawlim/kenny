#!/usr/bin/env python3
"""Test to debug why Swift embedding search returns no results"""

import sqlite3
import numpy as np
import struct

def deserialize_embedding(blob):
    """Deserialize a BLOB to a numpy array"""
    if blob is None:
        return None
    # Each float is 4 bytes
    num_floats = len(blob) // 4
    return np.array(struct.unpack(f'{num_floats}f', blob))

def test_query_structure(db_path):
    """Test the exact query structure used in Swift"""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    # This is the query from Database.swift searchEmbeddings method
    cursor.execute("""
        SELECT d.id, d.title, d.content, e.vector, c.text as chunk_text
        FROM documents d
        JOIN chunks c ON d.id = c.document_id
        JOIN embeddings e ON c.id = e.chunk_id
        WHERE e.vector IS NOT NULL
        ORDER BY d.created_at DESC
        LIMIT 10
    """)
    
    results = cursor.fetchall()
    print(f"Query returned {len(results)} results")
    
    if results:
        # Check first result
        doc_id, title, content, vector_blob, chunk_text = results[0]
        print(f"\nFirst result:")
        print(f"  ID: {doc_id}")
        print(f"  Title: {title[:50] if title else 'None'}")
        print(f"  Content: {content[:50] if content else 'None'}")
        print(f"  Chunk text: {chunk_text[:50] if chunk_text else 'None'}")
        print(f"  Vector blob size: {len(vector_blob) if vector_blob else 0} bytes")
        
        if vector_blob:
            vector = deserialize_embedding(vector_blob)
            print(f"  Vector shape: {vector.shape}")
            print(f"  Vector first 5 values: {vector[:5]}")
    
    # Now test without ORDER BY and with a larger LIMIT
    print("\n\nTesting simplified query:")
    cursor.execute("""
        SELECT COUNT(*) as count
        FROM documents d
        JOIN chunks c ON d.id = c.document_id
        JOIN embeddings e ON c.id = e.chunk_id
        WHERE e.vector IS NOT NULL
    """)
    
    count = cursor.fetchone()[0]
    print(f"Total documents with embeddings: {count}")
    
    # Test if the issue is with the LIMIT 1000 in Swift code
    cursor.execute("""
        SELECT d.id, e.vector
        FROM documents d
        JOIN chunks c ON d.id = c.document_id
        JOIN embeddings e ON c.id = e.chunk_id
        WHERE e.vector IS NOT NULL
        LIMIT 1
    """)
    
    result = cursor.fetchone()
    if result:
        doc_id, vector_blob = result
        vector = deserialize_embedding(vector_blob)
        print(f"\nSample embedding:")
        print(f"  Document ID: {doc_id}")
        print(f"  Vector shape: {vector.shape}")
        print(f"  Vector norm: {np.linalg.norm(vector):.4f}")
        print(f"  Vector mean: {np.mean(vector):.6f}")
        print(f"  Vector std: {np.std(vector):.6f}")
    
    conn.close()

if __name__ == "__main__":
    test_query_structure("/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db")