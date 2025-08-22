#!/usr/bin/env python3
"""
WhatsApp Data Inserter for Kenny.db
Inserts transformed WhatsApp data into Kenny.db
"""

import json
import sqlite3
from pathlib import Path
from typing import Dict, List
import sys

class WhatsAppInserter:
    """Insert transformed WhatsApp data into Kenny.db"""
    
    def __init__(self, db_path: str):
        self.db_path = db_path
        self.conn = None
        self.cursor = None
    
    def connect(self):
        """Connect to the database"""
        self.conn = sqlite3.connect(self.db_path)
        self.cursor = self.conn.cursor()
        # Enable foreign keys
        self.cursor.execute("PRAGMA foreign_keys = ON")
    
    def disconnect(self):
        """Disconnect from the database"""
        if self.conn:
            self.conn.close()
    
    def check_existing_messages(self, thread_id: str) -> int:
        """Check how many messages already exist for this thread"""
        self.cursor.execute(
            "SELECT COUNT(*) FROM messages WHERE thread_id = ?",
            (thread_id,)
        )
        return self.cursor.fetchone()[0]
    
    def insert_message(self, msg_data: Dict) -> bool:
        """Insert a single message into the database"""
        doc = msg_data["document"]
        msg = msg_data["message"]
        
        try:
            # Insert into documents table
            self.cursor.execute("""
                INSERT OR IGNORE INTO documents (
                    id, type, title, content, app_source, source_id,
                    source_path, hash, created_at, updated_at, 
                    last_seen_at, deleted, metadata_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                doc["id"], doc["type"], doc["title"], doc["content"],
                doc["app_source"], doc["source_id"], doc["source_path"],
                doc["hash"], doc["created_at"], doc["updated_at"],
                doc["last_seen_at"], doc["deleted"], doc["metadata_json"]
            ))
            
            # Insert into messages table
            self.cursor.execute("""
                INSERT OR IGNORE INTO messages (
                    document_id, thread_id, from_contact, to_contacts,
                    date_sent, is_from_me, is_read, service, chat_name,
                    has_attachments, attachment_types
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                msg["document_id"], msg["thread_id"], msg["from_contact"],
                msg["to_contacts"], msg["date_sent"], msg["is_from_me"],
                msg["is_read"], msg["service"], msg["chat_name"],
                msg["has_attachments"], msg["attachment_types"]
            ))
            
            return True
            
        except sqlite3.IntegrityError as e:
            # Message already exists, skip
            return False
        except Exception as e:
            print(f"Error inserting message: {e}")
            raise
    
    def insert_chat(self, chat_data: Dict) -> Dict:
        """Insert all messages from a chat"""
        chat_name = chat_data["chat_name"]
        thread_id = chat_data["thread_id"]
        messages = chat_data["messages"]
        
        # Check existing messages
        existing_count = self.check_existing_messages(thread_id)
        
        inserted = 0
        skipped = 0
        errors = 0
        
        for msg_data in messages:
            try:
                if self.insert_message(msg_data):
                    inserted += 1
                else:
                    skipped += 1
            except Exception as e:
                errors += 1
                print(f"Error in chat '{chat_name}': {e}")
        
        return {
            "chat_name": chat_name,
            "total_messages": len(messages),
            "existing_before": existing_count,
            "inserted": inserted,
            "skipped": skipped,
            "errors": errors
        }
    
    def insert_all(self, transformed_data: List[Dict]) -> Dict:
        """Insert all transformed data"""
        results = []
        
        for chat_data in transformed_data:
            result = self.insert_chat(chat_data)
            results.append(result)
            
            # Commit after each chat for safety
            self.conn.commit()
        
        return results

def print_insertion_summary(results: List[Dict]):
    """Print summary of insertion results"""
    print("\n" + "="*60)
    print("INSERTION SUMMARY")
    print("="*60)
    
    total_inserted = 0
    total_skipped = 0
    total_errors = 0
    
    for result in results:
        print(f"\n{result['chat_name']}:")
        print(f"  Total messages: {result['total_messages']}")
        print(f"  Already in DB: {result['existing_before']}")
        print(f"  Newly inserted: {result['inserted']}")
        print(f"  Skipped (duplicates): {result['skipped']}")
        if result['errors'] > 0:
            print(f"  ERRORS: {result['errors']}")
        
        total_inserted += result['inserted']
        total_skipped += result['skipped']
        total_errors += result['errors']
    
    print("\n" + "-"*60)
    print(f"TOTAL INSERTED: {total_inserted}")
    print(f"TOTAL SKIPPED: {total_skipped}")
    if total_errors > 0:
        print(f"TOTAL ERRORS: {total_errors}")

def main():
    """Main execution function"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Insert WhatsApp data into Kenny.db")
    parser.add_argument(
        "--input",
        default="/Users/joshwlim/Documents/Kenny/transformed/whatsapp_transformed.json",
        help="Path to transformed JSON file"
    )
    parser.add_argument(
        "--db",
        default="/Users/joshwlim/Documents/Kenny/kenny.db",
        help="Path to Kenny.db"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Perform a dry run without inserting data"
    )
    
    args = parser.parse_args()
    
    # Check if input file exists
    input_path = Path(args.input)
    if not input_path.exists():
        print(f"Error: Input file not found: {input_path}")
        print("Please run the transformation script first:")
        print("  python tools/whatsapp_importer.py")
        sys.exit(1)
    
    # Load transformed data
    print(f"Loading transformed data from: {input_path}")
    with open(input_path, 'r', encoding='utf-8') as f:
        transformed_data = json.load(f)
    
    print(f"Loaded {len(transformed_data)} chats")
    
    if args.dry_run:
        print("\n" + "="*60)
        print("DRY RUN - No data will be inserted")
        print("="*60)
        
        total_messages = sum(chat["total_messages"] for chat in transformed_data)
        print(f"\nWould insert {total_messages} messages from {len(transformed_data)} chats")
        
        for chat in transformed_data:
            print(f"  - {chat['chat_name']}: {chat['total_messages']} messages")
        
        print("\nTo insert data, run without --dry-run flag")
        return
    
    # Perform insertion
    print(f"\nConnecting to database: {args.db}")
    inserter = WhatsAppInserter(args.db)
    
    try:
        inserter.connect()
        
        print("Starting insertion...")
        results = inserter.insert_all(transformed_data)
        
        # Print summary
        print_insertion_summary(results)
        
        print("\n" + "="*60)
        print("INSERTION COMPLETE")
        print("="*60)
        
    except Exception as e:
        print(f"\nError during insertion: {e}")
        sys.exit(1)
    finally:
        inserter.disconnect()

if __name__ == "__main__":
    main()