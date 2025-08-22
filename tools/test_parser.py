#!/usr/bin/env python3
"""Test WhatsApp parser to debug parsing issues"""

import re
from datetime import datetime

# Test with actual line from file
test_lines = [
    "[7/9/2016, 7:06:22 pm] Caleb Anderson: ‎Messages and calls are end-to-end encrypted.",
    "[31/1/2017, 3:29:10 pm] Josh Lim: https://out.reddit.com/...",
    "[22/7/2020, 1:50:08 am] Asher Min Hu Ngoi: ‎Messages and calls are end-to-end encrypted.",
    "[14/10/2016, 9:13:53 am] Courtney Elyse Lim: ‎Courtney Elyse Lim created this group"
]

# Original pattern
MESSAGE_PATTERN = r'^\[(\d{1,2}/\d{1,2}/\d{4}), (\d{1,2}:\d{2}:\d{2} [ap]m)\] ([^:]+): (.+)$'
message_regex = re.compile(MESSAGE_PATTERN)

print("Testing message pattern matching:")
print("-" * 50)

for line in test_lines:
    match = message_regex.match(line)
    if match:
        date_str, time_str, sender, content = match.groups()
        print(f"✓ MATCHED: {line[:50]}...")
        print(f"  Date: {date_str}, Time: {time_str}, Sender: {sender}")
        
        # Try parsing timestamp
        datetime_str = f"{date_str} {time_str}"
        try:
            # The issue is that strptime expects consistent formatting
            # We need to handle both single and double digit days/months
            dt = datetime.strptime(datetime_str, "%d/%m/%Y %I:%M:%S %p")
            print(f"  Timestamp: {int(dt.timestamp())}")
        except ValueError as e:
            print(f"  ERROR parsing timestamp: {e}")
    else:
        print(f"✗ NO MATCH: {line[:50]}...")

print("\nTesting timestamp parsing:")
print("-" * 50)

test_timestamps = [
    ("7/9/2016", "7:06:22 pm"),
    ("31/1/2017", "3:29:10 pm"),
    ("22/7/2020", "1:50:08 am"),
    ("14/10/2016", "9:13:53 am")
]

for date_str, time_str in test_timestamps:
    datetime_str = f"{date_str} {time_str}"
    print(f"Parsing: {datetime_str}")
    
    # The strptime format %d expects zero-padded day, but we have single digit
    # Use %-d on Unix/Mac or handle it differently
    try:
        # This should work on Mac/Unix
        dt = datetime.strptime(datetime_str, "%-d/%-m/%Y %-I:%M:%S %p")
        print(f"  Success with %-d/%-m: {int(dt.timestamp())}")
    except:
        try:
            # Fallback that works everywhere - manually pad the date
            parts = date_str.split('/')
            day = parts[0].zfill(2)
            month = parts[1].zfill(2)
            year = parts[2]
            
            time_parts = time_str.split(':')
            hour = time_parts[0].zfill(2)
            rest = ':'.join(time_parts[1:])
            
            padded_datetime = f"{day}/{month}/{year} {hour}:{rest}"
            dt = datetime.strptime(padded_datetime, "%d/%m/%Y %I:%M:%S %p")
            print(f"  Success with padding: {int(dt.timestamp())}")
        except Exception as e:
            print(f"  Failed: {e}")