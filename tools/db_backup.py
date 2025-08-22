#!/usr/bin/env python3
"""
Kenny Database Backup Tool
Creates atomic SQLite backups with integrity verification and retention management.
"""

import sqlite3
import sys
import os
import time
from datetime import datetime, timezone
from pathlib import Path
import argparse
import glob

class KennyDBBackup:
    """Robust SQLite backup system for Kenny database"""
    
    def __init__(self, repo_root=None, max_backups=10):
        if repo_root is None:
            # Auto-detect repo root by finding Kenny directory structure
            current_dir = Path(__file__).resolve().parent
            while current_dir.parent != current_dir:
                if (current_dir / "mac_tools" / "kenny.db").exists():
                    repo_root = current_dir
                    break
                current_dir = current_dir.parent
            
            if repo_root is None:
                raise RuntimeError("Could not find Kenny repository root with mac_tools/kenny.db")
        
        self.repo_root = Path(repo_root)
        self.source_db = self.repo_root / "mac_tools" / "kenny.db"
        self.backup_dir = self.repo_root / "backups"
        self.max_backups = max_backups
        
        # Ensure backup directory exists
        self.backup_dir.mkdir(exist_ok=True)
        
        # Verify source database exists
        if not self.source_db.exists():
            raise FileNotFoundError(f"Source database not found: {self.source_db}")
    
    def create_backup(self):
        """Create atomic backup with integrity verification"""
        # Generate backup filename with UTC timestamp
        utc_timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S_UTC")
        backup_filename = f"kenny_{utc_timestamp}.db"
        backup_path = self.backup_dir / backup_filename
        
        print(f"Creating backup: {backup_path}")
        
        try:
            # Open source database in read-only mode
            source_conn = sqlite3.connect(f"file:{self.source_db}?mode=ro", uri=True)
            
            # Create backup database
            backup_conn = sqlite3.connect(backup_path)
            
            # Perform atomic backup using SQLite's backup API
            print("Performing atomic backup...")
            source_conn.backup(backup_conn)
            
            # Close connections
            source_conn.close()
            backup_conn.close()
            
            # Verify backup integrity
            print("Verifying backup integrity...")
            if not self._verify_backup_integrity(backup_path):
                os.unlink(backup_path)
                raise RuntimeError("Backup failed integrity check")
            
            print(f"✓ Backup created and verified: {backup_path}")
            
            # Clean up old backups
            self._cleanup_old_backups()
            
            return backup_path
            
        except Exception as e:
            # Clean up failed backup
            if backup_path.exists():
                os.unlink(backup_path)
            print(f"✗ Backup failed: {e}", file=sys.stderr)
            raise
    
    def _verify_backup_integrity(self, backup_path):
        """Verify backup database integrity using PRAGMA integrity_check"""
        try:
            conn = sqlite3.connect(backup_path)
            cursor = conn.cursor()
            
            # Run integrity check
            cursor.execute("PRAGMA integrity_check")
            result = cursor.fetchone()
            
            conn.close()
            
            if result and result[0] == "ok":
                print("✓ Integrity check passed")
                return True
            else:
                print(f"✗ Integrity check failed: {result}", file=sys.stderr)
                return False
                
        except Exception as e:
            print(f"✗ Integrity check error: {e}", file=sys.stderr)
            return False
    
    def _cleanup_old_backups(self):
        """Remove old backups, keeping only the N most recent"""
        # Find all backup files
        backup_pattern = str(self.backup_dir / "kenny_*_UTC.db")
        backup_files = sorted(glob.glob(backup_pattern), reverse=True)
        
        if len(backup_files) > self.max_backups:
            old_backups = backup_files[self.max_backups:]
            print(f"Cleaning up {len(old_backups)} old backups (keeping {self.max_backups} most recent)")
            
            for old_backup in old_backups:
                try:
                    os.unlink(old_backup)
                    print(f"  Removed: {Path(old_backup).name}")
                except Exception as e:
                    print(f"  Warning: Could not remove {old_backup}: {e}", file=sys.stderr)
    
    def list_backups(self):
        """List all available backups"""
        backup_pattern = str(self.backup_dir / "kenny_*_UTC.db")
        backup_files = sorted(glob.glob(backup_pattern), reverse=True)
        
        if not backup_files:
            print("No backups found")
            return []
        
        print(f"Found {len(backup_files)} backups:")
        for backup_file in backup_files:
            backup_path = Path(backup_file)
            size_mb = backup_path.stat().st_size / (1024 * 1024)
            mtime = datetime.fromtimestamp(backup_path.stat().st_mtime)
            print(f"  {backup_path.name} - {size_mb:.1f}MB - {mtime.strftime('%Y-%m-%d %H:%M:%S')}")
        
        return backup_files

def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(description="Kenny Database Backup Tool")
    parser.add_argument("--max-backups", type=int, default=10,
                       help="Maximum number of backups to retain (default: 10)")
    parser.add_argument("--list", action="store_true",
                       help="List existing backups instead of creating new one")
    parser.add_argument("--repo-root", type=str,
                       help="Repository root path (auto-detected if not provided)")
    
    args = parser.parse_args()
    
    try:
        backup_system = KennyDBBackup(repo_root=args.repo_root, max_backups=args.max_backups)
        
        if args.list:
            backup_system.list_backups()
        else:
            # Create backup
            start_time = time.time()
            backup_path = backup_system.create_backup()
            duration = time.time() - start_time
            
            # Print summary log line
            size_mb = backup_path.stat().st_size / (1024 * 1024)
            print(f"BACKUP_SUMMARY: path={backup_path}, size={size_mb:.1f}MB, duration={duration:.2f}s, status=verified")
        
        return 0
        
    except Exception as e:
        print(f"BACKUP_ERROR: {e}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())