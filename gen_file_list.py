#!/usr/bin/env python3
"""
gen_file_list.py
Generates file_index.json by reading branch declarations
from lua file headers and filtering against deploy_banlist.json.

Every lua file must declare its branches in its header.
Single line format:
    -- Branches : main, interactive_role_selector, node/test

Multi-line continuation format:
    -- Branches : main, interactive_role_selector,
    --            node/test

Continuation lines are any comment lines immediately following
the Branches declaration that contain no colon and are not
a new header field. All branches are collected across all
continuation lines and split on commas.

Files with no branch declaration are a hard error — deploy aborts.
Files listed in deploy_banlist.json are excluded regardless
of their branch declaration.

Run before committing when lua files are added or removed:
    python3 gen_file_list.py
"""

import json
import subprocess
import sys

BANLIST_PATH        = "deploy_banlist.json"
FILE_INDEX_PATH     = "file_index.json"
BRANCH_TAG          = "-- Branches :"
CONTINUATION_PREFIX = "--"

def load_banlist():
    with open(BANLIST_PATH, "r") as banlist_file:
        banlist_data = json.load(banlist_file)
    return set(banlist_data["banned"])

def get_current_branch():
    result = subprocess.run(
        ["git", "branch", "--show-current"],
        capture_output=True, text=True
    )
    return result.stdout.strip()

def get_tracked_lua_files():
    result = subprocess.run(
        ["git", "ls-files"],
        capture_output=True, text=True
    )
    return [
        file_path for file_path in result.stdout.strip().splitlines()
        if file_path.endswith(".lua")
    ]

def read_branch_declaration(file_path):
    """
    Reads the Branches declaration from a lua file header.
    Handles both single-line and multi-line continuation formats.
    Returns a list of branch names, or None if no declaration found.
    """
    try:
        with open(file_path, "r") as lua_file:
            lines             = lua_file.readlines()
            branch_lines      = []
            found_declaration = False

            for line in lines:
                stripped = line.strip()

                if stripped.startswith(BRANCH_TAG):
                    branch_content = stripped[len(BRANCH_TAG):].strip()
                    branch_lines.append(branch_content)
                    found_declaration = True
                    continue

                if found_declaration:
                    # Continuation line: starts with -- and contains
                    # no colon (colon would indicate a new header field)
                    if (stripped.startswith(CONTINUATION_PREFIX)
                            and ":" not in stripped):
                        continuation = stripped[len(CONTINUATION_PREFIX):].strip()
                        if continuation:
                            branch_lines.append(continuation)
                        continue
                    else:
                        # Hit a new field or non-comment line — stop
                        break

            if not found_declaration:
                return None

            combined_branch_string = " ".join(branch_lines)
            branches = [
                branch.strip().rstrip(",")
                for branch in combined_branch_string.split(",")
                if branch.strip().rstrip(",")
            ]
            return branches

    except Exception as read_error:
        print(f"ERROR: Could not read {file_path}: {read_error}")
        sys.exit(1)

def main():
    banlist        = load_banlist()
    current_branch = get_current_branch()
    lua_files      = get_tracked_lua_files()

    print(f"Current branch : {current_branch}")
    print(f"Tracked lua files found : {len(lua_files)}")
    print("")

    files_for_branch = []
    errors_found     = False

    for file_path in sorted(lua_files):
        if file_path in banlist:
            print(f"  BANNED  : {file_path}")
            continue

        declared_branches = read_branch_declaration(file_path)

        if declared_branches is None:
            print(f"  ERROR   : {file_path} has no branch declaration in header")
            errors_found = True
            continue

        if current_branch in declared_branches:
            print(f"  INCLUDE : {file_path}")
            print(f"            branches: {', '.join(declared_branches)}")
            files_for_branch.append(file_path)
        else:
            print(f"  SKIP    : {file_path}")
            print(f"            branches: {', '.join(declared_branches)}")

    print("")

    if errors_found:
        print("ABORTED: Fix missing branch declarations before continuing.")
        sys.exit(1)

    file_index = {"files": files_for_branch}
    with open(FILE_INDEX_PATH, "w") as index_file:
        json.dump(file_index, index_file, indent=2)

    print(f"file_index.json written: {len(files_for_branch)} file(s)"
          f" for branch '{current_branch}'")

if __name__ == "__main__":
    main()
