#!/usr/bin/env python3
"""
WhatsApp Text File Importer for Kenny.db
Parses WhatsApp exported text files and transforms them into Kenny.db format
"""

import re
import json
import sqlite3
import hashlib
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Tuple, Optional
from dataclasses import dataclass, asdict
import uuid

@dataclass
class WhatsAppMessage:
    """Represents a parsed WhatsApp message"""
    timestamp: int
    date_str: str
    time_str: str
    sender: str
    content: str
    is_system_message: bool
    has_media: bool
    media_type: Optional[str]
    chat_file: str
    line_number: int

@dataclass
class ParsedChat:
    """Represents a parsed WhatsApp chat file"""
    file_path: str
    chat_name: str
    participants: set
    messages: List[WhatsAppMessage]
    start_date: Optional[int]
    end_date: Optional[int]
    total_messages: int
    total_media: int

class WhatsAppParser:
    """Parser for WhatsApp exported text files"""
    
    # Regex patterns for parsing
    # Note: WhatsApp uses non-breaking space (\u202f) before am/pm
    MESSAGE_PATTERN = r'^\[(\d{1,2}/\d{1,2}/\d{4}), (\d{1,2}:\d{2}:\d{2}[\s\u202f][ap]m)\] ([^:]+): (.+)$'
    SYSTEM_MESSAGE_PATTERN = r'^\[(\d{1,2}/\d{1,2}/\d{4}), (\d{1,2}:\d{2}:\d{2}[\s\u202f][ap]m)\] (.+)$'
    MEDIA_OMITTED_PATTERN = r'‎?(image|video|audio|document|sticker|GIF) omitted'
    
    def __init__(self):
        self.message_regex = re.compile(self.MESSAGE_PATTERN)
        self.system_regex = re.compile(self.SYSTEM_MESSAGE_PATTERN)
        self.media_regex = re.compile(self.MEDIA_OMITTED_PATTERN, re.IGNORECASE)
    
    def parse_timestamp(self, date_str: str, time_str: str) -> int:
        """Convert date and time strings to Unix timestamp"""
        # Parse format: "14/10/2016", "9:13:53 am" or "7/9/2016", "7:06:22 pm"
        # Dates can have single or double digit days/months
        # WhatsApp uses non-breaking space before am/pm
        
        # Replace non-breaking space with regular space
        time_str = time_str.replace('\u202f', ' ')
        
        try:
            # Try platform-specific format first (works on Unix/Mac)
            datetime_str = f"{date_str} {time_str}"
            dt = datetime.strptime(datetime_str, "%-d/%-m/%Y %-I:%M:%S %p")
            return int(dt.timestamp())
        except:
            # Fallback: manually pad the date components
            parts = date_str.split('/')
            day = parts[0].zfill(2)
            month = parts[1].zfill(2) 
            year = parts[2]
            
            time_parts = time_str.split(':')
            hour = time_parts[0].zfill(2)
            rest = ':'.join(time_parts[1:])
            
            padded_datetime = f"{day}/{month}/{year} {hour}:{rest}"
            dt = datetime.strptime(padded_datetime, "%d/%m/%Y %I:%M:%S %p")
            return int(dt.timestamp())
    
    def extract_chat_name(self, file_path: str) -> str:
        """Extract chat name from file path"""
        filename = Path(file_path).stem
        # Remove leading underscore if present
        if filename.startswith('_'):
            filename = filename[1:]
        return filename.replace('_', ' ').title()
    
    def parse_line(self, line: str, line_number: int, chat_file: str) -> Optional[WhatsAppMessage]:
        """Parse a single line from WhatsApp export"""
        line = line.strip()
        if not line:
            return None
        
        # Try to match regular message pattern
        match = self.message_regex.match(line)
        if match:
            date_str, time_str, sender, content = match.groups()
            
            # Check if content contains media omitted
            has_media = bool(self.media_regex.search(content))
            media_type = None
            if has_media:
                media_match = self.media_regex.search(content)
                if media_match:
                    media_type = media_match.group(1).lower()
            
            return WhatsAppMessage(
                timestamp=self.parse_timestamp(date_str, time_str),
                date_str=date_str,
                time_str=time_str,
                sender=sender.strip(),
                content=content.strip(),
                is_system_message=False,
                has_media=has_media,
                media_type=media_type,
                chat_file=chat_file,
                line_number=line_number
            )
        
        # Try system message pattern (no sender)
        match = self.system_regex.match(line)
        if match:
            date_str, time_str, content = match.groups()
            
            # Check if this is actually a system message or just a message without sender
            if ':' in content and not any(keyword in content.lower() for keyword in 
                ['created', 'added', 'removed', 'left', 'changed', 'encrypted', 'deleted']):
                # This might be a continuation of a previous message
                return None
            
            return WhatsAppMessage(
                timestamp=self.parse_timestamp(date_str, time_str),
                date_str=date_str,
                time_str=time_str,
                sender='System',
                content=content.strip(),
                is_system_message=True,
                has_media=False,
                media_type=None,
                chat_file=chat_file,
                line_number=line_number
            )
        
        # Line doesn't match any pattern - might be continuation of previous message
        return None
    
    def parse_file(self, file_path: str) -> ParsedChat:
        """Parse entire WhatsApp chat export file"""
        messages = []
        participants = set()
        chat_name = self.extract_chat_name(file_path)
        
        with open(file_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
            
        current_message = None
        for i, line in enumerate(lines, 1):
            parsed = self.parse_line(line, i, file_path)
            
            if parsed:
                if current_message:
                    messages.append(current_message)
                current_message = parsed
                if not parsed.is_system_message:
                    participants.add(parsed.sender)
            elif current_message and line.strip():
                # Continuation of previous message
                current_message.content += '\n' + line.strip()
        
        # Don't forget the last message
        if current_message:
            messages.append(current_message)
        
        # Calculate statistics
        start_date = min(msg.timestamp for msg in messages) if messages else None
        end_date = max(msg.timestamp for msg in messages) if messages else None
        total_media = sum(1 for msg in messages if msg.has_media)
        
        return ParsedChat(
            file_path=file_path,
            chat_name=chat_name,
            participants=participants,
            messages=messages,
            start_date=start_date,
            end_date=end_date,
            total_messages=len(messages),
            total_media=total_media
        )

class WhatsAppToKennyTransformer:
    """Transform parsed WhatsApp data to Kenny.db format"""
    
    def __init__(self):
        self.parser = WhatsAppParser()
    
    def generate_document_id(self, message: WhatsAppMessage, chat_name: str) -> str:
        """Generate unique document ID for a message"""
        # Create deterministic ID based on chat, timestamp, sender, and content hash
        content_hash = hashlib.md5(f"{message.content[:100]}".encode()).hexdigest()[:8]
        return f"whatsapp_{chat_name}_{message.timestamp}_{content_hash}"
    
    def transform_message(self, message: WhatsAppMessage, chat: ParsedChat, thread_id: str) -> Dict:
        """Transform WhatsApp message to Kenny.db format"""
        doc_id = self.generate_document_id(message, chat.chat_name)
        
        # Determine if message is from the phone owner (Josh Lim)
        is_from_me = message.sender == "Josh Lim"
        
        # Build metadata
        metadata = {
            "original_file": chat.file_path,
            "line_number": message.line_number,
            "is_system_message": message.is_system_message,
            "has_media": message.has_media,
            "media_type": message.media_type
        }
        
        # Prepare document record
        document = {
            "id": doc_id,
            "type": "message",
            "title": f"WhatsApp: {chat.chat_name}",
            "content": message.content,
            "app_source": "WhatsApp",
            "source_id": doc_id,
            "source_path": chat.file_path,
            "hash": hashlib.sha256(message.content.encode()).hexdigest(),
            "created_at": message.timestamp,
            "updated_at": message.timestamp,
            "last_seen_at": int(datetime.now().timestamp()),
            "deleted": False,
            "metadata_json": json.dumps(metadata)
        }
        
        # Prepare message record
        message_record = {
            "document_id": doc_id,
            "thread_id": thread_id,
            "from_contact": message.sender if not is_from_me else "Josh Lim",
            "to_contacts": json.dumps(list(chat.participants - {message.sender})) if not message.is_system_message else "[]",
            "date_sent": message.timestamp,
            "is_from_me": is_from_me,
            "is_read": True,  # Assuming all exported messages are read
            "service": "WhatsApp",
            "chat_name": chat.chat_name,
            "has_attachments": message.has_media,
            "attachment_types": json.dumps([message.media_type]) if message.media_type else "[]"
        }
        
        return {
            "document": document,
            "message": message_record
        }
    
    def transform_chat(self, chat: ParsedChat) -> Dict:
        """Transform entire chat to Kenny.db format"""
        # Generate thread ID for this chat
        thread_id = f"whatsapp_thread_{chat.chat_name.lower().replace(' ', '_')}"
        
        transformed_messages = []
        for message in chat.messages:
            transformed = self.transform_message(message, chat, thread_id)
            transformed_messages.append(transformed)
        
        return {
            "chat_name": chat.chat_name,
            "thread_id": thread_id,
            "participants": list(chat.participants),
            "start_date": chat.start_date,
            "end_date": chat.end_date,
            "total_messages": chat.total_messages,
            "total_media": chat.total_media,
            "messages": transformed_messages
        }

def validate_transformed_data(transformed_data: List[Dict]) -> Tuple[bool, List[str]]:
    """Validate transformed data before insertion"""
    errors = []
    
    for chat_data in transformed_data:
        chat_name = chat_data.get("chat_name", "Unknown")
        
        # Check required fields
        if not chat_data.get("thread_id"):
            errors.append(f"Chat '{chat_name}': Missing thread_id")
        
        if not chat_data.get("messages"):
            errors.append(f"Chat '{chat_name}': No messages found")
        
        # Validate each message
        for i, msg_data in enumerate(chat_data.get("messages", [])):
            doc = msg_data.get("document", {})
            msg = msg_data.get("message", {})
            
            # Check document fields
            if not doc.get("id"):
                errors.append(f"Chat '{chat_name}', Message {i}: Missing document ID")
            if not doc.get("content"):
                errors.append(f"Chat '{chat_name}', Message {i}: Missing content")
            if doc.get("created_at") is None:
                errors.append(f"Chat '{chat_name}', Message {i}: Missing timestamp")
            
            # Check message fields
            if not msg.get("document_id"):
                errors.append(f"Chat '{chat_name}', Message {i}: Missing document_id in message")
            if not msg.get("thread_id"):
                errors.append(f"Chat '{chat_name}', Message {i}: Missing thread_id in message")
    
    return len(errors) == 0, errors

def main():
    """Main execution function"""
    import sys
    
    # Setup paths
    raw_dir = Path("/Users/joshwlim/Documents/Kenny/raw/Whatsapp_TXT")
    output_dir = Path("/Users/joshwlim/Documents/Kenny/transformed")
    output_dir.mkdir(exist_ok=True)
    
    # Initialize transformer
    transformer = WhatsAppToKennyTransformer()
    
    # Process all chat files
    all_transformed = []
    chat_files = sorted(raw_dir.glob("*.txt"))
    
    print(f"Found {len(chat_files)} WhatsApp chat files to process")
    
    for chat_file in chat_files:
        print(f"\nProcessing: {chat_file.name}")
        
        try:
            # Parse the chat file
            parsed_chat = transformer.parser.parse_file(str(chat_file))
            print(f"  - Parsed {parsed_chat.total_messages} messages")
            print(f"  - Found {len(parsed_chat.participants)} participants")
            
            # Transform to Kenny.db format
            transformed = transformer.transform_chat(parsed_chat)
            all_transformed.append(transformed)
            
            print(f"  - Transformed successfully")
            
        except Exception as e:
            print(f"  ERROR: Failed to process {chat_file.name}: {e}")
            continue
    
    # Validate all transformed data
    print("\n" + "="*50)
    print("Validating transformed data...")
    is_valid, errors = validate_transformed_data(all_transformed)
    
    if not is_valid:
        print(f"\nValidation failed with {len(errors)} errors:")
        for error in errors[:10]:  # Show first 10 errors
            print(f"  - {error}")
        if len(errors) > 10:
            print(f"  ... and {len(errors) - 10} more errors")
        sys.exit(1)
    
    print("Validation passed!")
    
    # Save transformed data to JSON for review
    output_file = output_dir / "whatsapp_transformed.json"
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(all_transformed, f, indent=2, ensure_ascii=False)
    
    print(f"\nTransformed data saved to: {output_file}")
    
    # Generate summary
    total_messages = sum(chat["total_messages"] for chat in all_transformed)
    total_chats = len(all_transformed)
    total_participants = len(set(
        participant 
        for chat in all_transformed 
        for participant in chat["participants"]
    ))
    
    print("\n" + "="*50)
    print("TRANSFORMATION SUMMARY")
    print("="*50)
    print(f"Total chats processed: {total_chats}")
    print(f"Total messages: {total_messages}")
    print(f"Total unique participants: {total_participants}")
    print(f"\nNext step: Review the transformed data in {output_file}")
    print("Then run: python tools/whatsapp_importer.py --insert")

if __name__ == "__main__":
    main()