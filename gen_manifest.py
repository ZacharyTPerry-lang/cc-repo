#!/usr/bin/env python3
"""
gen_manifest.py
Generates manifest.json listing all .lua files and their hashes.
Run from the repo root. Called automatically by the pre-commit hook.
"""

import json
import os
import hashlib

EXCLUDE = {"bootstrap.lua"}  # bootstrap is one-time, not managed by updater

def fnv1a(data: bytes) -> str:
    h = 2166136261
    for b in data:
        h ^= b
        h = (h * 16777619) & 0xFFFFFFFF
    return f"{h:08x}"

files = []
for root, dirs, filenames in os.walk("."):
    # Skip hidden dirs like .git
    dirs[:] = [d for d in dirs if not d.startswith(".")]
    for fname in filenames:
        if not fname.endswith(".lua"):
            continue
        path = os.path.join(root, fname).lstrip("./").replace("\\", "/")
        if path in EXCLUDE:
            continue
        with open(os.path.join(root, fname), "rb") as f:
            data = f.read()
        files.append({"path": path, "hash": fnv1a(data)})

files.sort(key=lambda x: x["path"])
manifest = {"files": files}

with open("manifest.json", "w") as f:
    json.dump(manifest, f, indent=2)

print(f"manifest.json updated: {len(files)} file(s)")
