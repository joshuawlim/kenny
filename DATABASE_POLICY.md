# Kenny Database Policy

## Single Source of Truth

**The ONLY Kenny database is: `/mac_tools/kenny.db`**

This database is the authoritative source for all Kenny operations and is referenced by the Orchestrator agent.

## Database Rules

1. **NO NEW KENNY DATABASES**: Do not create any new files named `kenny*.db` anywhere in the repository
2. **Single Location**: The database MUST remain at `/mac_tools/kenny.db`
3. **Backup Naming**: Backups should use the format: `kenny_backup_YYYYMMDD_HHMMSS.db`
4. **Test Databases**: Use descriptive names like `test_ingestion.db` or `temp_migration.db` - never `kenny_test.db`

## Validation and Enforcement

### Automated Validation
- **Pre-commit Hook**: `.git/hooks/pre-commit` prevents commits with database violations
- **Validation Script**: `scripts/validate_repo.py` runs comprehensive structure checks
- **Configuration**: `.kennyrc` defines all enforcement rules and forbidden paths

### Common AI Agent Mistakes (FORBIDDEN)
- ❌ Creating `kenny.db` in project root
- ❌ Creating nested `mac_tools/mac_tools/` directories  
- ❌ Making database copies like `kenny_copy.db`, `kenny_backup.db`
- ❌ Using wrong paths in scripts or tools

### Recovery Commands
```bash
# If database is in wrong location, use restore tool:
python3 tools/db_restore.py kenny_YYYYMMDD_HHMMSS_UTC.db --force

# Validate repository structure:
python3 scripts/validate_repo.py

# Check current violations:
git commit --dry-run  # Triggers pre-commit hook
```

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