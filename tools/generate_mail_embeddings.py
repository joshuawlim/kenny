#!/usr/bin/env python3
"""
Focused Mail embeddings generator for Kenny.
Generates embeddings specifically for Mail documents that are missing them.
"""

import sqlite3
import json
import requests
import time
import sys
from datetime import datetime
from typing import List, Dict, Optional, Tuple
import struct

class MailEmbeddingsGenerator:
    def __init__(self, db_path: str = "/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db"):
        self.db_path = db_path
        self.ollama_url = "http://localhost:11434/api/embeddings"
        self.model = "nomic-embed-text"
        self.batch_size = 10  # Smaller batch size for Mail processing
        self.total_processed = 0
        self.total_failed = 0
        self.start_time = None
        
    def get_mail_documents_without_embeddings(self, limit: int = 100) -> List[Tuple[str, str, str]]:
        """Get Mail documents that don't have embeddings yet"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        query = """
        SELECT DISTINCT d.id, d.title, d.content
        FROM documents d
        LEFT JOIN chunks c ON d.id = c.document_id
        LEFT JOIN embeddings e ON c.id = e.chunk_id
        WHERE d.app_source = 'Mail'
           AND e.id IS NULL
           AND d.content IS NOT NULL
           AND LENGTH(TRIM(d.content)) > 0
        LIMIT ?
        """
        
        cursor.execute(query, (limit,))
        results = cursor.fetchall()
        conn.close()
        
        return results
    
    def get_mail_embeddings_status(self) -> Tuple[int, int]:
        """Get Mail documents total and with embeddings"""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        # Total Mail documents
        cursor.execute("SELECT COUNT(*) FROM documents WHERE app_source = 'Mail' AND content IS NOT NULL AND LENGTH(TRIM(content)) > 0")
        total = cursor.fetchone()[0]
        
        # Mail documents with embeddings
        cursor.execute("""
            SELECT COUNT(DISTINCT d.id)
            FROM documents d
            JOIN chunks c ON d.id = c.document_id
            JOIN embeddings e ON c.id = e.chunk_id
            WHERE d.app_source = 'Mail'
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
                
            # Truncate if too long
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
                print(f"❌ API Error: {response.status_code}")
                return None
                
        except requests.exceptions.Timeout:
            print(f"⏰ Timeout for text (length: {len(text)})")
            return None
        except Exception as e:
            print(f"❌ Error generating embedding: {e}")
            return None
    
    def serialize_embedding(self, embedding: List[float]) -> bytes:
        """Serialize embedding vector to bytes for SQLite BLOB storage"""
        return struct.pack('d' * len(embedding), *embedding)
    
    def store_embedding(self, document_id: str, title: str, content: str, embedding: List[float]) -> bool:
        """Store embedding in database"""
        try:
            import uuid
            conn = sqlite3.connect(self.db_path)
            cursor = conn.cursor()
            
            # Create or get chunk
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
            
            # Store embedding with correct schema (vector, not embedding)
            embedding_blob = self.serialize_embedding(embedding)
            embedding_id = str(uuid.uuid4())
            cursor.execute("""
                INSERT OR REPLACE INTO embeddings (id, chunk_id, vector, model, dimensions, created_at)
                VALUES (?, ?, ?, ?, ?, strftime('%s', 'now'))
            """, (embedding_id, chunk_id, embedding_blob, self.model, len(embedding)))
            
            conn.commit()
            conn.close()
            return True
            
        except Exception as e:
            print(f"❌ Storage error for {document_id}: {e}")
            return False
    
    def process_batch(self, documents: List[Tuple[str, str, str]]) -> Tuple[int, int]:
        """Process a batch of Mail documents"""
        success_count = 0
        fail_count = 0
        
        for doc_id, title, content in documents:
            # Generate embedding
            embedding = self.generate_embedding(content)
            
            if embedding and len(embedding) == 768:
                # Store in database
                if self.store_embedding(doc_id, title or "", content, embedding):
                    success_count += 1
                    title_display = (title[:40] + "...") if title and len(title) > 40 else (title or "No title")
                    print(f"✅ {title_display}")
                else:
                    fail_count += 1
                    print(f"❌ Storage failed: {(title or doc_id)[:40]}")
            else:
                fail_count += 1
                print(f"❌ Embedding failed: {(title or doc_id)[:40]}")
        
        return success_count, fail_count
    
    def run(self):
        """Main processing loop for Mail embeddings"""
        self.start_time = time.time()
        
        print("=" * 70)
        print("KENNY MAIL EMBEDDINGS GENERATOR")
        print("=" * 70)
        
        # Get initial statistics
        total_mail, mail_with_embeddings = self.get_mail_embeddings_status()
        remaining = total_mail - mail_with_embeddings
        
        print(f"📧 Mail Documents Statistics:")
        print(f"   Total Mail documents: {total_mail:,}")
        print(f"   Mail docs with embeddings: {mail_with_embeddings:,}")
        print(f"   Mail docs NEEDING embeddings: {remaining:,}")
        print(f"📝 Using model: {self.model}")
        print(f"📦 Batch size: {self.batch_size}")
        print("-" * 70)
        
        if remaining == 0:
            print("✅ All Mail documents already have embeddings!")
            return
        
        # Process in batches
        batch_num = 0
        while True:
            batch_num += 1
            
            # Get next batch of Mail documents without embeddings
            documents = self.get_mail_documents_without_embeddings(self.batch_size)
            
            if not documents:
                print("\n✅ All Mail documents now have embeddings!")
                break
            
            print(f"\n📦 Processing Mail batch {batch_num} ({len(documents)} documents)...")
            
            # Process batch
            success, failed = self.process_batch(documents)
            self.total_processed += success
            self.total_failed += failed
            
            # Show progress
            elapsed = time.time() - self.start_time
            rate = self.total_processed / elapsed if elapsed > 0 else 0
            remaining_estimate = (remaining - self.total_processed) / rate if rate > 0 else 0
            
            print(f"📊 Batch {batch_num}: {success} ✅ / {failed} ❌")
            print(f"📈 Total: {self.total_processed:,} processed ({rate:.1f} docs/sec)")
            print(f"⏱️  Estimated remaining: {remaining_estimate/60:.1f} minutes")
            
            # Small delay
            time.sleep(0.5)
        
        # Final statistics
        elapsed = time.time() - self.start_time
        print("\n" + "=" * 70)
        print("✅ MAIL EMBEDDINGS GENERATION COMPLETE")
        print("=" * 70)
        print(f"📧 Total Mail processed: {self.total_processed:,}")
        print(f"❌ Total failed: {self.total_failed:,}")
        print(f"⏱️  Time elapsed: {elapsed:.1f} seconds ({elapsed/60:.1f} minutes)")
        print(f"📊 Average rate: {self.total_processed/elapsed:.1f} documents/second")
        
        # Final check
        total_mail, mail_with_embeddings = self.get_mail_embeddings_status()
        coverage = mail_with_embeddings / total_mail * 100 if total_mail > 0 else 0
        print(f"\n📈 Final Mail Coverage:")
        print(f"   📧 Mail docs with embeddings: {mail_with_embeddings:,} / {total_mail:,}")
        print(f"   📊 Coverage: {coverage:.1f}%")
        
        if coverage >= 99.0:
            print("🎉 Mail embeddings generation SUCCESSFUL!")
        else:
            print("⚠️  Some Mail documents still missing embeddings")

if __name__ == "__main__":
    generator = MailEmbeddingsGenerator()
    try:
        generator.run()
    except KeyboardInterrupt:
        print(f"\n\n⚠️  Interrupted by user")
        print(f"📊 Processed {generator.total_processed} Mail documents before interruption")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Error: {e}")
        sys.exit(1)