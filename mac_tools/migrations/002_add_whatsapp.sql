-- Add WhatsApp support to messages table and update schema
-- Based on WhatsApp MCP extraction patterns from https://github.com/lharries/whatsapp-mcp

-- Add WhatsApp-specific columns to messages table
ALTER TABLE messages ADD COLUMN whatsapp_chat_id TEXT;
ALTER TABLE messages ADD COLUMN whatsapp_message_type TEXT; -- 'text', 'image', 'video', 'audio', 'document', etc
ALTER TABLE messages ADD COLUMN whatsapp_quoted_message_id TEXT;
ALTER TABLE messages ADD COLUMN whatsapp_forwarded BOOLEAN DEFAULT FALSE;
ALTER TABLE messages ADD COLUMN whatsapp_media_path TEXT;
ALTER TABLE messages ADD COLUMN whatsapp_media_mime_type TEXT;

-- Create index for WhatsApp-specific queries
CREATE INDEX idx_messages_whatsapp_chat ON messages(whatsapp_chat_id);
CREATE INDEX idx_messages_whatsapp_type ON messages(whatsapp_message_type);

-- Update schema version
INSERT INTO schema_migrations (version, applied_at) VALUES (2, strftime('%s', 'now'));