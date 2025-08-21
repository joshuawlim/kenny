-- Canned search queries for testing FTS5 functionality
-- These test multi-domain search capabilities for personal assistant use cases

-- Query 1: Find emails about meetings
-- Expected: Should return emails containing "meeting", "schedule", or "calendar" terms
SELECT 
    d.title,
    d.type,
    snippet(documents_fts, 1, '<mark>', '</mark>', '...', 32) as snippet,
    e.from_name,
    e.date_received,
    bm25(documents_fts) as rank
FROM documents_fts 
JOIN documents d ON documents_fts.rowid = d.rowid
LEFT JOIN emails e ON d.id = e.document_id
WHERE documents_fts MATCH 'meeting OR schedule OR calendar'
  AND d.type = 'email'
  AND d.deleted = FALSE
ORDER BY rank
LIMIT 10;

-- Query 2: Cross-domain search - emails and events about projects
-- Expected: Should return both emails and calendar events related to projects
SELECT 
    d.title,
    d.type,
    d.app_source,
    snippet(documents_fts, 1, '<mark>', '</mark>', '...', 32) as snippet,
    CASE d.type
        WHEN 'email' THEN e.from_name
        WHEN 'event' THEN ev.location
        ELSE d.app_source
    END as context_info,
    bm25(documents_fts) as rank
FROM documents_fts 
JOIN documents d ON documents_fts.rowid = d.rowid
LEFT JOIN emails e ON d.id = e.document_id
LEFT JOIN events ev ON d.id = ev.document_id
WHERE documents_fts MATCH 'project OR update OR status OR quarterly'
  AND d.type IN ('email', 'event')
  AND d.deleted = FALSE
ORDER BY rank
LIMIT 15;

-- Query 3: Recent activity across all domains
-- Expected: Should return recent items from all data sources
SELECT 
    d.title,
    d.type,
    d.app_source,
    datetime(d.updated_at, 'unixepoch') as updated_time,
    snippet(documents_fts, 1, '<mark>', '</mark>', '...', 32) as snippet
FROM documents_fts 
JOIN documents d ON documents_fts.rowid = d.rowid
WHERE d.updated_at > strftime('%s', 'now', '-7 days')
  AND d.deleted = FALSE
ORDER BY d.updated_at DESC
LIMIT 20;

-- Query 4: Find people and their associated content
-- Expected: Should return contacts and related emails/messages
SELECT DISTINCT
    d1.title as person_name,
    d1.type as person_type,
    d2.title as related_title,
    d2.type as related_type,
    d2.app_source,
    snippet(documents_fts, 1, '<mark>', '</mark>', '...', 32) as snippet,
    r.relationship_type
FROM documents_fts
JOIN documents d1 ON documents_fts.rowid = d1.rowid
JOIN relationships r ON (d1.id = r.from_document_id OR d1.id = r.to_document_id)
JOIN documents d2 ON (r.from_document_id = d2.id OR r.to_document_id = d2.id)
WHERE documents_fts MATCH 'john OR jane'
  AND d1.type = 'contact'
  AND d2.id != d1.id
  AND d1.deleted = FALSE
  AND d2.deleted = FALSE
ORDER BY r.strength DESC
LIMIT 10;

-- Query 5: Complex search with date filtering and multiple terms
-- Expected: Should return emails from last month containing specific business terms
SELECT 
    d.title,
    e.from_name,
    e.from_address,
    datetime(e.date_received, 'unixepoch') as received_date,
    snippet(documents_fts, 1, '<mark>', '</mark>', '...', 32) as snippet,
    bm25(documents_fts) as relevance_score
FROM documents_fts 
JOIN documents d ON documents_fts.rowid = d.rowid
JOIN emails e ON d.id = e.document_id
WHERE documents_fts MATCH '(report OR analysis OR quarterly) AND (meeting OR discussion)'
  AND d.type = 'email'
  AND e.date_received > strftime('%s', 'now', '-30 days')
  AND d.deleted = FALSE
ORDER BY relevance_score
LIMIT 12;

-- Bonus Query: Test relationship strength and cross-references
-- Expected: Should show how documents are interconnected
SELECT 
    d1.title as source_title,
    d1.type as source_type,
    r.relationship_type,
    r.strength,
    d2.title as target_title,
    d2.type as target_type,
    d2.app_source
FROM relationships r
JOIN documents d1 ON r.from_document_id = d1.id
JOIN documents d2 ON r.to_document_id = d2.id
WHERE r.strength > 0.5
  AND d1.deleted = FALSE
  AND d2.deleted = FALSE
ORDER BY r.strength DESC, r.created_at DESC
LIMIT 20;