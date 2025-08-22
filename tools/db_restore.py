#!/usr/bin/env python3
"""
Kenny Database Restore Tool
Restores Kenny database from backup files with interactive confirmation and audit logging.
"""

import sqlite3
import sys
import os
import shutil
import time
from datetime import datetime, timezone
from pathlib import Path
import argparse
import glob

class KennyDBRestore:
    """Robust SQLite restore system for Kenny database"""
    
    def __init__(self, repo_root=None):
        if repo_root is None:
            # Auto-detect repo root by finding Kenny directory structure
            current_dir = Path(__file__).resolve().parent
            while current_dir.parent != current_dir:
                if (current_dir / "mac_tools").exists():
                    repo_root = current_dir
                    break
                current_dir = current_dir.parent
            
            if repo_root is None:
                raise RuntimeError("Could not find Kenny repository root with mac_tools directory")
        
        self.repo_root = Path(repo_root)
        self.target_db = self.repo_root / "mac_tools" / "kenny.db"
        self.backup_dir = self.repo_root / "backups"
        self.log_dir = self.repo_root / "logs"
        self.restore_log = self.log_dir / "db_restore.log"
        
        # Ensure log directory exists
        self.log_dir.mkdir(exist_ok=True)
        
        # Verify backup directory exists
        if not self.backup_dir.exists():
            raise FileNotFoundError(f"Backup directory not found: {self.backup_dir}")
    
    def list_available_backups(self):
        """List all available backup files"""
        backup_pattern = str(self.backup_dir / "kenny_*_UTC.db")
        backup_files = sorted(glob.glob(backup_pattern), reverse=True)
        
        if not backup_files:
            print("No backups found in", self.backup_dir)
            return []
        
        print(f"Available backups in {self.backup_dir}:")
        print("-" * 80)
        for i, backup_file in enumerate(backup_files):
            backup_path = Path(backup_file)
            size_mb = backup_path.stat().st_size / (1024 * 1024)
            mtime = datetime.fromtimestamp(backup_path.stat().st_mtime)
            print(f"{i+1:2d}. {backup_path.name}")
            print(f"    Size: {size_mb:.1f}MB, Modified: {mtime.strftime('%Y-%m-%d %H:%M:%S')}")
        print("-" * 80)
        
        return backup_files
    
    def verify_backup_integrity(self, backup_path):
        """Verify backup database integrity"""
        try:
            print(f"Verifying integrity of {Path(backup_path).name}...")
            conn = sqlite3.connect(backup_path)
            cursor = conn.cursor()
            
            # Run integrity check
            cursor.execute("PRAGMA integrity_check")
            result = cursor.fetchone()
            
            conn.close()
            
            if result and result[0] == "ok":
                print("✓ Backup integrity verified")
                return True
            else:
                print(f"✗ Backup integrity check failed: {result}")
                return False
                
        except Exception as e:
            print(f"✗ Error verifying backup: {e}")
            return False
    
    def get_confirmation(self, backup_path, force=False):
        """Get user confirmation for restore operation"""
        if force:
            return True
        
        print("\n" + "="*80)
        print("🚨 DATABASE RESTORE CONFIRMATION")
        print("="*80)
        print(f"Source backup: {Path(backup_path).name}")
        print(f"Target database: {self.target_db}")
        print()
        print("⚠️  WARNING: This will completely replace your current Kenny database!")
        print("⚠️  All current data will be lost unless you have other backups.")
        print()
        
        # Show current database info if it exists
        if self.target_db.exists():
            current_size = self.target_db.stat().st_size / (1024 * 1024)
            current_mtime = datetime.fromtimestamp(self.target_db.stat().st_mtime)
            print(f"Current database: {current_size:.1f}MB, Modified: {current_mtime.strftime('%Y-%m-%d %H:%M:%S')}")
        else:
            print("Current database: Does not exist")
        
        backup_size = Path(backup_path).stat().st_size / (1024 * 1024)
        backup_mtime = datetime.fromtimestamp(Path(backup_path).stat().st_mtime)
        print(f"Backup to restore: {backup_size:.1f}MB, Modified: {backup_mtime.strftime('%Y-%m-%d %H:%M:%S')}")
        print()
        
        response = input("Are you absolutely sure you want to proceed? (type 'YES' to confirm): ")
        return response.strip() == "YES"
    
    def log_restore_operation(self, backup_path, success, error_msg=None):
        """Log restore operation to audit log"""
        timestamp = datetime.now(timezone.utc).isoformat()
        backup_name = Path(backup_path).name
        status = "SUCCESS" if success else "FAILED"
        
        log_entry = f"[{timestamp}] RESTORE {status}: backup={backup_name}, target={self.target_db}"
        if error_msg:
            log_entry += f", error={error_msg}"
        log_entry += "\n"
        
        try:
            with open(self.restore_log, "a") as f:
                f.write(log_entry)
        except Exception as e:
            print(f"Warning: Could not write to restore log: {e}")
    
    def restore_database(self, backup_path, force=False):
        """Restore database from backup with safety checks"""
        backup_path = Path(backup_path)
        
        # Verify backup file exists
        if not backup_path.exists():
            raise FileNotFoundError(f"Backup file not found: {backup_path}")
        
        # Verify backup integrity
        if not self.verify_backup_integrity(backup_path):
            raise RuntimeError("Backup file failed integrity check")
        
        # Get user confirmation
        if not self.get_confirmation(backup_path, force=force):
            print("Restore operation cancelled by user")
            self.log_restore_operation(backup_path, False, "cancelled_by_user")
            return False
        
        print(f"\n🔄 Starting restore operation...")
        
        try:
            # Create temporary backup of current database if it exists
            temp_backup = None
            if self.target_db.exists():
                temp_backup = self.target_db.with_suffix('.db.restore_temp')
                print(f"Creating temporary backup of current database...")
                shutil.copy2(self.target_db, temp_backup)
            
            # Close any existing connections and remove target
            if self.target_db.exists():
                # Remove WAL and SHM files if they exist
                for suffix in ['-wal', '-shm']:
                    wal_file = self.target_db.with_suffix(f'.db{suffix}')
                    if wal_file.exists():
                        wal_file.unlink()
                
                self.target_db.unlink()
            
            # Copy backup to target location
            print(f"Copying backup to target location...")
            shutil.copy2(backup_path, self.target_db)
            
            # Verify restored database
            print("Verifying restored database...")
            if not self.verify_backup_integrity(self.target_db):
                # Restore failed, try to recover
                if temp_backup and temp_backup.exists():
                    print("Restore verification failed, recovering original database...")
                    shutil.copy2(temp_backup, self.target_db)
                raise RuntimeError("Restored database failed verification")
            
            # Clean up temporary backup
            if temp_backup and temp_backup.exists():
                temp_backup.unlink()
            
            # Log success
            restored_size = self.target_db.stat().st_size / (1024 * 1024)
            print(f"✅ Database successfully restored!")
            print(f"   Restored database: {restored_size:.1f}MB")
            print(f"   Target location: {self.target_db}")
            
            self.log_restore_operation(backup_path, True)
            return True
            
        except Exception as e:
            error_msg = str(e)
            print(f"❌ Restore failed: {error_msg}")
            self.log_restore_operation(backup_path, False, error_msg)
            raise

def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(description="Kenny Database Restore Tool")
    parser.add_argument("backup_file", nargs="?", help="Backup file to restore (required unless --list)")
    parser.add_argument("--list", action="store_true", help="List available backups")
    parser.add_argument("--force", action="store_true", help="Skip interactive confirmation")
    parser.add_argument("--repo-root", type=str, help="Repository root path (auto-detected if not provided)")
    
    args = parser.parse_args()
    
    # Require Python 3.9+
    if sys.version_info < (3, 9):
        print("Error: Python 3.9+ required", file=sys.stderr)
        return 1
    
    try:
        restore_system = KennyDBRestore(repo_root=args.repo_root)
        
        if args.list:
            restore_system.list_available_backups()
            return 0
        
        if not args.backup_file:
            print("Error: backup_file argument required (use --list to see available backups)", file=sys.stderr)
            return 1
        
        # Convert relative path to absolute if needed
        backup_path = Path(args.backup_file)
        if not backup_path.is_absolute():
            backup_path = restore_system.backup_dir / backup_path
        
        success = restore_system.restore_database(backup_path, force=args.force)
        return 0 if success else 1
        
    except Exception as e:
        print(f"RESTORE_ERROR: {e}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())