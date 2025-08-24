#!/usr/bin/env python3
"""
Generate embeddings for all Kenny documents using Ollama nomic-embed-text model.
This script processes all documents that don't have embeddings yet.
"""

import sqlite3
import json
import requests
import time
import sys
from datetime import datetime
from typing import List, Dict, Optional, Tuple
import struct

class EmbeddingsGenerator:
    def __init__(self, db_path: str = "/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db"):
        self.db_path = db_path
        self.ollama_url = "http://localhost:11434/api/embeddings"
        self.model = "nomic-embed-text"
        self.batch_size = 50
        self.total_processed = 0
        self.total_failed = 0
        self.start_time = None
        
    def get_documents_without_embeddings(self, limit: int = 1000) -> List[Tuple[str, str, str]]:
        """Get documents that don't have embeddings yet"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        query = """
        SELECT DISTINCT d.id, d.title, d.content
        FROM documents d
        LEFT JOIN chunks c ON d.id = c.document_id
        LEFT JOIN embeddings e ON c.id = e.chunk_id
        WHERE e.id IS NULL
           AND d.content IS NOT NULL
           AND LENGTH(TRIM(d.content)) > 0
        LIMIT ?
        """
        
        cursor.execute(query, (limit,))
        results = cursor.fetchall()
        conn.close()
        
        return results
    
    def get_total_documents_count(self) -> Tuple[int, int]:
        """Get total documents and documents with embeddings"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        # Total documents
        cursor.execute("SELECT COUNT(*) FROM documents WHERE content IS NOT NULL AND LENGTH(TRIM(content)) > 0")
        total = cursor.fetchone()[0]
        
        # Documents with embeddings
        cursor.execute("""
            SELECT COUNT(DISTINCT d.id)
            FROM documents d
            JOIN chunks c ON d.id = c.document_id
            JOIN embeddings e ON c.id = e.chunk_id
            WHERE d.content IS NOT NULL AND LENGTH(TRIM(d.content)) > 0
        """)
        with_embeddings = cursor.fetchone()[0]
        
        conn.close()
        return total, with_embeddings
    
    def generate_embedding(self, text: str) -> Optional[List[float]]:
        """Generate embedding for text using Ollama"""
        try:
            # Clean and prepare text
            text = text.strip()
            if not text:
                return None
                
            # Truncate if too long (nomic-embed-text has token limits)
            if len(text) > 8000:
                text = text[:8000]
            
            response = requests.post(
                self.ollama_url,
                json={"model": self.model, "prompt": text},
                timeout=30
            )
            
            if response.status_code == 200:
                data = response.json()
                return data.get('embedding')
            else:
                print(f"Error generating embedding: {response.status_code}")
                return None
                
        except requests.exceptions.Timeout:
            print(f"Timeout generating embedding for text (length: {len(text)})")
            return None
        except Exception as e:
            print(f"Error generating embedding: {e}")
            return None
    
    def serialize_embedding(self, embedding: List[float]) -> bytes:
        """Serialize embedding vector to bytes for SQLite BLOB storage"""
        # Pack as 768 doubles (8 bytes each)
        return struct.pack('d' * len(embedding), *embedding)
    
    def store_embedding(self, document_id: str, title: str, content: str, embedding: List[float]) -> bool:
        """Store embedding in database"""
        try:
            conn = sqlite3.connect(self.db_path)
            cursor = conn.cursor()
            
            # First, create or get chunk
            # Generate a deterministic chunk ID
            chunk_id = f"{document_id}_chunk_0"
            
            cursor.execute("""
                INSERT OR IGNORE INTO chunks (id, document_id, chunk_index, text, start_offset, end_offset, created_at, updated_at)
                VALUES (?, ?, 0, ?, 0, ?, strftime('%s', 'now'), strftime('%s', 'now'))
            """, (chunk_id, document_id, content, len(content)))
            
            cursor.execute("""
                SELECT id FROM chunks WHERE document_id = ? AND chunk_index = 0
            """, (document_id,))
            
            chunk_result = cursor.fetchone()
            if not chunk_result:
                conn.close()
                return False
                
            chunk_id = chunk_result[0]
            
            # Store embedding
            embedding_blob = self.serialize_embedding(embedding)
            cursor.execute("""
                INSERT OR REPLACE INTO embeddings (chunk_id, embedding, model, created_at)
                VALUES (?, ?, ?, datetime('now'))
            """, (chunk_id, embedding_blob, self.model))
            
            conn.commit()
            conn.close()
            return True
            
        except Exception as e:
            print(f"Error storing embedding for {document_id}: {e}")
            return False
    
    def process_batch(self, documents: List[Tuple[str, str, str]]) -> Tuple[int, int]:
        """Process a batch of documents"""
        success_count = 0
        fail_count = 0
        
        for doc_id, title, content in documents:
            # Generate embedding
            embedding = self.generate_embedding(content)
            
            if embedding and len(embedding) == 768:  # nomic-embed-text produces 768-dim vectors
                # Store in database
                if self.store_embedding(doc_id, title or "", content, embedding):
                    success_count += 1
                    print(f"✓ Embedded: {title[:50] if title else doc_id[:20]}...")
                else:
                    fail_count += 1
                    print(f"✗ Failed to store: {title[:50] if title else doc_id[:20]}")
            else:
                fail_count += 1
                print(f"✗ Failed to generate: {title[:50] if title else doc_id[:20]}")
        
        return success_count, fail_count
    
    def run(self):
        """Main processing loop"""
        self.start_time = time.time()
        
        print("=" * 70)
        print("KENNY EMBEDDINGS GENERATOR")
        print("=" * 70)
        
        # Get initial statistics
        total_docs, docs_with_embeddings = self.get_total_documents_count()
        print(f"\nDatabase Statistics:")
        print(f"  Total documents: {total_docs:,}")
        print(f"  Documents with embeddings: {docs_with_embeddings:,}")
        print(f"  Documents needing embeddings: {total_docs - docs_with_embeddings:,}")
        print(f"\nUsing model: {self.model}")
        print(f"Batch size: {self.batch_size}")
        print("-" * 70)
        
        # Process in batches
        batch_num = 0
        while True:
            batch_num += 1
            
            # Get next batch of documents without embeddings
            documents = self.get_documents_without_embeddings(self.batch_size)
            
            if not documents:
                print("\n✅ All documents have embeddings!")
                break
            
            print(f"\n📦 Processing batch {batch_num} ({len(documents)} documents)...")
            
            # Process batch
            success, failed = self.process_batch(documents)
            self.total_processed += success
            self.total_failed += failed
            
            # Show progress
            elapsed = time.time() - self.start_time
            rate = self.total_processed / elapsed if elapsed > 0 else 0
            print(f"\n  Batch complete: {success} succeeded, {failed} failed")
            print(f"  Total progress: {self.total_processed} processed ({rate:.1f} docs/sec)")
            
            # Small delay to avoid overwhelming Ollama
            time.sleep(0.1)
        
        # Final statistics
        elapsed = time.time() - self.start_time
        print("\n" + "=" * 70)
        print("EMBEDDINGS GENERATION COMPLETE")
        print("=" * 70)
        print(f"Total processed: {self.total_processed:,}")
        print(f"Total failed: {self.total_failed:,}")
        print(f"Time elapsed: {elapsed:.1f} seconds")
        print(f"Average rate: {self.total_processed/elapsed:.1f} documents/second")
        
        # Final check
        total_docs, docs_with_embeddings = self.get_total_documents_count()
        print(f"\nFinal Statistics:")
        print(f"  Documents with embeddings: {docs_with_embeddings:,} / {total_docs:,}")
        print(f"  Coverage: {docs_with_embeddings/total_docs*100:.1f}%")

if __name__ == "__main__":
    generator = EmbeddingsGenerator()
    try:
        generator.run()
    except KeyboardInterrupt:
        print("\n\n⚠️  Interrupted by user")
        print(f"Processed {generator.total_processed} documents before interruption")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Error: {e}")
        sys.exit(1)