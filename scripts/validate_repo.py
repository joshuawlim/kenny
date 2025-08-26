#!/usr/bin/env python3
"""
Kenny Repository Structure Validator
Ensures AI agents maintain proper directory structure and prevent duplicates
"""

import os
import sys
from pathlib import Path
import glob
import json
from datetime import datetime

class KennyRepoValidator:
    def __init__(self, repo_root=None):
        self.repo_root = Path(repo_root) if repo_root else Path.cwd()
        self.errors = []
        self.warnings = []
        
    def validate_database_structure(self):
        """Ensure single kenny.db in correct location"""
        print("🔍 Validating database structure...")
        
        # Find all kenny.db files (excluding backups)
        kenny_files = list(self.repo_root.glob("**/kenny.db"))
        kenny_files = [f for f in kenny_files if "backups" not in str(f) and ".git" not in str(f)]
        
        if len(kenny_files) == 0:
            self.warnings.append("No kenny.db found - use tools/db_restore.py if needed")
        elif len(kenny_files) > 1:
            self.errors.append(f"Multiple kenny.db files found: {[str(f) for f in kenny_files]}")
        else:
            correct_path = self.repo_root / "mac_tools" / "kenny.db"
            if kenny_files[0] != correct_path:
                self.errors.append(f"kenny.db in wrong location: {kenny_files[0]} (should be {correct_path})")
            else:
                print("✅ Database location correct")
                
        # Check for nested mac_tools (ignore build artifacts)
        nested = list(self.repo_root.glob("mac_tools/**/mac_tools"))
        # Filter out build directories and other legitimate nested directories
        nested = [n for n in nested if not any(part in str(n) for part in ['.build', 'Sources', '.dSYM', 'DWARF'])]
        if nested:
            self.errors.append(f"Nested mac_tools directories found: {nested}")
            
    def validate_directory_structure(self):
        """Ensure proper directory structure"""
        print("🔍 Validating directory structure...")
        
        required_dirs = ["mac_tools", "tools", "backups"]
        for dir_name in required_dirs:
            dir_path = self.repo_root / dir_name
            if not dir_path.exists():
                self.warnings.append(f"Missing directory: {dir_name}")
            else:
                print(f"✅ {dir_name}/ exists")
                
        # Check for common AI agent mistakes
        common_mistakes = [
            "kenny.db",  # In root
            "kenny_copy.db",
            "kenny_backup.db", 
            "temp_kenny.db",
            "kenny.db.bak"
        ]
        
        for mistake in common_mistakes:
            if (self.repo_root / mistake).exists():
                self.errors.append(f"Improper file found: {mistake}")
                
    def validate_policy_compliance(self):
        """Check DATABASE_POLICY.md compliance"""
        print("🔍 Validating policy compliance...")
        
        policy_file = self.repo_root / "DATABASE_POLICY.md"
        if not policy_file.exists():
            self.errors.append("DATABASE_POLICY.md missing")
            return
            
        policy_content = policy_file.read_text()
        required_phrases = [
            "mac_tools/kenny.db",
            "Single Source of Truth",
            "NO NEW KENNY DATABASES"
        ]
        
        for phrase in required_phrases:
            if phrase not in policy_content:
                self.warnings.append(f"Policy missing required phrase: {phrase}")
                
    def generate_report(self):
        """Generate validation report"""
        report = {
            "timestamp": datetime.now().isoformat(),
            "repo_root": str(self.repo_root),
            "status": "PASS" if not self.errors else "FAIL",
            "errors": self.errors,
            "warnings": self.warnings
        }
        
        # Save report
        report_file = self.repo_root / "logs" / "validation_report.json"
        report_file.parent.mkdir(exist_ok=True)
        with open(report_file, 'w') as f:
            json.dump(report, f, indent=2)
            
        return report
        
    def run_validation(self):
        """Run all validations"""
        print("🧹 Kenny Repository Structure Validation")
        print("=" * 50)
        
        self.validate_database_structure()
        self.validate_directory_structure() 
        self.validate_policy_compliance()
        
        report = self.generate_report()
        
        print("\n📊 VALIDATION SUMMARY")
        print("=" * 50)
        
        if self.errors:
            print("❌ ERRORS:")
            for error in self.errors:
                print(f"  - {error}")
                
        if self.warnings:
            print("⚠️  WARNINGS:")
            for warning in self.warnings:
                print(f"  - {warning}")
                
        if not self.errors and not self.warnings:
            print("✅ All validations passed!")
            
        print(f"\n📝 Report saved: logs/validation_report.json")
        
        return len(self.errors) == 0

if __name__ == "__main__":
    validator = KennyRepoValidator()
    success = validator.run_validation()
    sys.exit(0 if success else 1)