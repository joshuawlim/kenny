-- Migration: Enhanced Contacts Schema
-- Description: Add structured phone/email fields and contact threading

-- Drop existing contacts table 
DROP TABLE IF EXISTS contacts;

-- Create enhanced contacts table with structured fields
CREATE TABLE contacts (
    document_id TEXT PRIMARY KEY REFERENCES documents(id),
    contact_id TEXT UNIQUE,
    first_name TEXT,
    last_name TEXT,
    full_name TEXT,
    primary_phone TEXT,
    secondary_phone TEXT,
    tertiary_phone TEXT,
    primary_email TEXT,
    secondary_email TEXT,
    company TEXT,
    job_title TEXT,
    birthday INTEGER,
    interests TEXT,
    notes TEXT,
    date_last_interaction INTEGER,
    image_path TEXT
);

-- Create indexes for enhanced schema
CREATE INDEX idx_contacts_name ON contacts(full_name);
CREATE INDEX idx_contacts_company ON contacts(company);
CREATE INDEX idx_contacts_contact_id ON contacts(contact_id);
CREATE INDEX idx_contacts_primary_phone ON contacts(primary_phone);
CREATE INDEX idx_contacts_primary_email ON contacts(primary_email);