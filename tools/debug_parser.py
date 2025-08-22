#!/usr/bin/env python3
"""Debug the WhatsApp parser"""

from pathlib import Path
from whatsapp_importer import WhatsAppParser

# Test with one file
test_file = "/Users/joshwlim/Documents/Kenny/raw/Whatsapp_TXT/_chat 10.txt"

parser = WhatsAppParser()

print(f"Testing file: {test_file}")
print("-" * 50)

# Read file
with open(test_file, 'r', encoding='utf-8') as f:
    lines = f.readlines()

print(f"File has {len(lines)} lines")
print(f"First 5 lines:")
for i, line in enumerate(lines[:5], 1):
    print(f"  Line {i}: {repr(line[:80])}")

print("\nParsing lines:")
print("-" * 50)

messages = []
for i, line in enumerate(lines[:10], 1):
    parsed = parser.parse_line(line, i, test_file)
    if parsed:
        print(f"Line {i}: PARSED - {parsed.sender}: {parsed.content[:50]}...")
        messages.append(parsed)
    else:
        print(f"Line {i}: NOT PARSED - {repr(line[:50])}")

print(f"\nTotal messages parsed from first 10 lines: {len(messages)}")