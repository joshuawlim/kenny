#!/usr/bin/env python3
"""
Comprehensive Kenny Ingest System
Orchestrates ingestion from all major data sources with graceful error handling
"""

import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
import json
import sqlite3
import os

class KennyIngestOrchestrator:
    """Comprehensive ingest orchestrator for all Kenny data sources"""
    
    def __init__(self):
        self.kenny_db = "/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db"
        self.tools_dir = "/Users/joshwlim/Documents/Kenny/tools"
        self.mac_tools_dir = "/Users/joshwlim/Documents/Kenny/mac_tools"
        self.start_time = datetime.now()
        
        # Track results for all sources including backup
        self.results = {
            "Database_Backup": {"status": "pending", "count": 0, "errors": []},
            "Calendar": {"status": "pending", "count": 0, "errors": []},
            "Mail": {"status": "pending", "count": 0, "errors": []},
            "Messages": {"status": "pending", "count": 0, "errors": []},
            "Contacts": {"status": "pending", "count": 0, "errors": []},
            "WhatsApp_Bridge": {"status": "pending", "count": 0, "errors": []},
            "FTS5_Update": {"status": "pending", "count": 0, "errors": []},
            "Embeddings": {"status": "pending", "count": 0, "errors": []},
        }
    
    def run_command(self, cmd, description, cwd=None, timeout=300):
        """Run a command with error handling and logging"""
        print(f"\n{'='*60}")
        print(f"RUNNING: {description}")
        print(f"Command: {' '.join(cmd) if isinstance(cmd, list) else cmd}")
        print('='*60)
        
        try:
            if isinstance(cmd, str):
                result = subprocess.run(
                    cmd, shell=True, cwd=cwd, timeout=timeout,
                    capture_output=True, text=True
                )
            else:
                result = subprocess.run(
                    cmd, cwd=cwd, timeout=timeout,
                    capture_output=True, text=True
                )
            
            if result.stdout:
                print("STDOUT:", result.stdout)
            if result.stderr:
                print("STDERR:", result.stderr)
            
            if result.returncode == 0:
                print(f"✓ SUCCESS: {description}")
                return {"success": True, "stdout": result.stdout, "stderr": result.stderr}
            else:
                print(f"✗ FAILED: {description} (exit code: {result.returncode})")
                return {"success": False, "stdout": result.stdout, "stderr": result.stderr, "exit_code": result.returncode}
                
        except subprocess.TimeoutExpired:
            print(f"✗ TIMEOUT: {description} (>{timeout}s)")
            return {"success": False, "error": "timeout", "timeout": timeout}
        except Exception as e:
            print(f"✗ ERROR: {description} - {e}")
            return {"success": False, "error": str(e)}
    
    def get_database_counts(self):
        """Get current database record counts"""
        try:
            conn = sqlite3.connect(self.kenny_db)
            cursor = conn.cursor()
            
            cursor.execute("SELECT app_source, COUNT(*) FROM documents GROUP BY app_source ORDER BY COUNT(*) DESC")
            counts = dict(cursor.fetchall())
            
            cursor.execute("SELECT COUNT(*) FROM documents")
            total = cursor.fetchone()[0]
            
            conn.close()
            return {"total": total, "by_source": counts}
        except Exception as e:
            return {"error": str(e)}
    
    def check_whatsapp_bridge_status(self):
        """Check if WhatsApp bridge is active and receiving live messages"""
        bridge_status = {
            "process_running": False,
            "database_exists": False,
            "recent_activity": False,
            "message_count": 0,
            "last_message_time": None,
            "status": "inactive"
        }
        
        try:
            # Check if bridge process is running
            result = subprocess.run(['ps', 'aux'], capture_output=True, text=True)
            if 'kenny_whatsapp_enhanced' in result.stdout:
                bridge_status["process_running"] = True
                print("✓ WhatsApp bridge process is running")
            else:
                print("⚠️  WhatsApp bridge process not found")
            
            # Check bridge database
            bridge_db = f"{self.tools_dir}/whatsapp/whatsapp_messages.db"
            if Path(bridge_db).exists():
                bridge_status["database_exists"] = True
                print(f"✓ WhatsApp bridge database found: {bridge_db}")
                
                # Check message count and recent activity
                conn = sqlite3.connect(bridge_db)
                cursor = conn.cursor()
                
                cursor.execute("SELECT COUNT(*) FROM messages")
                bridge_status["message_count"] = cursor.fetchone()[0]
                
                cursor.execute("SELECT MAX(timestamp) FROM messages")
                latest_timestamp = cursor.fetchone()[0]
                
                if latest_timestamp:
                    latest_time = None
                    try:
                        # Handle different timestamp formats
                        if isinstance(latest_timestamp, str):
                            # Try parsing ISO format first
                            if 'T' in latest_timestamp or '+' in latest_timestamp or 'Z' in latest_timestamp:
                                from dateutil import parser
                                latest_time = parser.parse(latest_timestamp)
                            else:
                                # Try as Unix timestamp
                                latest_timestamp = float(latest_timestamp)
                                latest_time = datetime.fromtimestamp(latest_timestamp)
                        else:
                            # Numeric timestamp
                            latest_time = datetime.fromtimestamp(latest_timestamp)
                            
                        bridge_status["last_message_time"] = latest_time.isoformat()
                        
                        # Check if last message is within last 24 hours (indicating active bridge)
                        # Make latest_time timezone-naive for comparison
                        if latest_time.tzinfo is not None:
                            latest_time = latest_time.replace(tzinfo=None)
                        time_diff = datetime.now() - latest_time
                        if time_diff < timedelta(hours=24):
                            bridge_status["recent_activity"] = True
                            print(f"✓ Recent activity detected: Last message at {latest_time.strftime('%Y-%m-%d %H:%M:%S')}")
                        else:
                            print(f"⚠️  No recent activity: Last message at {latest_time.strftime('%Y-%m-%d %H:%M:%S')}")
                    except Exception as e:
                        print(f"⚠️  Could not parse timestamp: {latest_timestamp} ({e})")
                        bridge_status["last_message_time"] = str(latest_timestamp)
                
                conn.close()
                print(f"✓ Bridge database contains {bridge_status['message_count']} messages")
            else:
                print("⚠️  WhatsApp bridge database not found")
            
            # Determine overall status
            if (bridge_status["process_running"] and 
                bridge_status["database_exists"] and 
                bridge_status["recent_activity"]):
                bridge_status["status"] = "active"
                print("🟢 WhatsApp bridge is ACTIVE and receiving live messages")
            elif bridge_status["process_running"] and bridge_status["database_exists"]:
                bridge_status["status"] = "running_but_stale"
                print("🟡 WhatsApp bridge is running but no recent activity")
            else:
                bridge_status["status"] = "inactive"
                print("🔴 WhatsApp bridge is INACTIVE")
                
        except Exception as e:
            print(f"❌ Error checking WhatsApp bridge status: {e}")
            bridge_status["status"] = "error"
        
        return bridge_status
    
    def create_database_backup(self):
        """Create database backup before starting ingestion"""
        print("\n💾 CREATING DATABASE BACKUP")
        print("="*50)
        
        result = self.run_command(
            ["python3", f"{self.tools_dir}/db_backup.py"],
            "Database backup creation",
            timeout=120
        )
        
        if result["success"]:
            self.results["Database_Backup"]["status"] = "success"
            # Extract backup path from summary log line
            for line in result["stdout"].split('\n'):
                if "BACKUP_SUMMARY:" in line:
                    # Parse backup path and size info
                    if "path=" in line:
                        import re
                        path_match = re.search(r'path=([^,]+)', line)
                        size_match = re.search(r'size=([0-9.]+)MB', line)
                        if path_match:
                            backup_path = path_match.group(1)
                            backup_size = size_match.group(1) if size_match else "unknown"
                            print(f"✓ Backup created: {backup_path} ({backup_size}MB)")
                            self.results["Database_Backup"]["backup_path"] = backup_path
                            self.results["Database_Backup"]["backup_size"] = backup_size
                            break
        else:
            self.results["Database_Backup"]["status"] = "failed"
            self.results["Database_Backup"]["errors"].append(result.get("stderr", "Backup failed"))
            # Backup failure is critical - abort ingestion
            print("❌ CRITICAL: Database backup failed - aborting ingestion for safety")
            return False
        
        return True
    
    def ingest_calendar(self):
        """Ingest Calendar data using orchestrator CLI"""
        print("\n🗓️  INGESTING CALENDAR DATA")
        
        result = self.run_command(
            ["swift", "run", "orchestrator_cli", "ingest", "--sources", "Calendar"],
            "Calendar ingestion via orchestrator CLI",
            cwd=self.mac_tools_dir,
            timeout=180
        )
        
        if result["success"]:
            self.results["Calendar"]["status"] = "success"
            # Parse count from output if available
            if "calendar" in result["stdout"].lower():
                lines = result["stdout"].split('\n')
                for line in lines:
                    if "calendar" in line.lower() and any(char.isdigit() for char in line):
                        import re
                        numbers = re.findall(r'\d+', line)
                        if numbers:
                            self.results["Calendar"]["count"] = int(numbers[0])
                            break
        else:
            self.results["Calendar"]["status"] = "failed"
            self.results["Calendar"]["errors"].append(result.get("stderr", "Unknown error"))
    
    def ingest_mail(self):
        """Ingest Mail data using orchestrator CLI"""
        print("\n📧 INGESTING MAIL DATA")
        
        result = self.run_command(
            ["swift", "run", "orchestrator_cli", "ingest", "--sources", "Mail"],
            "Mail ingestion via orchestrator CLI",
            cwd=self.mac_tools_dir,
            timeout=300
        )
        
        if result["success"]:
            self.results["Mail"]["status"] = "success"
            # Parse count from output if available
            if "mail" in result["stdout"].lower():
                lines = result["stdout"].split('\n')
                for line in lines:
                    if "mail" in line.lower() and any(char.isdigit() for char in line):
                        import re
                        numbers = re.findall(r'\d+', line)
                        if numbers:
                            self.results["Mail"]["count"] = int(numbers[0])
                            break
        else:
            self.results["Mail"]["status"] = "failed"
            self.results["Mail"]["errors"].append(result.get("stderr", "Unknown error"))
    
    def ingest_messages(self):
        """Ingest Messages (iMessage/SMS) data using orchestrator CLI"""
        print("\n💬 INGESTING MESSAGES DATA")
        
        result = self.run_command(
            ["swift", "run", "orchestrator_cli", "ingest", "--sources", "Messages"],
            "Messages ingestion via orchestrator CLI",
            cwd=self.mac_tools_dir,
            timeout=300
        )
        
        if result["success"]:
            self.results["Messages"]["status"] = "success"
            # Parse count from output if available
            if "message" in result["stdout"].lower():
                lines = result["stdout"].split('\n')
                for line in lines:
                    if "message" in line.lower() and any(char.isdigit() for char in line):
                        import re
                        numbers = re.findall(r'\d+', line)
                        if numbers:
                            self.results["Messages"]["count"] = int(numbers[0])
                            break
        else:
            self.results["Messages"]["status"] = "failed"
            self.results["Messages"]["errors"].append(result.get("stderr", "Unknown error"))
    
    def ingest_contacts(self):
        """Ingest Contacts data using orchestrator CLI"""
        print("\n👥 INGESTING CONTACTS DATA")
        
        result = self.run_command(
            ["swift", "run", "orchestrator_cli", "ingest", "--sources", "Contacts"],
            "Contacts ingestion via orchestrator CLI",
            cwd=self.mac_tools_dir,
            timeout=180
        )
        
        if result["success"]:
            self.results["Contacts"]["status"] = "success"
            # Parse count from output if available
            if "contact" in result["stdout"].lower():
                lines = result["stdout"].split('\n')
                for line in lines:
                    if "contact" in line.lower() and any(char.isdigit() for char in line):
                        import re
                        numbers = re.findall(r'\d+', line)
                        if numbers:
                            self.results["Contacts"]["count"] = int(numbers[0])
                            break
        else:
            self.results["Contacts"]["status"] = "failed"
            self.results["Contacts"]["errors"].append(result.get("stderr", "Unknown error"))
    
    def ingest_whatsapp_bridge(self):
        """Import latest WhatsApp messages from bridge database"""
        print("\n💚 INGESTING WHATSAPP BRIDGE DATA")
        
        bridge_db = f"{self.tools_dir}/whatsapp/whatsapp_messages.db"
        if not Path(bridge_db).exists():
            print("⚠️  WhatsApp bridge database not found - skipping")
            print("   To enable WhatsApp sync:")
            print("   1. Set up WhatsApp MCP bridge")
            print("   2. Ensure bridge database exists at:", bridge_db)
            self.results["WhatsApp_Bridge"]["status"] = "skipped"
            self.results["WhatsApp_Bridge"]["errors"].append("Bridge database not found")
            return
        
        result = self.run_command(
            ["python3", f"{self.tools_dir}/whatsapp_bridge_importer.py"],
            "WhatsApp bridge message import",
            timeout=120
        )
        
        if result["success"]:
            self.results["WhatsApp_Bridge"]["status"] = "success"
            # Parse count from output
            if "inserted:" in result["stdout"]:
                lines = result["stdout"].split('\n')
                for line in lines:
                    if "Successfully inserted:" in line:
                        import re
                        numbers = re.findall(r'\\d+', line)
                        if numbers:
                            self.results["WhatsApp_Bridge"]["count"] = int(numbers[0])
                            break
        else:
            self.results["WhatsApp_Bridge"]["status"] = "failed"
            self.results["WhatsApp_Bridge"]["errors"].append(result.get("stderr", "Import failed"))
    
    def update_fts5(self):
        """Update FTS5 search indexes"""
        print("\n🔍 UPDATING FTS5 SEARCH INDEXES")
        
        # Rebuild FTS5 indexes to ensure consistency
        fts_commands = [
            "INSERT INTO documents_fts(documents_fts) VALUES('rebuild')",
            "INSERT INTO emails_fts(emails_fts) VALUES('rebuild')"
        ]
        
        try:
            conn = sqlite3.connect(self.kenny_db)
            cursor = conn.cursor()
            
            for cmd in fts_commands:
                print(f"Executing: {cmd}")
                cursor.execute(cmd)
            
            conn.commit()
            conn.close()
            
            print("✓ FTS5 indexes rebuilt successfully")
            self.results["FTS5_Update"]["status"] = "success"
            
        except Exception as e:
            print(f"✗ FTS5 update failed: {e}")
            self.results["FTS5_Update"]["status"] = "failed"
            self.results["FTS5_Update"]["errors"].append(str(e))
    
    def update_embeddings(self):
        """Update vector embeddings for semantic search"""
        print("\n🧠 UPDATING VECTOR EMBEDDINGS")
        
        result = self.run_command(
            ["swift", "run", "orchestrator_cli", "ingest", "--sources", "Embeddings"],
            "Vector embeddings update",
            cwd=self.mac_tools_dir,
            timeout=600  # Embeddings can take longer
        )
        
        if result["success"]:
            self.results["Embeddings"]["status"] = "success"
        else:
            # Embeddings failure is not critical - mark as warning
            print("⚠️  Embeddings update failed - search will use FTS5 fallback")
            self.results["Embeddings"]["status"] = "warning"
            self.results["Embeddings"]["errors"].append("Embeddings service unavailable")
    
    def print_summary(self):
        """Print comprehensive ingest summary"""
        end_time = datetime.now()
        duration = end_time - self.start_time
        
        print("\n" + "="*80)
        print("KENNY COMPREHENSIVE INGEST SUMMARY")
        print("="*80)
        print(f"Start time: {self.start_time.strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"End time: {end_time.strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"Duration: {duration.total_seconds():.1f} seconds")
        
        # Get final database counts
        db_counts = self.get_database_counts()
        if "total" in db_counts:
            print(f"\\nTotal documents in Kenny.db: {db_counts['total']:,}")
            print("\\nBy source:")
            for source, count in db_counts["by_source"].items():
                print(f"  {source}: {count:,}")
        
        print("\\nIngestion Results:")
        print("-" * 50)
        
        success_count = 0
        for source, result in self.results.items():
            status_icon = {
                "success": "✓",
                "failed": "✗", 
                "warning": "⚠️",
                "skipped": "⊝",
                "pending": "?",
                "bridge_active": "🟢",
                "bridge_stale": "🟡", 
                "bridge_inactive": "🔴"
            }.get(result["status"], "?")
            
            print(f"{status_icon} {source:15} - {result['status'].upper()}")
            if result["count"] > 0:
                print(f"    Records processed: {result['count']}")
                
            # Special handling for Database Backup status
            if source == "Database_Backup":
                if "backup_path" in result:
                    import os
                    backup_name = os.path.basename(result["backup_path"])
                    print(f"    Backup file: {backup_name}")
                    if "backup_size" in result:
                        print(f"    Backup size: {result['backup_size']}MB")
            
            # Special handling for WhatsApp Bridge status
            if source == "WhatsApp_Bridge" and "bridge_info" in result:
                bridge_info = result["bridge_info"]
                print(f"    Process running: {'Yes' if bridge_info['process_running'] else 'No'}")
                print(f"    Messages in bridge: {bridge_info['message_count']:,}")
                if bridge_info['last_message_time']:
                    print(f"    Last message: {bridge_info['last_message_time']}")
                print(f"    Recent activity: {'Yes' if bridge_info['recent_activity'] else 'No'}")
                
            if result["errors"]:
                for error in result["errors"][:2]:  # Show first 2 errors
                    print(f"    Error: {error}")
            
            if result["status"] == "success":
                success_count += 1
        
        print("\\n" + "="*80)
        print(f"RESULTS: {success_count}/{len(self.results)} sources successful")
        
        # Provide guidance for failed sources
        failed_sources = [k for k, v in self.results.items() if v["status"] == "failed"]
        if failed_sources:
            print("\\nACTIONS REQUIRED:")
            for source in failed_sources:
                if source == "WhatsApp_Bridge":
                    print("• WhatsApp Bridge: Set up WhatsApp MCP bridge for real-time sync")
                elif source == "Embeddings":
                    print("• Embeddings: Check Ollama/embedding service is running")
                else:
                    print(f"• {source}: Check system permissions and app access")
        
        print("\\nSINGLE-LINE COMMAND FOR FUTURE RUNS:")
        print("python3 tools/comprehensive_ingest.py")
        print("="*80)
    
    def run_comprehensive_ingest(self):
        """Run comprehensive ingestion from all sources"""
        print("🚀 KENNY COMPREHENSIVE INGEST STARTING")
        print(f"Target database: {self.kenny_db}")
        
        # Get initial counts
        initial_counts = self.get_database_counts()
        if "total" in initial_counts:
            print(f"Initial document count: {initial_counts['total']:,}")
        
        # Check WhatsApp bridge status before ingestion
        print("\n💚 CHECKING WHATSAPP BRIDGE STATUS")
        print("="*50)
        bridge_status = self.check_whatsapp_bridge_status()
        
        # Store bridge status in results for summary
        if bridge_status["status"] == "active":
            self.results["WhatsApp_Bridge"]["status"] = "bridge_active"
        elif bridge_status["status"] == "running_but_stale":
            self.results["WhatsApp_Bridge"]["status"] = "bridge_stale"  
        else:
            self.results["WhatsApp_Bridge"]["status"] = "bridge_inactive"
        
        self.results["WhatsApp_Bridge"]["bridge_info"] = {
            "process_running": bridge_status["process_running"],
            "message_count": bridge_status["message_count"],
            "last_message_time": bridge_status["last_message_time"],
            "recent_activity": bridge_status["recent_activity"]
        }
        
        # Create database backup before any modifications
        print("\n🔄 PRE-INGESTION SAFETY BACKUP")
        if not self.create_database_backup():
            return  # Abort if backup fails
        
        # Run all ingestion sources with graceful error handling
        self.ingest_calendar()
        self.ingest_mail() 
        self.ingest_messages()
        self.ingest_contacts()
        self.ingest_whatsapp_bridge()
        self.update_fts5()
        self.update_embeddings()
        
        # Print comprehensive summary
        self.print_summary()

def main():
    """Main execution"""
    orchestrator = KennyIngestOrchestrator()
    orchestrator.run_comprehensive_ingest()

if __name__ == "__main__":
    main()