#!/usr/bin/env python3
"""
Direct Mail ingestion from Apple Mail database to Kenny.
Bypasses the Swift implementation issues with foreign key constraints.
"""

import sqlite3
import hashlib
import uuid
from datetime import datetime
import os
from pathlib import Path

class DirectMailIngester:
    def __init__(self):
        self.kenny_db = "/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db"
        self.mail_db = os.path.expanduser("~/Library/Mail/V10/MailData/Envelope Index")
        self.processed = 0
        self.errors = 0
        
    def clear_existing_mail(self):
        """Clear existing Mail data for fresh import"""
        conn = sqlite3.connect(self.kenny_db)
        cursor = conn.cursor()
        
        # Delete in correct order to respect foreign keys
        cursor.execute("DELETE FROM emails WHERE document_id IN (SELECT id FROM documents WHERE app_source = 'Mail')")
        cursor.execute("DELETE FROM documents WHERE app_source = 'Mail'")
        
        conn.commit()
        count = cursor.rowcount
        conn.close()
        
        print(f"Cleared {count} existing Mail documents")
        
    def ingest_mail(self, limit=None):
        """Ingest mail from Apple Mail database"""
        print(f"Opening Mail database: {self.mail_db}")
        
        # Open both databases
        mail_conn = sqlite3.connect(self.mail_db)
        mail_conn.row_factory = sqlite3.Row
        kenny_conn = sqlite3.connect(self.kenny_db)
        
        try:
            # Query emails from Mail database
            query = """
                SELECT 
                    m.ROWID as mail_id,
                    s.subject,
                    a.address as from_address,
                    a.comment as from_name,
                    m.date_sent,
                    m.date_received,
                    m.read,
                    m.flagged,
                    mb.url as mailbox,
                    m.size
                FROM messages m
                LEFT JOIN subjects s ON m.subject = s.ROWID
                LEFT JOIN addresses a ON m.sender = a.ROWID
                LEFT JOIN mailboxes mb ON m.mailbox = mb.ROWID
                WHERE m.deleted = 0
                ORDER BY m.date_received DESC
            """
            
            if limit:
                query += f" LIMIT {limit}"
                
            print(f"Querying Mail database...")
            mail_cursor = mail_conn.execute(query)
            
            kenny_cursor = kenny_conn.cursor()
            
            # Process each email
            batch = []
            email_batch = []
            
            for row in mail_cursor:
                try:
                    # Generate document ID
                    doc_id = str(uuid.uuid4())
                    
                    # Extract data
                    mail_id = row['mail_id']
                    subject = row['subject'] or "No Subject"
                    from_address = row['from_address'] or "unknown@unknown.com"
                    from_name = row['from_name'] or from_address.split('@')[0]
                    
                    # Convert Mac epoch (2001-01-01) to Unix epoch
                    MAC_EPOCH_OFFSET = 978307200
                    date_sent = (row['date_sent'] or 0) + MAC_EPOCH_OFFSET if row['date_sent'] else int(datetime.now().timestamp())
                    date_received = (row['date_received'] or 0) + MAC_EPOCH_OFFSET if row['date_received'] else date_sent
                    
                    # Create content (no snippet available in this schema)
                    content = f"{subject}\n{from_name} <{from_address}>"
                    
                    # Create hash
                    hash_str = hashlib.sha256(f"{mail_id}{subject}{from_address}".encode()).hexdigest()
                    
                    # Prepare document data
                    doc_data = (
                        doc_id,
                        "email",
                        "Mail",
                        subject[:500],  # title
                        content[:2000],  # content (truncate for storage)
                        f"mail-{mail_id}",  # source_id
                        f"message://mail-{mail_id}",  # source_path
                        hash_str,
                        date_received,  # created_at
                        date_received,  # updated_at
                        int(datetime.now().timestamp()),  # last_seen_at
                        False  # deleted
                    )
                    
                    batch.append(doc_data)
                    
                    # Prepare email data
                    email_data = (
                        doc_id,  # document_id (PRIMARY KEY)
                        None,  # thread_id
                        f"mail-{mail_id}",  # message_id
                        from_address,
                        from_name,
                        None,  # to_addresses
                        None,  # cc_addresses
                        None,  # bcc_addresses
                        date_sent,
                        date_received,
                        bool(row['read']),
                        bool(row['flagged']),
                        row['mailbox'] or "INBOX",
                        subject[:200] if subject else None,  # Use subject as snippet
                        False,  # has_attachments (could be enhanced)
                        None  # attachment_names
                    )
                    
                    email_batch.append(email_data)
                    
                    # Process in batches of 500
                    if len(batch) >= 500:
                        self._insert_batch(kenny_cursor, batch, email_batch)
                        kenny_conn.commit()
                        print(f"Processed {self.processed} emails...")
                        batch = []
                        email_batch = []
                        
                except Exception as e:
                    self.errors += 1
                    print(f"Error processing mail {row['mail_id']}: {e}")
                    continue
            
            # Insert remaining batch
            if batch:
                self._insert_batch(kenny_cursor, batch, email_batch)
                kenny_conn.commit()
                
        finally:
            mail_conn.close()
            kenny_conn.close()
            
        print(f"\nMail ingestion complete!")
        print(f"Processed: {self.processed} emails")
        print(f"Errors: {self.errors}")
        
    def _insert_batch(self, cursor, doc_batch, email_batch):
        """Insert a batch of documents and emails"""
        # Insert documents first
        cursor.executemany("""
            INSERT OR REPLACE INTO documents 
            (id, type, app_source, title, content, source_id, source_path, hash, 
             created_at, updated_at, last_seen_at, deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, doc_batch)
        
        # Then insert emails (foreign key references documents)
        cursor.executemany("""
            INSERT OR REPLACE INTO emails
            (document_id, thread_id, message_id, from_address, from_name,
             to_addresses, cc_addresses, bcc_addresses, date_sent, date_received,
             is_read, is_flagged, mailbox, snippet, has_attachments, attachment_names)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, email_batch)
        
        self.processed += len(doc_batch)
        
    def verify_results(self):
        """Verify the ingestion results"""
        conn = sqlite3.connect(self.kenny_db)
        cursor = conn.cursor()
        
        # Count documents
        cursor.execute("SELECT COUNT(*) FROM documents WHERE app_source = 'Mail'")
        doc_count = cursor.fetchone()[0]
        
        # Count emails
        cursor.execute("SELECT COUNT(*) FROM emails")
        email_count = cursor.fetchone()[0]
        
        # Sample emails
        cursor.execute("""
            SELECT d.title, e.from_name, e.from_address, 
                   datetime(e.date_received, 'unixepoch') as date
            FROM documents d
            JOIN emails e ON d.id = e.document_id
            WHERE d.app_source = 'Mail'
            ORDER BY e.date_received DESC
            LIMIT 5
        """)
        
        samples = cursor.fetchall()
        
        conn.close()
        
        print(f"\n=== Verification ===")
        print(f"Documents in database: {doc_count}")
        print(f"Emails in database: {email_count}")
        print(f"\nRecent emails:")
        for title, from_name, from_addr, date in samples:
            print(f"  - {date}: {title[:50]} from {from_name} <{from_addr}>")

if __name__ == "__main__":
    import sys
    
    ingester = DirectMailIngester()
    
    # Check if Mail database exists
    if not os.path.exists(ingester.mail_db):
        print(f"ERROR: Mail database not found at {ingester.mail_db}")
        sys.exit(1)
    
    print("=" * 70)
    print("DIRECT MAIL INGESTION")
    print("=" * 70)
    
    # Clear existing mail data
    ingester.clear_existing_mail()
    
    # Ingest all mail (or specify a limit for testing)
    limit = None  # Set to a number like 1000 for testing
    ingester.ingest_mail(limit=limit)
    
    # Verify results
    ingester.verify_results()