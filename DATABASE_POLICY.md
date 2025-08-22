# Kenny Database Policy

## Single Source of Truth

**The ONLY Kenny database is: `/mac_tools/kenny.db`**

This database is the authoritative source for all Kenny operations and is referenced by the Orchestrator agent.

## Database Rules

1. **NO NEW KENNY DATABASES**: Do not create any new files named `kenny*.db` anywhere in the repository
2. **Single Location**: The database MUST remain at `/mac_tools/kenny.db`
3. **Backup Naming**: Backups should use the format: `kenny_backup_YYYYMMDD_HHMMSS.db`
4. **Test Databases**: Use descriptive names like `test_ingestion.db` or `temp_migration.db` - never `kenny_test.db`

## Current Database Contents

As of 2025-08-22, the database contains:
- WhatsApp: 177,325 documents
- Mail: 27,144 documents  
- Messages: 26,861 documents
- Contacts: 1,321 documents
- Calendar: 703 documents

Total: ~233,354 documents

## Database Access

The Orchestrator CLI and all Swift tools reference the database using the relative path `"kenny.db"` when run from the `mac_tools` directory.

## Migration Guidelines

When modifying the database:
1. Always backup first: `cp mac_tools/kenny.db mac_tools/kenny_backup_$(date +%Y%m%d_%H%M%S).db`
2. Run migrations in the `mac_tools` directory
3. Test with the Orchestrator CLI after changes
4. Remove backup files after confirming success

## Enforcement

This policy is enforced through:
- `.gitignore` rules preventing accidental commits of wrong database files
- Code reviews ensuring no new database files are created
- Clear documentation in this file