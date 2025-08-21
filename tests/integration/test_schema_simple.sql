-- Simplified schema test without complex triggers
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- Core documents table
CREATE TABLE documents (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    title TEXT NOT NULL,
    content TEXT,
    app_source TEXT NOT NULL,
    source_id TEXT,
    source_path TEXT,
    hash TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    deleted BOOLEAN DEFAULT FALSE,
    UNIQUE(app_source, source_id)
);

-- Simple FTS5 table
CREATE VIRTUAL TABLE documents_fts USING fts5(
    title,
    content,
    content=documents,
    content_rowid=rowid
);

-- Test data
INSERT INTO documents (id, type, title, content, app_source, source_id, source_path, hash, created_at, updated_at, last_seen_at, deleted)
VALUES 
    ('test-1', 'email', 'Project Meeting', 'Discussing quarterly project updates and milestones', 'Mail', 'msg-1', 'message://1', 'hash1', 1672531200, 1672531200, 1672531200, 0),
    ('test-2', 'contact', 'John Smith', 'john.smith@company.com Product Manager', 'Contacts', 'contact-1', 'addressbook://1', 'hash2', 1672531200, 1672531200, 1672531200, 0),
    ('test-3', 'event', 'Team Standup', 'Daily team standup meeting in conference room A', 'Calendar', 'event-1', 'calendar://1', 'hash3', 1672531200, 1672531200, 1672531200, 0);

-- Populate FTS
INSERT INTO documents_fts(documents_fts) VALUES('rebuild');

-- Test queries
SELECT 'Basic count:' as test, COUNT(*) as result FROM documents;

SELECT 'FTS search for "project":' as test;
SELECT title, snippet(documents_fts, 1, '<mark>', '</mark>', '...', 32) as snippet 
FROM documents_fts 
JOIN documents ON documents_fts.rowid = documents.rowid
WHERE documents_fts MATCH 'project';

SELECT 'FTS search for "meeting":' as test;  
SELECT title, snippet(documents_fts, 1, '<mark>', '</mark>', '...', 32) as snippet
FROM documents_fts
JOIN documents ON documents_fts.rowid = documents.rowid  
WHERE documents_fts MATCH 'meeting';