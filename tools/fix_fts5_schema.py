#!/usr/bin/env python3
"""
Kenny FTS5 Schema Repair Tool
Fixes database schema corruption without deleting kenny.db or losing data
"""

import sqlite3
import sys
import os
from pathlib import Path
import shutil
from datetime import datetime

class FTS5SchemaRepairer:
    def __init__(self, db_path):
        self.db_path = Path(db_path)
        self.backup_path = None
        
    def create_safety_backup(self):
        """Create safety backup before any modifications"""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.backup_path = self.db_path.parent / f"kenny_fts5_repair_backup_{timestamp}.db"
        
        print(f"Creating safety backup: {self.backup_path}")
        shutil.copy2(self.db_path, self.backup_path)
        
        # Verify backup
        try:
            conn = sqlite3.connect(self.backup_path)
            cursor = conn.cursor()
            cursor.execute("SELECT COUNT(*) FROM documents")
            count = cursor.fetchone()[0]
            conn.close()
            print(f"✓ Backup verified: {count:,} documents preserved")
            return True
        except Exception as e:
            print(f"✗ Backup verification failed: {e}")
            return False
    
    def diagnose_schema_issues(self):
        """Diagnose FTS5 schema issues"""
        print("Diagnosing FTS5 schema issues...")
        
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        issues = []
        
        try:
            # Check documents_fts table structure
            cursor.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='documents_fts'")
            fts_table = cursor.fetchone()
            if fts_table:
                print(f"documents_fts table: {fts_table[0]}")
                # Extract column names from FTS5 definition
                sql = fts_table[0]
                if "snippet" not in sql:
                    issues.append("documents_fts table missing snippet column")
            
            # Check trigger definitions  
            cursor.execute("SELECT name, sql FROM sqlite_master WHERE type='trigger' AND name LIKE '%documents_fts%'")
            triggers = cursor.fetchall()
            
            for trigger_name, trigger_sql in triggers:
                if "snippet" in trigger_sql:
                    issues.append(f"Trigger {trigger_name} references non-existent snippet column")
                    print(f"Problematic trigger: {trigger_name}")
            
            # Test a simple FTS query
            try:
                cursor.execute("SELECT rowid FROM documents_fts LIMIT 1")
                print("✓ FTS5 table is accessible")
            except Exception as e:
                issues.append(f"FTS5 table query failed: {e}")
            
            conn.close()
            
        except Exception as e:
            issues.append(f"Schema diagnosis failed: {e}")
            conn.close()
        
        return issues
    
    def fix_triggers(self):
        """Fix the corrupted triggers"""
        print("Fixing FTS5 triggers...")
        
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        try:
            # Drop existing problematic triggers
            cursor.execute("DROP TRIGGER IF EXISTS documents_fts_insert")
            cursor.execute("DROP TRIGGER IF EXISTS documents_fts_delete") 
            cursor.execute("DROP TRIGGER IF EXISTS documents_fts_update")
            print("✓ Dropped problematic triggers")
            
            # Create correct triggers without snippet column
            cursor.execute("""
                CREATE TRIGGER documents_fts_insert AFTER INSERT ON documents BEGIN
                    INSERT INTO documents_fts(rowid, title, content, app_source)
                    VALUES (new.rowid, new.title, new.content, new.app_source);
                END
            """)
            
            cursor.execute("""
                CREATE TRIGGER documents_fts_delete AFTER DELETE ON documents BEGIN
                    INSERT INTO documents_fts(documents_fts, rowid, title, content, app_source)
                    VALUES ('delete', old.rowid, old.title, old.content, old.app_source);
                END
            """)
            
            cursor.execute("""
                CREATE TRIGGER documents_fts_update AFTER UPDATE ON documents BEGIN
                    INSERT INTO documents_fts(documents_fts, rowid, title, content, app_source)
                    VALUES ('delete', old.rowid, old.title, old.content, old.app_source);
                    INSERT INTO documents_fts(rowid, title, content, app_source)
                    VALUES (new.rowid, new.title, new.content, new.app_source);
                END
            """)
            
            conn.commit()
            print("✓ Created corrected FTS5 triggers")
            
        except Exception as e:
            conn.rollback()
            print(f"✗ Failed to fix triggers: {e}")
            conn.close()
            return False
        
        conn.close()
        return True
    
    def rebuild_fts_indexes(self):
        """Rebuild FTS5 indexes to ensure consistency"""
        print("Rebuilding FTS5 indexes...")
        
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        try:
            # Check if we need to rebuild
            cursor.execute("SELECT COUNT(*) FROM documents")
            doc_count = cursor.fetchone()[0]
            
            cursor.execute("SELECT COUNT(*) FROM documents_fts")
            fts_count = cursor.fetchone()[0]
            
            print(f"Documents table: {doc_count:,} rows")
            print(f"FTS table: {fts_count:,} rows")
            
            if doc_count != fts_count:
                print("FTS index out of sync, rebuilding...")
                cursor.execute("INSERT INTO documents_fts(documents_fts) VALUES('rebuild')")
                conn.commit()
                print("✓ FTS index rebuilt")
            else:
                print("✓ FTS index already in sync")
            
        except Exception as e:
            print(f"✗ Failed to rebuild FTS index: {e}")
            conn.rollback()
            conn.close()
            return False
        
        conn.close()
        return True
    
    def test_fts_functionality(self):
        """Test that FTS5 functionality works correctly"""
        print("Testing FTS5 functionality...")
        
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        try:
            # Test basic FTS search
            cursor.execute("SELECT COUNT(*) FROM documents_fts WHERE documents_fts MATCH 'test'")
            search_count = cursor.fetchone()[0]
            print(f"✓ FTS search test successful ({search_count} results)")
            
            # Test snippet function (the problematic query)
            cursor.execute("""
                SELECT d.title, 
                       snippet(documents_fts, 1, '<mark>', '</mark>', '...', 32) as snippet
                FROM documents_fts
                JOIN documents d ON documents_fts.rowid = d.rowid
                WHERE documents_fts MATCH 'message'
                LIMIT 1
            """)
            result = cursor.fetchone()
            if result:
                print("✓ Snippet function test successful")
            else:
                print("⚠ Snippet function returned no results")
            
        except Exception as e:
            print(f"✗ FTS functionality test failed: {e}")
            conn.close()
            return False
        
        conn.close()
        return True
    
    def repair_schema(self):
        """Complete schema repair process"""
        print("=" * 60)
        print("KENNY FTS5 SCHEMA REPAIR TOOL")
        print("=" * 60)
        
        if not self.db_path.exists():
            print(f"✗ Database not found: {self.db_path}")
            return False
        
        # Create safety backup
        if not self.create_safety_backup():
            print("✗ Failed to create safety backup - aborting")
            return False
        
        # Diagnose issues
        issues = self.diagnose_schema_issues()
        print(f"\nFound {len(issues)} schema issues:")
        for issue in issues:
            print(f"  - {issue}")
        
        if not issues:
            print("✓ No schema issues found!")
            return True
        
        # Fix triggers
        if not self.fix_triggers():
            print("✗ Failed to fix triggers")
            return False
        
        # Rebuild indexes
        if not self.rebuild_fts_indexes():
            print("✗ Failed to rebuild FTS indexes")
            return False
        
        # Test functionality
        if not self.test_fts_functionality():
            print("✗ FTS functionality test failed")
            return False
        
        print("\n" + "=" * 60)
        print("✓ FTS5 SCHEMA REPAIR COMPLETED SUCCESSFULLY")
        print("=" * 60)
        print(f"Original database preserved")
        print(f"Backup created at: {self.backup_path}")
        print("Database is now ready for ingestion")
        
        return True

def main():
    """Main execution"""
    kenny_db = Path("/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db")
    
    repairer = FTS5SchemaRepairer(kenny_db)
    success = repairer.repair_schema()
    
    if success:
        print("\nYou can now run comprehensive_ingest.py to test the fix")
        sys.exit(0)
    else:
        print("\nSchema repair failed. Please check the errors above.")
        sys.exit(1)

if __name__ == "__main__":
    main()