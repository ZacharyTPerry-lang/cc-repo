#!/usr/bin/env python3
"""
gen_file_list.py
Generates file_list.json from all tracked lua files.
Run manually before committing when lua files are added or removed:
    python3 gen_file_list.py
"""

import json
import subprocess

EXCLUDE = {"bootstrap.lua", "CC_NETWORK_DESIGN.md"}

result = subprocess.run(
    ["git", "ls-files"],
    capture_output=True,
    text=True
)

all_tracked_files = result.stdout.strip().splitlines()

files = [
    f for f in all_tracked_files
    if f.endswith(".lua") and f not in EXCLUDE
]

files.sort()

with open("file_list.json", "w") as output_file:
    json.dump({"files": files}, output_file, indent=2)

print(f"file_list.json updated: {len(files)} file(s)")
for f in files:
    print(f"  {f}")
