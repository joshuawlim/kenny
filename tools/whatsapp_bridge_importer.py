#!/usr/bin/env python3
"""
Import WhatsApp messages from the bridge database into Kenny.db
"""

import sqlite3
import json
import hashlib
from datetime import datetime
from pathlib import Path
import sys
import uuid

class WhatsAppBridgeImporter:
    """Import messages from WhatsApp bridge database to Kenny.db"""
    
    def __init__(self, bridge_db_path: str, kenny_db_path: str):
        self.bridge_db = bridge_db_path
        self.kenny_db = kenny_db_path
        
    def fetch_messages(self):
        """Fetch all messages from bridge database"""
        conn = sqlite3.connect(self.bridge_db)
        cursor = conn.cursor()
        
        # Get messages with chat information
        query = """
        SELECT 
            m.id,
            m.chat_jid,
            m.sender,
            m.content,
            m.timestamp,
            m.is_from_me,
            m.media_type,
            c.name as chat_name
        FROM messages m
        LEFT JOIN chats c ON m.chat_jid = c.jid
        ORDER BY m.timestamp
        """
        
        cursor.execute(query)
        messages = cursor.fetchall()
        conn.close()
        
        return messages
    
    def generate_document_id(self, msg_id: str, chat_jid: str, timestamp):
        """Generate unique document ID for a message"""
        # Create deterministic ID based on WhatsApp message ID
        id_hash = hashlib.md5(f"{msg_id}_{chat_jid}".encode()).hexdigest()[:8]
        return f"whatsapp_bridge_{id_hash}"
    
    def extract_sender_name(self, sender: str):
        """Extract readable name from sender JID"""
        if '@' in sender:
            # Format: 123456789@s.whatsapp.net or 149370389397702@lid
            parts = sender.split('@')[0]
            # Check if it's a phone number (starts with country code)
            if parts.isdigit() and len(parts) > 10:
                # It's a phone number, return as is for now
                # Could enhance this with contact lookup
                return f"+{parts}"
            else:
                # It's likely a name ID
                return f"User_{parts}"
        return sender
    
    def transform_message(self, msg_tuple):
        """Transform bridge message to Kenny.db format"""
        msg_id, chat_jid, sender, content, timestamp, is_from_me, media_type, chat_name = msg_tuple
        
        # Handle null content
        if content is None:
            content = "[Unknown message type]" if media_type else "[Empty message]"
        
        # Generate document ID
        doc_id = self.generate_document_id(msg_id, chat_jid, timestamp)
        
        # Parse timestamp (already in ISO format from SQLite)
        try:
            dt = datetime.fromisoformat(timestamp.replace(' ', 'T'))
            unix_timestamp = int(dt.timestamp())
        except:
            # Fallback to current time if parsing fails
            unix_timestamp = int(datetime.now().timestamp())
        
        # Determine chat type and name
        if '@g.us' in chat_jid:
            # Group chat
            chat_type = "group"
            final_chat_name = chat_name or f"Group_{chat_jid.split('@')[0]}"
        elif '@lid' in chat_jid:
            # Newsletter/Channel
            chat_type = "channel"
            final_chat_name = chat_name or f"Channel_{chat_jid.split('@')[0]}"
        else:
            # Individual chat
            chat_type = "individual"
            final_chat_name = chat_name or self.extract_sender_name(chat_jid)
        
        # Extract sender name
        sender_name = "Josh Lim" if is_from_me else self.extract_sender_name(sender)
        
        # Build metadata
        metadata = {
            "bridge_import": True,
            "chat_jid": chat_jid,
            "chat_type": chat_type,
            "original_msg_id": msg_id,
            "media_type": media_type,
            "imported_at": datetime.now().isoformat()
        }
        
        # Prepare document record
        document = {
            "id": doc_id,
            "type": "message",
            "title": f"WhatsApp: {final_chat_name}",
            "content": content,
            "app_source": "WhatsApp",
            "source_id": doc_id,
            "source_path": f"whatsapp://{chat_jid}/{msg_id}",
            "hash": hashlib.sha256(content.encode()).hexdigest(),
            "created_at": unix_timestamp,
            "updated_at": unix_timestamp,
            "last_seen_at": int(datetime.now().timestamp()),
            "deleted": 0,
            "metadata_json": json.dumps(metadata)
        }
        
        # Prepare message record
        message_record = {
            "document_id": doc_id,
            "thread_id": f"whatsapp_thread_{chat_jid}",
            "from_contact": sender_name,
            "to_contacts": json.dumps([final_chat_name]) if not is_from_me else json.dumps([]),
            "date_sent": unix_timestamp,
            "is_from_me": 1 if is_from_me else 0,
            "is_read": 1,  # Assume all bridge messages are read
            "service": "WhatsApp",
            "chat_name": final_chat_name,
            "has_attachments": 1 if media_type else 0,
            "attachment_types": json.dumps([media_type]) if media_type else json.dumps([])
        }
        
        return document, message_record
    
    def import_messages(self):
        """Import all messages from bridge to Kenny.db"""
        # Fetch messages from bridge
        print("Fetching messages from WhatsApp bridge...")
        messages = self.fetch_messages()
        print(f"Found {len(messages)} messages to import")
        
        if not messages:
            print("No messages to import")
            return
        
        # Connect to Kenny.db
        kenny_conn = sqlite3.connect(self.kenny_db)
        kenny_cursor = kenny_conn.cursor()
        
        # Enable foreign keys
        kenny_cursor.execute("PRAGMA foreign_keys = ON")
        
        # Track import statistics
        inserted = 0
        skipped = 0
        errors = 0
        
        # Begin transaction
        kenny_conn.execute("BEGIN TRANSACTION")
        
        try:
            for msg_tuple in messages:
                try:
                    document, message = self.transform_message(msg_tuple)
                    
                    # Insert into documents table
                    kenny_cursor.execute("""
                        INSERT OR IGNORE INTO documents (
                            id, type, title, content, app_source, source_id,
                            source_path, hash, created_at, updated_at,
                            last_seen_at, deleted, metadata_json
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, (
                        document["id"], document["type"], document["title"],
                        document["content"], document["app_source"], document["source_id"],
                        document["source_path"], document["hash"], document["created_at"],
                        document["updated_at"], document["last_seen_at"], document["deleted"],
                        document["metadata_json"]
                    ))
                    
                    if kenny_cursor.rowcount > 0:
                        # Document was inserted, now insert message
                        kenny_cursor.execute("""
                            INSERT OR IGNORE INTO messages (
                                document_id, thread_id, from_contact, to_contacts,
                                date_sent, is_from_me, is_read, service, chat_name,
                                has_attachments, attachment_types
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, (
                            message["document_id"], message["thread_id"],
                            message["from_contact"], message["to_contacts"],
                            message["date_sent"], message["is_from_me"],
                            message["is_read"], message["service"],
                            message["chat_name"], message["has_attachments"],
                            message["attachment_types"]
                        ))
                        inserted += 1
                    else:
                        skipped += 1
                        
                except Exception as e:
                    errors += 1
                    print(f"Error processing message {msg_tuple[0]}: {e}")
            
            # Commit transaction
            kenny_conn.commit()
            print("\nImport completed successfully!")
            
        except Exception as e:
            kenny_conn.rollback()
            print(f"Transaction failed: {e}")
            raise
        finally:
            kenny_conn.close()
        
        # Print summary
        print("\n" + "="*50)
        print("IMPORT SUMMARY")
        print("="*50)
        print(f"Total messages processed: {len(messages)}")
        print(f"Successfully inserted: {inserted}")
        print(f"Skipped (duplicates): {skipped}")
        if errors > 0:
            print(f"Errors: {errors}")
        
        return {
            "total": len(messages),
            "inserted": inserted,
            "skipped": skipped,
            "errors": errors
        }

def main():
    bridge_db = "/Users/joshwlim/Documents/Kenny/tools/whatsapp/whatsapp_messages.db"
    kenny_db = "/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db"
    
    # Check if bridge database exists
    if not Path(bridge_db).exists():
        print(f"Error: Bridge database not found at {bridge_db}")
        sys.exit(1)
    
    # Check if Kenny database exists
    if not Path(kenny_db).exists():
        print(f"Error: Kenny database not found at {kenny_db}")
        sys.exit(1)
    
    print("WhatsApp Bridge Importer")
    print("="*50)
    print(f"Source: {bridge_db}")
    print(f"Target: {kenny_db}")
    print()
    
    importer = WhatsAppBridgeImporter(bridge_db, kenny_db)
    importer.import_messages()

if __name__ == "__main__":
    main()