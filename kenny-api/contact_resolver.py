#!/usr/bin/env python3
"""
Kenny Contact Resolution System
Gradually resolves identities from existing Contacts data and document metadata
"""

import sqlite3
import json
import re
from typing import Dict, List, Optional, Tuple, Set
from dataclasses import dataclass
from pathlib import Path
import uuid
import time
from difflib import SequenceMatcher

@dataclass
class Identity:
    type: str  # 'phone', 'email', 'whatsapp_jid', 'contact_record'
    value: str
    source: str
    confidence: float = 1.0

@dataclass
class Contact:
    kenny_contact_id: str
    display_name: str
    identities: List[Identity]
    confidence_score: float = 1.0

class ContactResolver:
    def __init__(self, kenny_db_path: str, contact_db_path: str):
        self.kenny_db_path = kenny_db_path
        self.contact_db_path = contact_db_path
        self.phone_patterns = [
            r'\+?(\d{1,4}[\s\-]?)?\(?(\d{3})\)?[\s\-]?(\d{3})[\s\-]?(\d{4})',
            r'\+?(\d{8,15})',  # International format
        ]
    
    def setup_contact_database(self):
        """Initialize the contact memory database"""
        from pathlib import Path
        
        # Check if database already exists
        if Path(self.contact_db_path).exists():
            print(f"Contact memory database already exists at {self.contact_db_path}")
            return
        
        with open('/Users/joshwlim/Documents/Kenny/kenny-api/contact_memory_schema.sql', 'r') as f:
            schema = f.read()
        
        conn = sqlite3.connect(self.contact_db_path)
        conn.executescript(schema)
        conn.close()
        print(f"Contact memory database initialized at {self.contact_db_path}")
    
    def normalize_phone(self, phone: str) -> str:
        """Normalize phone number for matching"""
        if not phone:
            return ""
        
        # Remove all non-digits except +
        cleaned = re.sub(r'[^\d+]', '', phone)
        
        # Handle Australian numbers specifically
        if cleaned.startswith('+61'):
            cleaned = cleaned[3:]  # Remove +61
        elif cleaned.startswith('61') and len(cleaned) > 10:
            cleaned = cleaned[2:]  # Remove 61 prefix
        elif cleaned.startswith('0') and len(cleaned) == 10:
            cleaned = cleaned[1:]  # Remove leading 0
        
        return cleaned[-9:] if len(cleaned) >= 9 else cleaned  # Last 9 digits for matching
    
    def normalize_email(self, email: str) -> str:
        """Normalize email for matching"""
        if not email:
            return ""
        return email.lower().strip()
    
    def extract_whatsapp_identifier(self, chat_jid: str) -> Optional[str]:
        """Extract phone number from WhatsApp JID"""
        if not chat_jid:
            return None
        
        if '@s.whatsapp.net' in chat_jid:
            # Individual chat - extract phone number
            phone = chat_jid.replace('@s.whatsapp.net', '')
            return self.normalize_phone(phone)
        
        return None  # Group chats not handled here
    
    def similarity_score(self, str1: str, str2: str) -> float:
        """Calculate similarity between two strings"""
        if not str1 or not str2:
            return 0.0
        return SequenceMatcher(None, str1.lower(), str2.lower()).ratio()
    
    def load_contacts_from_kenny_db(self) -> List[Contact]:
        """Load contacts from the main kenny.db contacts table"""
        conn = sqlite3.connect(self.kenny_db_path)
        cursor = conn.cursor()
        
        # Get all contacts with structured data
        cursor.execute("""
            SELECT contact_id, first_name, last_name, full_name, 
                   primary_phone, secondary_phone, tertiary_phone,
                   primary_email, secondary_email,
                   company, job_title
            FROM contacts
            WHERE (primary_phone IS NOT NULL AND primary_phone != '') 
               OR (primary_email IS NOT NULL AND primary_email != '')
               OR (first_name IS NOT NULL AND first_name != '')
               OR (full_name IS NOT NULL AND full_name != '')
        """)
        
        contacts = []
        for row in cursor.fetchall():
            contact_id, first, last, full_name, phone1, phone2, phone3, email1, email2, company, job_title = row
            
            # Build display name - prefer full_name, then constructed name
            if full_name and full_name.strip():
                display_name = full_name.strip()
            elif first:
                name_parts = [first, last] if last else [first]
                display_name = " ".join(filter(None, name_parts))
            else:
                display_name = f"Contact {contact_id}" if contact_id else "Unknown Contact"
            
            # Build identities list
            identities = []
            
            # Contact record identity
            identities.append(Identity(
                type='contact_record',
                value=str(contact_id),
                source='contacts_app',
                confidence=1.0
            ))
            
            # Phone identities
            for phone in [phone1, phone2, phone3]:
                if phone and phone.strip():
                    identities.append(Identity(
                        type='phone',
                        value=self.normalize_phone(phone),
                        source='contacts_app',
                        confidence=0.95
                    ))
            
            # Email identities
            for email in [email1, email2]:
                if email and email.strip():
                    identities.append(Identity(
                        type='email',
                        value=self.normalize_email(email),
                        source='contacts_app',
                        confidence=0.95
                    ))
            
            contacts.append(Contact(
                kenny_contact_id=str(uuid.uuid4()),
                display_name=display_name,
                identities=identities,
                confidence_score=1.0
            ))
        
        conn.close()
        return contacts
    
    def extract_identities_from_documents(self) -> List[Identity]:
        """Extract potential contact identities from document metadata"""
        conn = sqlite3.connect(self.kenny_db_path)
        cursor = conn.cursor()
        
        identities = []
        
        # WhatsApp identities
        cursor.execute("""
            SELECT DISTINCT metadata_json 
            FROM documents 
            WHERE app_source = 'WhatsApp' 
              AND metadata_json IS NOT NULL
              AND metadata_json != ''
        """)
        
        for (metadata_json,) in cursor.fetchall():
            try:
                metadata = json.loads(metadata_json)
                chat_jid = metadata.get('chat_jid', '')
                
                whatsapp_phone = self.extract_whatsapp_identifier(chat_jid)
                if whatsapp_phone:
                    identities.append(Identity(
                        type='phone',
                        value=whatsapp_phone,
                        source='whatsapp_bridge',
                        confidence=0.8
                    ))
                    
                    # Also add WhatsApp JID as separate identity
                    identities.append(Identity(
                        type='whatsapp_jid',
                        value=chat_jid,
                        source='whatsapp_bridge',
                        confidence=0.9
                    ))
            except json.JSONDecodeError:
                continue
        
        # Email identities (would need email header parsing)
        # TODO: Extract from/to addresses from email metadata
        
        conn.close()
        return identities
    
    def find_matching_contacts(self, identity: Identity, existing_contacts: List[Contact]) -> List[Tuple[Contact, float]]:
        """Find existing contacts that might match this identity"""
        matches = []
        
        for contact in existing_contacts:
            max_confidence = 0.0
            
            for existing_identity in contact.identities:
                if existing_identity.type == identity.type:
                    if existing_identity.value == identity.value:
                        # Exact match
                        max_confidence = max(max_confidence, 0.95)
                    elif identity.type in ['phone', 'email']:
                        # Fuzzy match for contact details
                        similarity = self.similarity_score(existing_identity.value, identity.value)
                        if similarity > 0.8:
                            max_confidence = max(max_confidence, similarity * 0.7)
            
            if max_confidence > 0.5:
                matches.append((contact, max_confidence))
        
        return sorted(matches, key=lambda x: x[1], reverse=True)
    
    def save_contacts_to_memory_db(self, contacts: List[Contact]):
        """Save resolved contacts to the contact memory database"""
        conn = sqlite3.connect(self.contact_db_path)
        cursor = conn.cursor()
        
        current_time = int(time.time())
        
        for contact in contacts:
            # Insert contact
            cursor.execute("""
                INSERT OR REPLACE INTO kenny_contacts 
                (kenny_contact_id, display_name, created_at, updated_at, confidence_score)
                VALUES (?, ?, ?, ?, ?)
            """, (
                contact.kenny_contact_id,
                contact.display_name,
                current_time,
                current_time,
                contact.confidence_score
            ))
            
            # Insert identities
            for identity in contact.identities:
                cursor.execute("""
                    INSERT OR REPLACE INTO contact_identities
                    (id, kenny_contact_id, identity_type, identity_value, source, confidence, created_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, (
                    str(uuid.uuid4()),
                    contact.kenny_contact_id,
                    identity.type,
                    identity.value,
                    identity.source,
                    identity.confidence,
                    current_time,
                    current_time
                ))
        
        conn.commit()
        conn.close()
        print(f"Saved {len(contacts)} contacts to memory database")
    
    def resolve_and_initialize(self):
        """Main resolution process - run this to bootstrap the contact memory system"""
        print("Starting contact resolution...")
        
        # 1. Setup database
        self.setup_contact_database()
        
        # 2. Load contacts from kenny.db
        print("Loading contacts from kenny.db...")
        contacts = self.load_contacts_from_kenny_db()
        print(f"Loaded {len(contacts)} contacts from contacts table")
        
        # 3. Extract identities from documents
        print("Extracting identities from documents...")
        document_identities = self.extract_identities_from_documents()
        print(f"Found {len(document_identities)} identities in documents")
        
        # 4. Match document identities to contacts
        unmatched_identities = []
        matched_count = 0
        
        for identity in document_identities:
            matches = self.find_matching_contacts(identity, contacts)
            
            if matches and matches[0][1] > 0.7:  # High confidence match
                # Add identity to existing contact
                best_match, confidence = matches[0]
                best_match.identities.append(identity)
                matched_count += 1
            else:
                unmatched_identities.append(identity)
        
        print(f"Matched {matched_count} identities to existing contacts")
        print(f"{len(unmatched_identities)} identities remain unmatched")
        
        # 5. Create new contacts for unmatched identities (high-confidence ones)
        for identity in unmatched_identities:
            if identity.confidence > 0.8 and identity.type in ['phone', 'email']:
                # Create new contact
                new_contact = Contact(
                    kenny_contact_id=str(uuid.uuid4()),
                    display_name=f"Unknown ({identity.value})",
                    identities=[identity],
                    confidence_score=0.6  # Lower confidence for unknown contacts
                )
                contacts.append(new_contact)
        
        # 6. Save to contact memory database
        print("Saving contacts to memory database...")
        self.save_contacts_to_memory_db(contacts)
        
        print("Contact resolution complete!")
        return contacts

def main():
    """Initialize contact resolution system"""
    kenny_db = "/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db"
    contact_db = "/Users/joshwlim/Documents/Kenny/kenny-api/contact_memory.db"
    
    resolver = ContactResolver(kenny_db, contact_db)
    contacts = resolver.resolve_and_initialize()
    
    print(f"\n=== Resolution Summary ===")
    print(f"Total contacts: {len(contacts)}")
    
    # Show some statistics
    high_conf = len([c for c in contacts if c.confidence_score > 0.8])
    medium_conf = len([c for c in contacts if 0.5 <= c.confidence_score <= 0.8])
    low_conf = len([c for c in contacts if c.confidence_score < 0.5])
    
    print(f"High confidence: {high_conf}")
    print(f"Medium confidence: {medium_conf}")  
    print(f"Low confidence: {low_conf}")

if __name__ == "__main__":
    main()