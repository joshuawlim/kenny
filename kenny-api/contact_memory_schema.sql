-- Kenny Contact Memory System Schema
-- Separate database for contact-centric threading and memory features
-- This sits alongside kenny.db, not inside it

-- Core contact identity table
CREATE TABLE kenny_contacts (
    kenny_contact_id TEXT PRIMARY KEY,           -- Unique Kenny identifier (uuid)
    display_name TEXT NOT NULL,                  -- Primary display name
    created_at INTEGER NOT NULL,                 -- When we first identified this person
    updated_at INTEGER NOT NULL,                 -- Last memory/identity update
    confidence_score REAL DEFAULT 1.0,          -- How confident we are in identity resolution
    status TEXT DEFAULT 'active',               -- active, archived, merged
    photo_path TEXT,                             -- Path to contact photo
    UNIQUE(kenny_contact_id)
);

-- Identity mapping - links external identifiers to kenny contacts
CREATE TABLE contact_identities (
    id TEXT PRIMARY KEY,
    kenny_contact_id TEXT NOT NULL,
    identity_type TEXT NOT NULL,                 -- 'phone', 'email', 'whatsapp_jid', 'contact_record'
    identity_value TEXT NOT NULL,               -- +1234567890, alice@company.com, 1234567890@s.whatsapp.net
    source TEXT NOT NULL,                       -- 'contacts_app', 'whatsapp_bridge', 'email_headers', 'manual'
    confidence REAL DEFAULT 1.0,               -- How sure we are this identity belongs to this contact
    created_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    FOREIGN KEY (kenny_contact_id) REFERENCES kenny_contacts(kenny_contact_id),
    UNIQUE(identity_type, identity_value)
);

-- Document-to-contact threading (links to kenny.db documents)
CREATE TABLE contact_threads (
    id TEXT PRIMARY KEY,
    kenny_contact_id TEXT NOT NULL,
    document_id TEXT NOT NULL,                   -- References documents.id in kenny.db
    relationship_type TEXT NOT NULL,            -- 'sender', 'recipient', 'attendee', 'mentioned'
    extracted_at INTEGER NOT NULL,
    confidence REAL DEFAULT 1.0,
    FOREIGN KEY (kenny_contact_id) REFERENCES kenny_contacts(kenny_contact_id),
    UNIQUE(document_id, kenny_contact_id, relationship_type)
);

-- Contact memories - extracted insights and context
CREATE TABLE contact_memories (
    id TEXT PRIMARY KEY,
    kenny_contact_id TEXT NOT NULL,
    memory_type TEXT NOT NULL,                   -- 'preference', 'life_event', 'work_context', 'gift_idea', 'personal_detail'
    title TEXT NOT NULL,                         -- "Prefers coffee over tea"
    description TEXT,                            -- Longer description/context
    confidence REAL DEFAULT 1.0,               -- How sure we are about this memory
    source_document_ids TEXT,                    -- JSON array of contributing document IDs
    extracted_at INTEGER NOT NULL,
    last_confirmed_at INTEGER,                   -- When this was last validated
    importance_score REAL DEFAULT 0.5,         -- 0-1, how important this memory is
    tags TEXT,                                  -- JSON array of tags
    FOREIGN KEY (kenny_contact_id) REFERENCES kenny_contacts(kenny_contact_id)
);

-- Communication patterns and preferences
CREATE TABLE contact_communication_patterns (
    id TEXT PRIMARY KEY,
    kenny_contact_id TEXT NOT NULL,
    pattern_type TEXT NOT NULL,                  -- 'response_time', 'preferred_channel', 'communication_style', 'availability'
    pattern_data TEXT NOT NULL,                  -- JSON data about the pattern
    confidence REAL DEFAULT 1.0,
    calculated_at INTEGER NOT NULL,
    sample_size INTEGER DEFAULT 1,              -- How many interactions this is based on
    FOREIGN KEY (kenny_contact_id) REFERENCES kenny_contacts(kenny_contact_id)
);

-- Relationship context - how you know this person
CREATE TABLE contact_relationships (
    id TEXT PRIMARY KEY,
    kenny_contact_id TEXT NOT NULL,
    relationship_type TEXT NOT NULL,             -- 'family', 'friend', 'colleague', 'client', 'acquaintance'
    relationship_details TEXT,                   -- "Brother's roommate from college"
    company TEXT,                               -- Current/associated company
    role TEXT,                                  -- Their role/title
    context TEXT,                               -- How you met/know them
    importance_level INTEGER DEFAULT 3,         -- 1-5 importance scale
    last_interaction_at INTEGER,
    interaction_frequency TEXT,                  -- 'daily', 'weekly', 'monthly', 'rarely'
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY (kenny_contact_id) REFERENCES kenny_contacts(kenny_contact_id)
);

-- Upcoming context - birthdays, anniversaries, reminders
CREATE TABLE contact_upcoming (
    id TEXT PRIMARY KEY,
    kenny_contact_id TEXT NOT NULL,
    event_type TEXT NOT NULL,                    -- 'birthday', 'anniversary', 'follow_up', 'custom'
    event_date TEXT NOT NULL,                    -- ISO date or recurring pattern
    title TEXT NOT NULL,
    description TEXT,
    is_recurring BOOLEAN DEFAULT FALSE,
    reminder_days INTEGER DEFAULT 7,            -- Days before to remind
    created_at INTEGER NOT NULL,
    FOREIGN KEY (kenny_contact_id) REFERENCES kenny_contacts(kenny_contact_id)
);

-- Memory extraction queue - documents pending memory extraction
CREATE TABLE memory_extraction_queue (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL,                   -- References documents.id in kenny.db
    kenny_contact_id TEXT,                       -- NULL if not yet assigned to contact
    status TEXT DEFAULT 'pending',              -- 'pending', 'processing', 'completed', 'failed'
    priority INTEGER DEFAULT 5,                 -- 1-10 priority
    scheduled_for INTEGER,                       -- When to process this
    attempts INTEGER DEFAULT 0,
    last_error TEXT,
    created_at INTEGER NOT NULL,
    UNIQUE(document_id)
);

-- Indexes for performance
CREATE INDEX idx_contact_identities_kenny_id ON contact_identities(kenny_contact_id);
CREATE INDEX idx_contact_identities_type_value ON contact_identities(identity_type, identity_value);
CREATE INDEX idx_contact_threads_kenny_id ON contact_threads(kenny_contact_id);
CREATE INDEX idx_contact_threads_document_id ON contact_threads(document_id);
CREATE INDEX idx_contact_memories_kenny_id ON contact_memories(kenny_contact_id);
CREATE INDEX idx_contact_memories_type ON contact_memories(memory_type);
CREATE INDEX idx_contact_memories_importance ON contact_memories(importance_score DESC);
CREATE INDEX idx_contact_relationships_kenny_id ON contact_relationships(kenny_contact_id);
CREATE INDEX idx_memory_queue_status ON memory_extraction_queue(status, priority DESC);

-- Views for common queries
CREATE VIEW contact_summary AS
SELECT 
    kc.kenny_contact_id,
    kc.display_name,
    cr.relationship_type,
    cr.company,
    cr.role,
    COUNT(DISTINCT ct.document_id) as total_interactions,
    MAX(ct.extracted_at) as last_interaction_time,
    COUNT(DISTINCT cm.id) as memory_count
FROM kenny_contacts kc
LEFT JOIN contact_relationships cr ON kc.kenny_contact_id = cr.kenny_contact_id
LEFT JOIN contact_threads ct ON kc.kenny_contact_id = ct.kenny_contact_id  
LEFT JOIN contact_memories cm ON kc.kenny_contact_id = cm.kenny_contact_id
GROUP BY kc.kenny_contact_id, kc.display_name, cr.relationship_type, cr.company, cr.role;

-- Contact interaction timeline view
CREATE VIEW contact_timeline AS
SELECT 
    ct.kenny_contact_id,
    ct.document_id,
    ct.relationship_type,
    ct.extracted_at,
    -- We'll join with kenny.db documents in the application layer
    ct.confidence
FROM contact_threads ct
ORDER BY ct.kenny_contact_id, ct.extracted_at DESC;