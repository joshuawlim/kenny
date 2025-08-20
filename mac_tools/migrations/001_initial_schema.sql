-- Initial schema for Personal Assistant
-- Supports: Mail, Calendar, Reminders, Notes, Files, iMessages, WhatsApp, Contacts
-- Design: Cross-domain relationships, provenance tracking, FTS5 search

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- Core documents table - unified view of all content
CREATE TABLE documents (
    id TEXT PRIMARY KEY,                    -- UUID or app-specific ID
    type TEXT NOT NULL,                     -- 'email', 'message', 'event', 'reminder', 'note', 'file', 'contact'
    title TEXT NOT NULL,                    -- Subject/title/filename
    content TEXT,                           -- Full text content where available  
    app_source TEXT NOT NULL,               -- 'Mail', 'Messages', 'WhatsApp', 'Calendar', 'Reminders', 'Notes', 'Finder', 'Contacts'
    source_id TEXT,                         -- App-specific identifier
    source_path TEXT,                       -- File path or app URL scheme
    hash TEXT,                              -- Content hash for change detection
    created_at INTEGER NOT NULL,            -- Unix timestamp
    updated_at INTEGER NOT NULL,            -- Unix timestamp  
    last_seen_at INTEGER NOT NULL,         -- Last time we saw this in source system
    deleted BOOLEAN DEFAULT FALSE,          -- Soft delete/tombstone
    metadata_json TEXT,                     -- App-specific metadata as JSON
    UNIQUE(app_source, source_id)
);

CREATE INDEX idx_documents_type ON documents(type);
CREATE INDEX idx_documents_updated ON documents(updated_at);
CREATE INDEX idx_documents_hash ON documents(hash);

-- Email-specific details
CREATE TABLE emails (
    document_id TEXT PRIMARY KEY REFERENCES documents(id),
    thread_id TEXT,                         -- Mail thread identifier
    message_id TEXT UNIQUE,                 -- RFC message ID
    from_address TEXT,
    from_name TEXT,
    to_addresses TEXT,                      -- JSON array
    cc_addresses TEXT,                      -- JSON array  
    bcc_addresses TEXT,                     -- JSON array
    date_sent INTEGER,                      -- Unix timestamp
    date_received INTEGER,                  -- Unix timestamp
    is_read BOOLEAN DEFAULT FALSE,
    is_flagged BOOLEAN DEFAULT FALSE,
    mailbox TEXT,                           -- Inbox, Sent, etc
    snippet TEXT,                           -- First ~200 chars
    has_attachments BOOLEAN DEFAULT FALSE,
    attachment_names TEXT                   -- JSON array of filenames
);

CREATE INDEX idx_emails_thread ON emails(thread_id);
CREATE INDEX idx_emails_from ON emails(from_address);
CREATE INDEX idx_emails_date_received ON emails(date_received);

-- Messages (iMessage, WhatsApp, etc)
CREATE TABLE messages (
    document_id TEXT PRIMARY KEY REFERENCES documents(id),
    thread_id TEXT,                         -- Conversation identifier
    from_contact TEXT,                      -- Phone/handle
    to_contacts TEXT,                       -- JSON array
    date_sent INTEGER,
    is_from_me BOOLEAN DEFAULT FALSE,
    is_read BOOLEAN DEFAULT FALSE,
    service TEXT,                           -- 'iMessage', 'SMS', 'WhatsApp'
    chat_name TEXT,                         -- Group chat name
    has_attachments BOOLEAN DEFAULT FALSE,
    attachment_types TEXT                   -- JSON array: ['image', 'video', etc]
);

CREATE INDEX idx_messages_thread ON messages(thread_id);
CREATE INDEX idx_messages_date ON messages(date_sent);
CREATE INDEX idx_messages_service ON messages(service);

-- Calendar events
CREATE TABLE events (
    document_id TEXT PRIMARY KEY REFERENCES documents(id),
    start_time INTEGER NOT NULL,            -- Unix timestamp
    end_time INTEGER,                       -- Unix timestamp (null for all-day)
    is_all_day BOOLEAN DEFAULT FALSE,
    location TEXT,
    attendees TEXT,                         -- JSON array of {name, email, status}
    organizer_name TEXT,
    organizer_email TEXT,
    status TEXT,                            -- 'confirmed', 'tentative', 'cancelled'
    calendar_name TEXT,                     -- Which calendar
    recurrence_rule TEXT,                   -- RRULE if recurring
    timezone TEXT DEFAULT 'America/Los_Angeles'
);

CREATE INDEX idx_events_start_time ON events(start_time);
CREATE INDEX idx_events_calendar ON events(calendar_name);
CREATE INDEX idx_events_status ON events(status);

-- Reminders/Tasks
CREATE TABLE reminders (
    document_id TEXT PRIMARY KEY REFERENCES documents(id),
    due_date INTEGER,                       -- Unix timestamp
    is_completed BOOLEAN DEFAULT FALSE,
    completed_date INTEGER,                 -- Unix timestamp
    priority INTEGER DEFAULT 0,             -- 0=none, 1=low, 5=medium, 9=high
    list_name TEXT,                         -- Which reminder list
    notes TEXT,
    tags TEXT,                              -- JSON array
    subtasks TEXT                           -- JSON array of subtask objects
);

CREATE INDEX idx_reminders_due_date ON reminders(due_date);
CREATE INDEX idx_reminders_completed ON reminders(is_completed);
CREATE INDEX idx_reminders_list ON reminders(list_name);

-- Notes
CREATE TABLE notes (
    document_id TEXT PRIMARY KEY REFERENCES documents(id),
    folder TEXT,                            -- Notes folder
    is_locked BOOLEAN DEFAULT FALSE,
    modification_date INTEGER,              -- When note was last edited
    creation_date INTEGER,
    snippet TEXT,                           -- First ~200 chars
    word_count INTEGER DEFAULT 0
);

CREATE INDEX idx_notes_folder ON notes(folder);
CREATE INDEX idx_notes_modified ON notes(modification_date);

-- Files
CREATE TABLE files (
    document_id TEXT PRIMARY KEY REFERENCES documents(id),
    file_path TEXT UNIQUE NOT NULL,
    filename TEXT NOT NULL,
    file_extension TEXT,
    file_size INTEGER,                      -- Bytes
    mime_type TEXT,
    parent_directory TEXT,
    is_directory BOOLEAN DEFAULT FALSE,
    permissions TEXT,                       -- rwxrwxrwx format
    owner TEXT,
    group_name TEXT,
    creation_date INTEGER,
    modification_date INTEGER,
    access_date INTEGER,
    spotlight_content TEXT,                 -- Extracted text content
    tags TEXT                               -- JSON array of Finder tags
);

CREATE INDEX idx_files_path ON files(file_path);
CREATE INDEX idx_files_extension ON files(file_extension);
CREATE INDEX idx_files_directory ON files(parent_directory);
CREATE INDEX idx_files_modified ON files(modification_date);

-- Contacts
CREATE TABLE contacts (
    document_id TEXT PRIMARY KEY REFERENCES documents(id),
    first_name TEXT,
    last_name TEXT,
    full_name TEXT,
    company TEXT,
    job_title TEXT,
    emails TEXT,                            -- JSON array
    phone_numbers TEXT,                     -- JSON array  
    addresses TEXT,                         -- JSON array
    birthday INTEGER,                       -- Unix timestamp
    notes TEXT,
    groups TEXT,                            -- JSON array of contact groups
    image_path TEXT                         -- Path to contact photo
);

CREATE INDEX idx_contacts_name ON contacts(full_name);
CREATE INDEX idx_contacts_company ON contacts(company);

-- Relationships between entities (emails about events, files attached to emails, etc)
CREATE TABLE relationships (
    id TEXT PRIMARY KEY,
    from_document_id TEXT NOT NULL REFERENCES documents(id),
    to_document_id TEXT NOT NULL REFERENCES documents(id),
    relationship_type TEXT NOT NULL,        -- 'attachment', 'reference', 'reply_to', 'meeting_about', etc
    strength REAL DEFAULT 1.0,              -- Relationship strength (0.0-1.0)
    created_at INTEGER NOT NULL,
    metadata_json TEXT,                     -- Relationship-specific data
    UNIQUE(from_document_id, to_document_id, relationship_type)
);

CREATE INDEX idx_relationships_from ON relationships(from_document_id);
CREATE INDEX idx_relationships_to ON relationships(to_document_id);
CREATE INDEX idx_relationships_type ON relationships(relationship_type);

-- FTS5 virtual tables for full-text search
CREATE VIRTUAL TABLE documents_fts USING fts5(
    title,
    content,
    snippet,
    content='documents',
    content_rowid='rowid'
);

CREATE VIRTUAL TABLE emails_fts USING fts5(
    from_name,
    from_address, 
    subject,
    snippet,
    content='emails',
    content_rowid='rowid'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER documents_fts_insert AFTER INSERT ON documents BEGIN
    INSERT INTO documents_fts(rowid, title, content, snippet)
    VALUES (new.rowid, new.title, new.content, substr(new.content, 1, 200));
END;

CREATE TRIGGER documents_fts_delete AFTER DELETE ON documents BEGIN
    INSERT INTO documents_fts(documents_fts, rowid, title, content, snippet)
    VALUES ('delete', old.rowid, old.title, old.content, substr(old.content, 1, 200));
END;

CREATE TRIGGER documents_fts_update AFTER UPDATE ON documents BEGIN
    INSERT INTO documents_fts(documents_fts, rowid, title, content, snippet)
    VALUES ('delete', old.rowid, old.title, old.content, substr(old.content, 1, 200));
    INSERT INTO documents_fts(rowid, title, content, snippet)
    VALUES (new.rowid, new.title, new.content, substr(new.content, 1, 200));
END;

-- Action audit log (from existing requirement)
CREATE TABLE actions (
    id TEXT PRIMARY KEY,
    session_id TEXT,
    tool TEXT NOT NULL,
    input_json TEXT NOT NULL,
    output_json TEXT,
    status TEXT NOT NULL,                   -- 'pending', 'success', 'error', 'cancelled'
    started_at INTEGER NOT NULL,
    ended_at INTEGER,
    error_message TEXT,
    retry_count INTEGER DEFAULT 0
);

CREATE INDEX idx_actions_session ON actions(session_id);
CREATE INDEX idx_actions_tool ON actions(tool);
CREATE INDEX idx_actions_started ON actions(started_at);

-- Plans for dry-run/confirm workflow
CREATE TABLE plans (
    id TEXT PRIMARY KEY,
    session_id TEXT,
    steps_json TEXT NOT NULL,               -- Array of planned steps
    status TEXT NOT NULL,                   -- 'draft', 'confirmed', 'executing', 'completed', 'cancelled'
    created_at INTEGER NOT NULL,
    confirmed_at INTEGER,
    executed_at INTEGER,
    completed_at INTEGER,
    confirmation_hash TEXT                  -- For dry-run validation
);

CREATE INDEX idx_plans_session ON plans(session_id);
CREATE INDEX idx_plans_status ON plans(status);
CREATE INDEX idx_plans_hash ON plans(confirmation_hash);

-- Background jobs queue
CREATE TABLE jobs (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,                     -- 'ingest_full', 'ingest_delta', 'cleanup', etc
    payload_json TEXT NOT NULL,
    scheduled_for INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending', -- 'pending', 'running', 'completed', 'failed'
    attempts INTEGER DEFAULT 0,
    max_attempts INTEGER DEFAULT 3,
    last_error TEXT,
    created_at INTEGER NOT NULL,
    started_at INTEGER,
    completed_at INTEGER
);

CREATE INDEX idx_jobs_scheduled ON jobs(scheduled_for);
CREATE INDEX idx_jobs_status ON jobs(status);
CREATE INDEX idx_jobs_type ON jobs(type);

-- Schema version tracking
CREATE TABLE schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at INTEGER NOT NULL
);

INSERT INTO schema_migrations (version, applied_at) VALUES (1, strftime('%s', 'now'));