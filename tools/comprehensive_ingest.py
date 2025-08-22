#!/usr/bin/env python3
"""
Comprehensive Kenny Ingest System
Orchestrates ingestion from all major data sources with graceful error handling
"""

import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
import json
import sqlite3

class KennyIngestOrchestrator:
    """Comprehensive ingest orchestrator for all Kenny data sources"""
    
    def __init__(self):
        self.kenny_db = "/Users/joshwlim/Documents/Kenny/mac_tools/kenny.db"
        self.tools_dir = "/Users/joshwlim/Documents/Kenny/tools"
        self.mac_tools_dir = "/Users/joshwlim/Documents/Kenny/mac_tools"
        self.start_time = datetime.now()
        
        # Track results for all sources
        self.results = {
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
                "pending": "?"
            }.get(result["status"], "?")
            
            print(f"{status_icon} {source:15} - {result['status'].upper()}")
            if result["count"] > 0:
                print(f"    Records processed: {result['count']}")
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