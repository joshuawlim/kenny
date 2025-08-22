#!/usr/bin/env python3
"""
Merge WhatsApp data from root kenny.db into mac_tools/kenny.db
"""

import sqlite3
import sys
from pathlib import Path

def merge_databases():
    source_db = "/Users/joshwlim/Documents/Kenny/kenny.db"
    target_db = "/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db"
    
    print(f"Merging WhatsApp data from {source_db}")
    print(f"Into target database: {target_db}")
    
    # Connect to both databases
    source_conn = sqlite3.connect(source_db)
    target_conn = sqlite3.connect(target_db)
    
    try:
        # Attach source database to target connection
        target_conn.execute(f"ATTACH DATABASE '{source_db}' AS source_db")
        
        # Check existing WhatsApp messages in target
        cursor = target_conn.execute("""
            SELECT COUNT(*) FROM messages WHERE service = 'WhatsApp'
        """)
        existing_count = cursor.fetchone()[0]
        print(f"\nExisting WhatsApp messages in target: {existing_count}")
        
        # Check WhatsApp messages to import from source
        cursor = target_conn.execute("""
            SELECT COUNT(*) FROM source_db.messages WHERE service = 'WhatsApp'
        """)
        source_count = cursor.fetchone()[0]
        print(f"WhatsApp messages to import: {source_count}")
        
        if source_count == 0:
            print("No WhatsApp messages to import")
            return
        
        # Begin transaction
        target_conn.execute("BEGIN TRANSACTION")
        
        # Copy documents
        print("\nCopying documents...")
        target_conn.execute("""
            INSERT OR IGNORE INTO documents 
            SELECT * FROM source_db.documents 
            WHERE app_source = 'WhatsApp'
        """)
        
        # Copy messages
        print("Copying messages...")
        target_conn.execute("""
            INSERT OR IGNORE INTO messages
            SELECT * FROM source_db.messages
            WHERE service = 'WhatsApp'
        """)
        
        # Commit transaction
        target_conn.commit()
        print("Transaction committed successfully")
        
        # Verify the merge
        cursor = target_conn.execute("""
            SELECT COUNT(*) FROM messages WHERE service = 'WhatsApp'
        """)
        final_count = cursor.fetchone()[0]
        print(f"\nFinal WhatsApp message count: {final_count}")
        print(f"Messages added: {final_count - existing_count}")
        
        # Show summary of all data sources
        print("\n" + "="*50)
        print("FINAL DATABASE SUMMARY")
        print("="*50)
        cursor = target_conn.execute("""
            SELECT app_source, COUNT(*) as count 
            FROM documents 
            GROUP BY app_source 
            ORDER BY count DESC
        """)
        for row in cursor:
            print(f"{row[0]}: {row[1]:,} documents")
        
        print("\nMerge completed successfully!")
        
    except Exception as e:
        print(f"Error during merge: {e}")
        target_conn.rollback()
        sys.exit(1)
    finally:
        source_conn.close()
        target_conn.close()

if __name__ == "__main__":
    merge_databases()