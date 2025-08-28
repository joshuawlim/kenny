#!/usr/bin/env python3
"""
Safe Database Merge - Restore historical WhatsApp data while preserving latest bridge messages
"""

import sqlite3
import shutil
from datetime import datetime
from pathlib import Path

# Database paths
CURRENT_DB = "/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db"
BACKUP_DB = "/Users/joshwlim/Documents/Kenny/backups/kenny_20250822_140107_UTC.db"
MERGE_BACKUP = "/Users/joshwlim/Documents/Kenny/backups/kenny_pre_merge_backup.db"

def create_backup():
    """Create backup of current database before merge"""
    print("Creating backup of current database...")
    shutil.copy2(CURRENT_DB, MERGE_BACKUP)
    print(f"Backup created at: {MERGE_BACKUP}")

def analyze_databases():
    """Analyze both databases to understand the merge requirements"""
    print("\n=== DATABASE ANALYSIS ===")
    
    # Current database
    with sqlite3.connect(CURRENT_DB) as conn:
        cursor = conn.cursor()
        
        cursor.execute("SELECT COUNT(*) FROM documents WHERE app_source='WhatsApp'")
        current_whatsapp_count = cursor.fetchone()[0]
        
        cursor.execute("""
            SELECT MIN(datetime(created_at, 'unixepoch')), MAX(datetime(created_at, 'unixepoch'))
            FROM documents WHERE app_source='WhatsApp'
        """)
        current_date_range = cursor.fetchone()
        
        cursor.execute("SELECT COUNT(*) FROM documents")
        current_total = cursor.fetchone()[0]
        
    # Backup database
    with sqlite3.connect(BACKUP_DB) as conn:
        cursor = conn.cursor()
        
        cursor.execute("SELECT COUNT(*) FROM documents WHERE app_source='WhatsApp'")
        backup_whatsapp_count = cursor.fetchone()[0]
        
        cursor.execute("""
            SELECT MIN(datetime(created_at, 'unixepoch')), MAX(datetime(created_at, 'unixepoch'))
            FROM documents WHERE app_source='WhatsApp'
        """)
        backup_date_range = cursor.fetchone()
        
        cursor.execute("SELECT COUNT(*) FROM documents")
        backup_total = cursor.fetchone()[0]
    
    print(f"CURRENT DATABASE:")
    print(f"  WhatsApp messages: {current_whatsapp_count}")
    print(f"  Date range: {current_date_range[0]} to {current_date_range[1]}")
    print(f"  Total documents: {current_total}")
    
    print(f"\nBACKUP DATABASE:")
    print(f"  WhatsApp messages: {backup_whatsapp_count}")
    print(f"  Date range: {backup_date_range[0]} to {backup_date_range[1]}")
    print(f"  Total documents: {backup_total}")
    
    # Find the cutoff date for safe merge
    cutoff_date = "2025-08-20 00:00:00"  # Keep all current messages from Aug 20+
    
    with sqlite3.connect(BACKUP_DB) as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT COUNT(*) FROM documents 
            WHERE app_source='WhatsApp' AND datetime(created_at, 'unixepoch') < ?
        """, (cutoff_date,))
        historical_count = cursor.fetchone()[0]
    
    print(f"\nMERGE PLAN:")
    print(f"  Historical messages to restore (before {cutoff_date}): {historical_count}")
    print(f"  Current messages to preserve (after {cutoff_date}): {current_whatsapp_count}")
    print(f"  Expected total after merge: ~{historical_count + current_whatsapp_count}")
    
    return cutoff_date, historical_count

def merge_databases(cutoff_date: str):
    """Safely merge historical data from backup while preserving current messages"""
    print(f"\n=== MERGING DATABASES ===")
    print("Inserting historical WhatsApp messages...")
    
    current_conn = sqlite3.connect(CURRENT_DB)
    backup_conn = sqlite3.connect(BACKUP_DB)
    
    try:
        # Get historical WhatsApp messages from backup (before cutoff date)
        backup_cursor = backup_conn.cursor()
        backup_cursor.execute("""
            SELECT id, type, title, content, app_source, source_id, source_path, hash, 
                   created_at, updated_at, last_seen_at, deleted, metadata_json
            FROM documents 
            WHERE app_source='WhatsApp' AND datetime(created_at, 'unixepoch') < ?
            ORDER BY created_at
        """, (cutoff_date,))
        
        historical_messages = backup_cursor.fetchall()
        print(f"Found {len(historical_messages)} historical messages to merge")
        
        # Insert historical messages into current database
        current_cursor = current_conn.cursor()
        
        inserted_count = 0
        skipped_count = 0
        
        for msg in historical_messages:
            try:
                current_cursor.execute("""
                    INSERT OR IGNORE INTO documents 
                    (id, type, title, content, app_source, source_id, source_path, hash, 
                     created_at, updated_at, last_seen_at, deleted, metadata_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, msg)
                
                if current_cursor.rowcount > 0:
                    inserted_count += 1
                else:
                    skipped_count += 1
                    
            except sqlite3.Error as e:
                print(f"Error inserting message {msg[0]}: {e}")
                skipped_count += 1
        
        current_conn.commit()
        
        print(f"Merge complete:")
        print(f"  Inserted: {inserted_count} historical messages")
        print(f"  Skipped (duplicates): {skipped_count}")
        
        # Verify final counts
        current_cursor.execute("SELECT COUNT(*) FROM documents WHERE app_source='WhatsApp'")
        final_whatsapp_count = current_cursor.fetchone()[0]
        
        current_cursor.execute("SELECT COUNT(*) FROM documents")
        final_total_count = current_cursor.fetchone()[0]
        
        print(f"Final database stats:")
        print(f"  WhatsApp messages: {final_whatsapp_count}")
        print(f"  Total documents: {final_total_count}")
        
    except Exception as e:
        print(f"Error during merge: {e}")
        current_conn.rollback()
        raise
    finally:
        current_conn.close()
        backup_conn.close()

def rebuild_indexes():
    """Rebuild FTS and other indexes after merge"""
    print("\n=== REBUILDING INDEXES ===")
    
    with sqlite3.connect(CURRENT_DB) as conn:
        cursor = conn.cursor()
        
        # Rebuild FTS5 index
        print("Rebuilding FTS5 index...")
        cursor.execute("INSERT INTO documents_fts(documents_fts) VALUES('rebuild')")
        
        # Update any other indexes that may need refreshing
        cursor.execute("ANALYZE")
        
        conn.commit()
        print("Indexes rebuilt successfully")

def main():
    """Main merge process"""
    print("KENNY DATABASE MERGE - Restoring Historical WhatsApp Data")
    print("=" * 60)
    
    # Step 1: Create backup
    create_backup()
    
    # Step 2: Analyze databases
    cutoff_date, historical_count = analyze_databases()
    
    # Step 3: Confirm merge
    print(f"\nThis will merge {historical_count} historical WhatsApp messages")
    print("while preserving all current messages from the bridge.")
    print("Proceeding automatically with merge...")
    
    # Step 4: Perform merge
    merge_databases(cutoff_date)
    
    # Step 5: Rebuild indexes
    rebuild_indexes()
    
    print("\n✅ DATABASE MERGE COMPLETE!")
    print(f"Backup of original database saved at: {MERGE_BACKUP}")

if __name__ == "__main__":
    main()