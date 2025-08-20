-- Minimal test data insertion bypassing FTS triggers

-- Disable FTS triggers temporarily  
DROP TRIGGER IF EXISTS documents_fts_insert;
DROP TRIGGER IF EXISTS documents_fts_delete; 
DROP TRIGGER IF EXISTS documents_fts_update;

-- Clear existing test data
DELETE FROM documents WHERE id LIKE 'test-%';

-- Insert minimal test documents
INSERT INTO documents (id, type, title, content, app_source, source_id, source_path, hash, created_at, updated_at, last_seen_at, deleted) VALUES 
('test-email-apollo', 'email', 'Project Apollo Status Update', 'Project Apollo status update with budget information and March milestone review. Backend API development 85% complete. Budget: $127,000 spent of $180,000 allocated.', 'Mail', 'apollo-email-001', 'message://apollo-status-march-2024', 'hash-apollo-email', 1710444000, 1710444000, 1710444000, 0),

('test-email-budget', 'email', 'Budget Review Q2', 'Q2 budget review meeting next week. Submit departmental budget requests by Friday. Focus areas: Infrastructure investments, team expansion, training allocations.', 'Mail', 'budget-q2-001', 'message://budget-review-q2-2024', 'hash-budget-email', 1710358000, 1710358000, 1710358000, 0),

('test-note-1on1', 'note', '1:1 with Jon Larsen', 'Meeting with Jon Larsen about microservices migration progress. Action items: architecture review meeting, performance benchmarking, contractor interviews.', 'Notes', 'note-1on1-larsen', 'x-coredata://note-1on1-jon-larsen-march', 'hash-note-1on1', 1710108000, 1710108000, 1710108000, 0),

('test-note-design', 'note', 'Design Decisions Async Processing', 'Design decision to implement asynchronous processing with queue system for better scalability and user experience. Migration from synchronous to async approach.', 'Notes', 'note-design-sync-async', 'x-coredata://note-design-decisions-sync-async', 'hash-note-design', 1710194000, 1710194000, 1710194000, 0),

('test-event-offsite', 'event', 'Team Offsite Planning', 'Team offsite planning session for Q2 strategy. Location: Redwood Conference Center Palo Alto. Attendees include engineering, product, and design teams.', 'Calendar', 'event-offsite-q2-2024', 'x-apple-eventkit://event-team-offsite-march', 'hash-event-offsite', 1711094400, 1711094400, 1711094400, 0),

('test-file-roadmap', 'file', 'Product Roadmap 2024', 'Product development roadmap with Q1-Q4 milestones. Focus on user experience improvements, scalability enhancements, API optimization, and enterprise features.', 'Files', 'file-roadmap-2024', '/Users/team/Documents/Product/Roadmap.md', 'hash-file-roadmap', 1709251200, 1710460800, 1710460800, 0);

-- Manually add to FTS (using only existing columns)
INSERT INTO documents_fts (rowid, title, content) 
SELECT rowid, title, content FROM documents WHERE id LIKE 'test-%';

-- Verify insertion
SELECT 'Test data inserted:' as status;
SELECT id, type, title FROM documents WHERE id LIKE 'test-%' ORDER BY type, id;