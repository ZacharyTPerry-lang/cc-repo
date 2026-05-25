#!/usr/bin/env python3
"""
gen_file_list.py
Generates file_list.json listing all tracked lua files.
Called automatically by the pre-commit hook.
"""

import json
import subprocess
import os

EXCLUDE = {"bootstrap.lua"}

# Ask git for the tracked file list -- no filesystem guessing
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

with open("file_list.json", "w") as out:
    json.dump({"files": files}, out, indent=2)

print(f"file_list.json updated: {len(files)} file(s)")
