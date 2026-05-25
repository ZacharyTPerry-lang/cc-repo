#!/usr/bin/env python3
"""
gen_file_list.py
Generates file_list.json and deployed_sha.txt.
Called automatically by the pre-commit hook.
"""

import json
import subprocess

EXCLUDE = {"bootstrap.lua"}

# Get current commit SHA (this will be the SHA after commit via hook)
sha_result = subprocess.run(
    ["git", "write-tree"],
    capture_output=True, text=True
)
sha = sha_result.stdout.strip()

# Get tracked lua files
files_result = subprocess.run(
    ["git", "ls-files"],
    capture_output=True,
    text=True
)

all_tracked_files = files_result.stdout.strip().splitlines()

files = [
    f for f in all_tracked_files
    if f.endswith(".lua") and f not in EXCLUDE
]

files.sort()

with open("file_list.json", "w") as out:
    json.dump({"files": files}, out, indent=2)

with open("deployed_sha.txt", "w") as out:
    out.write(sha + "\n")

print(f"file_list.json updated: {len(files)} file(s)")
print(f"deployed_sha.txt: {sha[:7]}")
