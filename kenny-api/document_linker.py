#!/usr/bin/env python3
"""
Kenny Document-to-Contact Linking System
Links 234K documents to resolved contacts for contact-centric threading
"""

import sqlite3
import json
import re
import time
import uuid
from typing import Dict, List, Optional, Tuple, Set
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path

@dataclass
class DocumentLink:
    document_id: str
    kenny_contact_id: str
    relationship_type: str  # 'sender', 'recipient', 'attendee', 'mentioned'
    confidence: float
    extraction_method: str

class DocumentLinker:
    def __init__(self, kenny_db_path: str, contact_db_path: str):
        self.kenny_db_path = kenny_db_path
        self.contact_db_path = contact_db_path
        self.contact_identity_cache = {}  # Cache for identity lookups
        self.load_identity_cache()
    
    def load_identity_cache(self):
        """Load all contact identities into memory for fast lookup"""
        conn = sqlite3.connect(self.contact_db_path)
        cursor = conn.cursor()
        
        cursor.execute("""
            SELECT kenny_contact_id, identity_type, identity_value, confidence
            FROM contact_identities
        """)
        
        for kenny_id, id_type, id_value, confidence in cursor.fetchall():
            key = f"{id_type}:{id_value}"
            if key not in self.contact_identity_cache:
                self.contact_identity_cache[key] = []
            self.contact_identity_cache[key].append((kenny_id, confidence))
        
        conn.close()
        print(f"Loaded {len(self.contact_identity_cache)} identity mappings into cache")
    
    def normalize_phone_for_lookup(self, phone: str) -> str:
        """Normalize phone for identity matching"""
        if not phone:
            return ""
        
        # Remove all non-digits
        cleaned = re.sub(r'\D', '', phone)
        
        # Handle Australian numbers
        if cleaned.startswith('61') and len(cleaned) > 10:
            cleaned = cleaned[2:]  # Remove country code
        elif cleaned.startswith('0') and len(cleaned) == 10:
            cleaned = cleaned[1:]  # Remove leading 0
        
        return cleaned[-9:] if len(cleaned) >= 9 else cleaned
    
    def extract_whatsapp_phone(self, chat_jid: str) -> Optional[str]:
        """Extract normalized phone from WhatsApp JID"""
        if not chat_jid or '@s.whatsapp.net' not in chat_jid:
            return None
        
        phone = chat_jid.replace('@s.whatsapp.net', '')
        return self.normalize_phone_for_lookup(phone)
    
    def find_contact_by_identity(self, identity_type: str, identity_value: str) -> List[Tuple[str, float]]:
        """Find contacts matching an identity"""
        key = f"{identity_type}:{identity_value}"
        return self.contact_identity_cache.get(key, [])
    
    def extract_email_addresses(self, email_content: str) -> List[str]:
        """Extract email addresses from email content/headers"""
        # Simple regex for emails - could be enhanced
        email_pattern = r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b'
        emails = re.findall(email_pattern, email_content)
        return [email.lower() for email in emails]
    
    def fuzzy_match_calendar_event(self, title: str, content: str) -> List[Tuple[str, float]]:
        """Fuzzy match calendar events to contacts by name similarity - only close contacts"""
        conn = sqlite3.connect(self.contact_db_path)
        cursor = conn.cursor()
        
        # Get contact names with email/phone data (indicating closer relationships)
        cursor.execute("""
            SELECT DISTINCT kc.kenny_contact_id, kc.display_name 
            FROM kenny_contacts kc 
            JOIN contact_identities ci ON kc.kenny_contact_id = ci.kenny_contact_id
            WHERE ci.identity_type IN ('email', 'phone', 'whatsapp_jid')
        """)
        contacts = cursor.fetchall()
        conn.close()
        
        matches = []
        search_text = f"{title} {content}".lower()
        
        # Skip obvious business/formal events
        business_keywords = ['meeting', 'conference', 'workshop', 'training', 'seminar', 'webinar', 'inspection']
        if any(keyword in search_text for keyword in business_keywords):
            return []  # Don't match business events to personal contacts
        
        for kenny_id, display_name in contacts:
            if not display_name:
                continue
                
            name_parts = display_name.lower().split()
            
            # Require first name match (more personal)
            first_name = name_parts[0] if name_parts else ""
            if len(first_name) < 3:  # Skip very short first names
                continue
            
            if first_name in search_text:
                # Check for stronger match with multiple name parts
                matched_parts = sum(1 for part in name_parts if part in search_text and len(part) >= 3)
                
                if matched_parts >= 1:  # At least first name matches
                    # Higher confidence for multiple name matches
                    confidence = min(0.7, 0.5 + (matched_parts * 0.1))
                    matches.append((kenny_id, confidence))
        
        return sorted(matches, key=lambda x: x[1], reverse=True)[:2]  # Top 2 matches only
    
    def link_whatsapp_documents(self) -> List[DocumentLink]:
        """Link WhatsApp messages to contacts"""
        conn = sqlite3.connect(self.kenny_db_path)
        cursor = conn.cursor()
        
        cursor.execute("""
            SELECT id, metadata_json FROM documents 
            WHERE app_source = 'WhatsApp' 
              AND metadata_json IS NOT NULL
              AND metadata_json != ''
        """)
        
        links = []
        processed = 0
        
        for doc_id, metadata_json in cursor.fetchall():
            try:
                metadata = json.loads(metadata_json)
                chat_jid = metadata.get('chat_jid', '')
                
                if '@g.us' in chat_jid:
                    # Group chat - skip for now (platform-specific)
                    continue
                
                phone = self.extract_whatsapp_phone(chat_jid)
                if phone:
                    matches = self.find_contact_by_identity('phone', phone)
                    if matches:
                        # Use highest confidence match
                        kenny_id, confidence = matches[0]
                        links.append(DocumentLink(
                            document_id=doc_id,
                            kenny_contact_id=kenny_id,
                            relationship_type='sender',  # WhatsApp messages are conversations
                            confidence=confidence * 0.9,  # Slight discount for indirect matching
                            extraction_method='whatsapp_jid_phone'
                        ))
                
                processed += 1
                if processed % 100 == 0:
                    print(f"Processed {processed} WhatsApp documents...")
                    
            except json.JSONDecodeError:
                continue
        
        conn.close()
        print(f"Linked {len(links)} WhatsApp documents to contacts")
        return links
    
    def link_email_documents(self) -> List[DocumentLink]:
        """Link email documents to contacts - only use emails from known contacts"""
        conn = sqlite3.connect(self.kenny_db_path)
        cursor = conn.cursor()
        
        # Get known contact emails for filtering
        known_emails = set()
        for key, contacts in self.contact_identity_cache.items():
            if key.startswith('email:'):
                email = key.split(':', 1)[1]
                known_emails.add(email.lower())
        
        print(f"Filtering emails against {len(known_emails)} known contact emails")
        
        cursor.execute("""
            SELECT id, title, content FROM documents 
            WHERE app_source = 'Mail' 
              AND (title IS NOT NULL OR content IS NOT NULL)
        """)  # Process all emails now that we're filtering
        
        links = []
        processed = 0
        
        for doc_id, title, content in cursor.fetchall():
            # Extract sender email from the structured format
            sender_email = None
            recipient_emails = []
            
            # Email format appears to be: "Subject | Content Sender Name sender@email.com"
            if title and content:
                # Look for email pattern at end of content (sender)
                content_emails = self.extract_email_addresses(content)
                if content_emails:
                    # Last email in content is likely the sender
                    sender_email = content_emails[-1].lower()
                
                # Look for other emails in title/content (recipients, CCs, etc)
                title_emails = self.extract_email_addresses(title)
                recipient_emails = [e.lower() for e in title_emails + content_emails[:-1] if content_emails]
            
            # Only link emails that match known contacts
            if sender_email and sender_email in known_emails:
                matches = self.find_contact_by_identity('email', sender_email)
                if matches:
                    kenny_id, confidence = matches[0]
                    links.append(DocumentLink(
                        document_id=doc_id,
                        kenny_contact_id=kenny_id,
                        relationship_type='sender',
                        confidence=confidence * 0.95,
                        extraction_method='email_sender'
                    ))
            
            # Link recipient emails that match known contacts
            for recipient_email in recipient_emails:
                if recipient_email in known_emails:
                    matches = self.find_contact_by_identity('email', recipient_email)
                    if matches:
                        kenny_id, confidence = matches[0]
                        links.append(DocumentLink(
                            document_id=doc_id,
                            kenny_contact_id=kenny_id,
                            relationship_type='recipient',
                            confidence=confidence * 0.9,
                            extraction_method='email_recipient'
                        ))
            
            processed += 1
            if processed % 500 == 0:
                print(f"Processed {processed} email documents...")
        
        conn.close()
        print(f"Linked {len(links)} email documents to contacts (filtered to known contacts only)")
        return links
    
    def link_calendar_documents(self) -> List[DocumentLink]:
        """Link calendar events to contacts using fuzzy name matching"""
        conn = sqlite3.connect(self.kenny_db_path)
        cursor = conn.cursor()
        
        cursor.execute("""
            SELECT id, title, content FROM documents 
            WHERE app_source = 'Calendar'
              AND title IS NOT NULL
        """)
        
        links = []
        processed = 0
        
        for doc_id, title, content in cursor.fetchall():
            matches = self.fuzzy_match_calendar_event(title, content or '')
            
            for kenny_id, confidence in matches:
                if confidence > 0.5:  # Only include reasonable matches
                    links.append(DocumentLink(
                        document_id=doc_id,
                        kenny_contact_id=kenny_id,
                        relationship_type='mentioned',  # Calendar events mention people
                        confidence=confidence,
                        extraction_method='calendar_fuzzy_name'
                    ))
            
            processed += 1
            if processed % 50 == 0:
                print(f"Processed {processed} calendar documents...")
        
        conn.close()
        print(f"Linked {len(links)} calendar documents to contacts")
        return links
    
    def link_messages_documents(self) -> List[DocumentLink]:
        """Link SMS/iMessage documents to contacts"""
        # Messages app usually has conversation identifiers
        # This would need investigation of the Messages metadata structure
        # For now, return empty list
        print("Messages linking not yet implemented - need to investigate metadata structure")
        return []
    
    def save_links_to_database(self, links: List[DocumentLink]):
        """Save document-contact links to contact memory database"""
        conn = sqlite3.connect(self.contact_db_path)
        cursor = conn.cursor()
        
        current_time = int(time.time())
        
        # Clear existing links (for re-runs)
        cursor.execute("DELETE FROM contact_threads")
        
        for link in links:
            cursor.execute("""
                INSERT OR IGNORE INTO contact_threads 
                (id, kenny_contact_id, document_id, relationship_type, extracted_at, confidence)
                VALUES (?, ?, ?, ?, ?, ?)
            """, (
                str(uuid.uuid4()),
                link.kenny_contact_id,
                link.document_id,
                link.relationship_type,
                current_time,
                link.confidence
            ))
        
        conn.commit()
        conn.close()
        print(f"Saved {len(links)} document links to database")
    
    def link_all_documents(self):
        """Main process to link all documents to contacts"""
        print("Starting document-to-contact linking...")
        
        all_links = []
        
        # Link different document types
        print("\n1. Linking WhatsApp documents...")
        whatsapp_links = self.link_whatsapp_documents()
        all_links.extend(whatsapp_links)
        
        print("\n2. Linking Email documents...")
        email_links = self.link_email_documents()
        all_links.extend(email_links)
        
        print("\n3. Linking Calendar documents...")
        calendar_links = self.link_calendar_documents()
        all_links.extend(calendar_links)
        
        print("\n4. Linking Messages documents...")
        messages_links = self.link_messages_documents()
        all_links.extend(messages_links)
        
        # Save to database
        print(f"\nSaving {len(all_links)} total document links...")
        self.save_links_to_database(all_links)
        
        # Statistics
        print(f"\n=== Linking Summary ===")
        print(f"Total documents linked: {len(all_links)}")
        print(f"WhatsApp: {len(whatsapp_links)}")
        print(f"Email: {len(email_links)}")
        print(f"Calendar: {len(calendar_links)}")
        print(f"Messages: {len(messages_links)}")
        
        # Show confidence distribution
        high_conf = len([l for l in all_links if l.confidence > 0.8])
        med_conf = len([l for l in all_links if 0.5 <= l.confidence <= 0.8])
        low_conf = len([l for l in all_links if l.confidence < 0.5])
        
        print(f"High confidence (>0.8): {high_conf}")
        print(f"Medium confidence (0.5-0.8): {med_conf}")
        print(f"Low confidence (<0.5): {low_conf}")
        
        return all_links

def main():
    """Run document linking process"""
    kenny_db = "/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db"
    contact_db = "/Users/joshwlim/Documents/Kenny/kenny-api/contact_memory.db"
    
    linker = DocumentLinker(kenny_db, contact_db)
    links = linker.link_all_documents()
    
    # Show some examples
    conn = sqlite3.connect(contact_db)
    cursor = conn.cursor()
    
    cursor.execute("""
        SELECT kc.display_name, COUNT(ct.document_id) as doc_count
        FROM kenny_contacts kc 
        JOIN contact_threads ct ON kc.kenny_contact_id = ct.kenny_contact_id
        GROUP BY kc.kenny_contact_id
        ORDER BY doc_count DESC
        LIMIT 10
    """)
    
    print(f"\n=== Top Contacts by Document Count ===")
    for name, count in cursor.fetchall():
        print(f"{name}: {count} documents")
    
    conn.close()

if __name__ == "__main__":
    main()