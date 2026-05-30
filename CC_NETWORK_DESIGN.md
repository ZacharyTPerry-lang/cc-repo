# ComputerCraft Distributed Control Network
## Design Document v3.0.0

**Project:** CC:Tweaked distributed control network for NuclearCraft Fork + AE2
**Repository:** https://github.com/ZacharyTPerry-lang/cc-repo
**Minecraft Version:** NeoForge 1.21.1
**CC:Tweaked Version:** Current, installed on shared server
**Document Version:** 3.0.0
**Status:** Foundation complete and tested. Network primitives unbuilt.

This document is a complete knowledge transfer artifact. It encodes not
only what was built and how it works, but why every decision was made,
what alternatives were considered and rejected, what failed during
development and why, what the developer taught through the course of
building this system, and what remains to be done. A reader who finishes
this document should be able to continue development without asking
clarifying questions. A reader who skims it will produce subtly wrong
results. Do not skim.

---

## Table of Contents

1.  Project Intent and Philosophy
2.  Hardware Constraints and Their Implications
3.  The CI/CD Pipeline
4.  Repository Architecture and Branch Strategy
5.  The File Declaration and Deployment System
6.  Node Provisioning System
7.  Network Topology
8.  The Display Fabric
9.  The Channel Bus and Process Model
10. Memory Management
11. The NuclearCraft Peripheral API
12. Third Party Code Assessment
13. Coding Conventions for Lua on CC
14. The branch_manager.py Toolkit
15. What the Developer Taught the System
16. Anti-Patterns Explicitly Rejected
17. Open Items and Build Order

---

## 1. Project Intent and Philosophy

The goal of this project is to build a distributed ComputerCraft network
that monitors and controls NuclearCraft fission reactors and Applied
Energistics 2 networks across a survival Minecraft server. The developer
writes Lua code on a Windows development machine using a standard
terminal environment — nvim, WSL Ubuntu — pushes to GitHub, and the
in-game computers synchronize automatically on reboot. No direct
interaction with in-game terminals is required during normal operation.

The server is shared and not owned by the developer. This is a binding
constraint that shapes every architectural decision. The developer cannot
ask the server administrator for block removal, world editing, JVM
restarts, or filesystem access. Every failure mode must be resolvable
from within the CC environment itself. The system must be self-healing
or recoverable without external intervention.

The developer has constructed a perimeter using world-digging machines.
Physical space for computer placement is not a constraint. The binding
constraints are the Lua heap size per computer, server RAM consumption
from active computers, and the absence of administrator access.

### 1.1 The Core Design Philosophy

The single most important principle that emerged during development and
that must be understood before any other: the developer is not the
system's protection mechanism. The system is.

This principle was stated explicitly by the developer during a session
where the conversation repeatedly produced instructions that relied on
the developer remembering the right sequence, the right branch, the
right file, the right confirmation. The developer's response was direct:
"I am not the thing that preserves state. The system should."

This means every guard, every check, every confirmation prompt, every
hard error exists because human memory is not a reliable invariant. The
system must enforce correctness automatically. The developer's job is to
write code and make architectural decisions. The system's job is to make
sure what gets deployed is coherent. These two jobs must not be
conflated.

The consequences of this principle are visible throughout the codebase:
- `gen_file_list.py` hard-errors on a missing branch declaration rather
  than silently skipping the file
- The deploy banlist prevents files from reaching CC computers
  regardless of what the developer does
- `propagate --all` requires typing `ALL BRANCHES` in full, not just `y`
- `wipe.lua` requires typing `WIPE` in full caps
- `configure_pc.lua` fetches the live role list from GitHub rather than
  trusting a hardcoded list that could drift
- The branch header system was invented specifically because the
  developer recognized that manually maintaining a deployment manifest
  was a human memory problem

### 1.2 The Finite Pattern Requirement

Every loop in every program must have a termination condition that is
guaranteed to be reached within a bounded number of iterations. No loop
may depend on an external condition — network response, peripheral
availability, user input — without a timeout that guarantees eventual
termination. Recursion is prohibited.

This is not a style preference. It is a hard requirement derived from
the operational context: CC computers have no external kill mechanism
accessible to the developer without server administrator access. A hung
loop cannot be interrupted remotely. `Ctrl+T` terminates a running
program from the local terminal, but the developer is not always at the
local terminal. A program that can hang indefinitely is a program that
can only be killed by physically breaking the computer block, which
requires administrator access the developer does not have.

Every blocking operation must have a timeout. Every `os.pullEvent` must
specify a maximum wait time. The SHUTDOWN signal must be checked between
every operation so that a process can be cleanly terminated even if it
is in the middle of a long task.

### 1.3 The Exit Path Requirement

Every interactive loop must have an explicit exit path that returns
control to the CC terminal. No program should be able to trap the
developer. This was stated by the developer as an absolute requirement
after reviewing `configure_pc.lua`: "all files need a way out so we do
not get stuck anywhere."

The convention is that `0` at any prompt exits to the terminal. This
applies to role selection, confirmation prompts, and any future
interactive program. The exit message must tell the developer how to
resume the operation if they change their mind.

This requirement exists for the same reason as the finite pattern
requirement: the developer may not be at the local terminal and cannot
remotely terminate a hung interactive program. Trapping the local
terminal is a recoverable failure only if someone is physically present.

### 1.4 Scope and Future Direction

The reactor controller and AE2 monitor are the first applications. The
underlying network primitives — the channel bus, the process registry,
the display fabric — are being designed to support dozens of independent
processes running simultaneously, each with its own display channel that
can be viewed from any monitor on the network. The system is a general
purpose distributed control fabric, not a reactor monitor. The reactor
is the first application that runs on top of it.

---

## 2. Hardware Constraints and Their Implications

Understanding the hardware constraints of CC:Tweaked computers is
essential to every design decision. These are hard ceilings enforced by
the mod itself, not soft limits that clever code can work around.

### 2.1 Memory — The Critical Constraint

Every CC:Tweaked computer has a Lua heap of 2MB. This is the total
memory available for all running code, all loaded tables, all string
data, and all coroutines on that computer. It is not per-process. It is
the total for everything running on that physical machine.

The critical insight that came up as a real question during development
and was answered definitively: comments cost zero RAM. A 500 byte file
header costs 500 bytes of disk space and zero bytes of runtime heap.
Comments are stripped by the Lua parser and never loaded into memory.
The 2MB limit is entirely about what code does at runtime — what tables
it creates, what strings it accumulates, what coroutines it spawns —
not about what the code says.

This means: write full headers on every file without hesitation. Write
verbose comments explaining every non-obvious decision. The only cost
is disk space, and disk is not the constraint.

The actual RAM risks are:
- Tables that grow without bound. A monitoring system that appends
  sensor readings to a table every tick will exhaust the heap within
  minutes. Every accumulating data structure must have a fixed maximum
  size with old entries pruned on insertion.
- Large string allocations. HTTP response bodies, serialized JSON
  payloads, and concatenated strings all consume heap.
- Deep call stacks. Lua uses heap for stack frames. Deep recursion
  exhausts the heap before it exhausts any explicit limit.

The design response to the 2MB constraint is that each computer holds
state only for its own process. No computer accumulates state on behalf
of other computers. The coordinator holds only a registry table, not
the state payloads of every process it manages. Display nodes hold only
the most recent state packet, not historical data.

### 2.2 Storage

CC:Tweaked computer storage is 1MB for regular computers and 2MB for
advanced computers. This is a filesystem limit — files written to the
CC computer's virtual filesystem. These files are stored as actual files
in a subdirectory of the Minecraft server's world folder, not in server
RAM. An idle computer with data on disk consumes zero server RAM.

This distinction is critical for the distributed database architecture.
A 1000-node database cluster stores data on disk across 1000 folders.
Total disk consumption could reach 2GB of server disk space. Total
server RAM consumption from idle database nodes is approximately zero.
When a query arrives, a node loads data from disk, responds, and
deallocates. The RAM cost is only the working set of the handful of
nodes actively processing queries at any moment.

The storage limit means deployed code must be lean. Each branch
contains only the files needed for its role. The branch architecture
described in Section 4 keeps each node's deployed footprint as small
as possible.

### 2.3 Network

CC:Tweaked supports wireless rednet and wired modems with networking
cable. Rednet messages can carry Lua tables as payloads, serialized
internally by CC:Tweaked. The practical message size limit for table
payloads is approximately 64KB per message. This is large enough for
most state packets but requires careful design for large payloads such
as AE2 inventory snapshots.

For very large payloads, chunking is required. The channel bus must
support fragmented message transmission — splitting a payload across
multiple messages with sequence numbers and reassembling on the
receiving end. This is built into the channel bus design from the
beginning, not added later.

### 2.4 Concurrency

CC:Tweaked computers are single-threaded. The `parallel.waitForAny`
and `parallel.waitForAll` API functions provide cooperative multitasking
through coroutines, but only one coroutine executes at a time. A
coroutine that blocks indefinitely will starve all other coroutines.

This reinforces the timeout requirement. Every blocking operation must
have a timeout. A process that blocks indefinitely waiting for a message
that never arrives freezes the entire computer.

### 2.5 The Terminal Width Constraint

The CC:Tweaked advanced computer terminal is 51 characters wide. This
is a hard physical constraint that overrides the 100-character line
width convention from the developer's C projects. Every comment border,
every print statement, every formatted output must fit within 51
characters or it will wrap and become unreadable. All visual conventions
in this project are derived with the 51-character constraint as a
primary design input, not an afterthought.

### 2.6 The Distributed Memory Model

Because each computer is limited to 2MB of RAM, the network as a whole
is a distributed memory system where each node contributes 2MB of
working memory. Ten computers running as a single logical cluster
provide 20MB of combined state capacity. This is only useful if work is
actually distributed — a single computer trying to hold 20MB of state
will crash. The architecture distributes work deliberately so that each
node's working set fits comfortably within its 2MB budget.

---

## 3. The CI/CD Pipeline

### 3.1 The Core Problem and Why GitHub

The developer writes code on a Windows machine. The execution environment
is a CC:Tweaked computer inside a Minecraft server the developer does
not control. There is no direct filesystem access to the server's CC
computer directories, no SSH, and no way to push files directly. The
only outbound communication channel available is the CC:Tweaked HTTP
API, which allows in-game computers to make outbound HTTP requests.

The solution is GitHub as the intermediary. The developer pushes code
to a public repository. CC computers fetch code from GitHub's raw
content delivery network on every reboot. GitHub is reachable from CC
computers (confirmed: `http.checkURL` returns `true nil` for both
`raw.githubusercontent.com` and `api.github.com`). GitHub serves files
reliably, provides version control, and is free.

### 3.2 Development Environment Details

The development machine runs Windows with WSL Ubuntu. All git operations
are performed from WSL, not from PowerShell. The SSH key for GitHub
authentication is stored in the WSL environment. The GitHub account that
owns the repository is `ZacharyTPerry-lang`. Authentication uses SSH
with the remote URL configured as:

```
git@github.com:ZacharyTPerry-lang/cc-repo.git
```

Password authentication to GitHub is not supported for git operations
and will fail. This was discovered during development when pushing with
HTTPS credentials was rejected.

A second GitHub account (`zacperry1999`) exists and was initially
authenticated. This caused push failures because that account did not
have write access to the repository owned by `ZacharyTPerry-lang`. The
fix was setting the remote URL explicitly to use the correct account.

### 3.3 The Deployment Workflow

After many iterations and several serious failures, the final deployment
workflow is three commands with no automation, no hooks, and no moving
parts that can fail silently:

```bash
python3 gen_file_list.py   # run only when lua files are added or removed
git add .
git commit -m "descriptive message"
git push
```

`gen_file_list.py` reads branch declarations from Lua file headers and
generates `file_index.json` for the current branch. It must be run
after new files are added to git tracking but before committing, because
it uses `git ls-files` which only sees tracked files. If no Lua files
were added or removed, `gen_file_list.py` does not need to be run.

There are no git hooks. This is an explicit design decision made after
two serious failures with hook-based automation. The full failure history
is documented in Section 3.7.

### 3.4 The Sync Mechanism

On every boot, `startup.lua` performs the following sequence:

First, it reads `role.cfg` to determine which branch this computer is
assigned to. If `role.cfg` does not exist, the computer is not yet
provisioned. It fetches `configure_pc.lua` from the
`interactive_role_selector` branch and runs it to assign a role.

Second, it fetches the latest commit SHA from the GitHub API:
```
https://api.github.com/repos/ZacharyTPerry-lang/cc-repo/commits/<branch>
```
The branch in this URL is the configured branch from `role.cfg`, not
always `main`. Each computer checks the SHA of its own assigned branch.

Third, it reads the locally stored file `.deployed_sha`. If this file
does not exist, the computer treats itself as needing a full update.

Fourth, it compares the remote SHA to the local SHA. If they match, the
computer is up to date. If they differ, it fetches `deploy_banlist.json`
and `file_index.json` from the configured branch, then fetches each
file listed in `file_index.json` that is not banned.

Fifth, after all files are written, it writes the new SHA to
`.deployed_sha`. The computer is now at that commit on that branch.

Sixth, it determines whether to reboot. If any file other than
`startup.lua` itself was updated, it reboots. If only `startup.lua` was
updated, it does not reboot — the update takes effect on the next
natural reboot. This rule exists to prevent infinite reboot loops.

### 3.5 Why SHA-Based Sync, Not File Hash Comparison

The first sync mechanism used FNV-1a hashes of file contents to detect
changes. This failed catastrophically and repeatedly due to line ending
differences. Windows Git converts line endings from LF to CRLF on
checkout by default. The hash of a file with CRLF endings differs from
the hash of the same file with LF endings. The manifest was generated on
Windows with CRLF files. CC received the files and hashed them. The
hashes always differed. The computer rebooted every boot. This was the
first infinite reboot loop.

SHA-based sync compares commit SHAs, not file content hashes. A commit
SHA is a property of the git history, not of any individual file's byte
content. It is immune to line ending differences, encoding differences,
and any other byte-level variation that does not change the logical
content of the commit. The developer and the CC computer will always
agree on what the current commit SHA is because they are both asking
GitHub, which is the authoritative source.

### 3.6 The Bootstrap Process

A freshly provisioned CC computer has nothing on it. The bootstrap
process is a single line pasted into the CC terminal:

```lua
local r=http.get("https://raw.githubusercontent.com/ZacharyTPerry-lang/cc-repo/main/bootstrap.lua") local f=fs.open("bootstrap.lua","w") f.write(r.readAll()) f.close() r.close() shell.run("bootstrap.lua")
```

`bootstrap.lua` fetches `startup.lua` from the main branch, writes it
to disk, and reboots. On the next boot, `startup.lua` detects that no
`role.cfg` exists, fetches `configure_pc.lua` from the
`interactive_role_selector` branch, and runs the role selection
sequence. After role selection, every subsequent reboot is fully
automatic.

This bootstrap one-liner should be memorized or kept accessible. It is
the factory reset for any CC computer in this network.

### 3.7 Complete Failure History

Every failure mode encountered during development is documented here.
These failures shaped the final design. Understanding them is required
to understand why the system is built the way it is.

**Failure 1: The CRLF infinite reboot loop.**
The file hash sync mechanism hashed file contents on the development
machine and stored those hashes in a manifest. CC computers downloaded
files and computed their own hashes to compare. Windows Git's line
ending conversion caused every file's hash to differ between the
manifest and the CC-computed version. The computer detected changes on
every boot, pulled files, wrote them with CRLF endings, hashed them,
still got a different hash from the manifest, and rebooted again. This
was a permanent infinite loop. Resolution: abandon file hashing entirely
and use commit SHA comparison, which is encoding-immune.

**Failure 2: The GitHub API 404.**
An early version of the SHA check attempted to reach `api.github.com`
and received a 404. The URL was malformed. The correct endpoint is
exactly:
```
https://api.github.com/repos/{owner}/{repo}/commits/{branch}
```
Any deviation from this format returns a 404. The URL format must be
exact.

**Failure 3: The infinite post-commit hook recursion.**
A post-commit git hook was introduced to write the current commit SHA
to `deployed_sha.txt` after each commit. The hook used
`git commit --no-verify` to commit the updated SHA file. The assumption
was that `--no-verify` would prevent the hook from re-firing.
This assumption was wrong. `--no-verify` skips pre-commit hooks, not
post-commit hooks. The post-commit hook fired after every commit
including the commits it made itself. Within seconds, hundreds of
commits were made. The terminal had to be killed with `Ctrl+C`. The
repository accumulated hundreds of identical commits that had to be
cleaned up.

Resolution: remove all git hooks permanently. No hooks exist in this
project. The lesson is absolute: hooks that call git commands will
always risk recursive firing because git does not distinguish between
user-initiated and hook-initiated commits in its hook dispatch logic.
`--no-verify` is not a reliable recursion guard.

**Failure 4: Zone.Identifier contamination.**
Files downloaded through Windows Explorer acquire Zone.Identifier
metadata files — for example, `startup.lua:Zone.Identifier`. When
`git add .` was run, these metadata files were added to the repository
as tracked files. They appeared in git history and caused confusion.

Resolution: add `*:Zone.Identifier` to `.gitignore`. More importantly,
perform all file operations from WSL rather than through Windows
Explorer. WSL does not create Zone.Identifier files. This failure
established the rule that file placement into the repository must always
be done via nvim or WSL command line, never via Windows GUI tools.

**Failure 5: The gen_file_list.py ordering problem.**
`gen_file_list.py` uses `git ls-files` to enumerate tracked files. If
run before new files are staged with `git add`, the new files are
invisible to `git ls-files` and are omitted from `file_index.json`. A
deployment with a stale `file_index.json` silently omits files from
the CC computer.

Resolution: the correct order is always: add files to tracking with
`git add`, run `gen_file_list.py`, then commit. This order is now
documented in the deployment workflow and enforced by the `deploy`
command when it is written.

**Failure 6: The startup.lua multi-branch declaration error.**
When the branch header system was introduced, `startup.lua` was given
a header declaring `Branches : main`. This was incorrect —
`startup.lua` must be deployed to every branch because every CC
computer needs it to boot. The `gen_file_list.py` tool correctly
enforced the declaration: it skipped `startup.lua` on
`interactive_role_selector` and `node/test` because those branches
were not listed. The CC computers on those branches would never receive
updates to `startup.lua`.

This failure was caught before any CC computer was affected because
the `gen_file_list.py` output was verified before committing. The
developer noted: "I was going to see if you took it through the entire
repo. This is why we invented this system — glad to see it's working."

Resolution: change `startup.lua`'s declaration to:
```lua
-- Branches : main, interactive_role_selector,
--            node/test
```
And update `gen_file_list.py` to handle multi-line continuation
declarations. The parser now collects all continuation lines following
a `Branches :` declaration until it encounters a line with a colon
(indicating a new header field) or a non-comment line.

### 3.8 Recovery Procedures

**Soft recovery** — the computer has a bad sync state but `startup.lua`
is functional:
```lua
fs.delete(".deployed_sha")
reboot
```
Deleting `.deployed_sha` forces a full re-sync on next boot.

**Hard recovery** — `startup.lua` itself is broken or the computer is
in an unrecoverable state:
```lua
fs.delete("startup.lua")
fs.delete(".deployed_sha")
```
Then paste the bootstrap one-liner. This pulls a fresh `startup.lua`
from `main` and begins the provisioning flow.

**Full wipe** — all files must be cleared:
```lua
for _, file in ipairs(fs.list("/")) do
    if file ~= "rom" then fs.delete(file) end
end
```
The `rom` directory must never be deleted. It contains the CC:Tweaked
operating system. All other directories and files in root are user
space. After wiping, paste the bootstrap one-liner.

The `wipe.lua` utility on the `interactive_role_selector` branch
automates the full wipe with a confirmation guard. It can be fetched
directly without bootstrapping:
```lua
local r=http.get("https://raw.githubusercontent.com/ZacharyTPerry-lang/cc-repo/interactive_role_selector/wipe.lua")
local f=fs.open("wipe.lua","w") f.write(r.readAll()) f.close() r.close()
shell.run("wipe.lua")
```

---

## 4. Repository Architecture and Branch Strategy

### 4.1 Why Branches, Not Repositories

The naive approach to a multi-role CC network is a single monolithic
repository where every computer pulls the same codebase. This fails for
two reasons. First, the total codebase will eventually exceed 2MB, at
which point no single computer can hold all of it. Second, a computer
pulling files it does not need wastes both storage and HTTP requests.

Multiple repositories were considered and rejected. The overhead of
maintaining authentication, bootstrap URLs, and sync logic for multiple
repositories is significantly higher than managing branches within one
repository. Branches within a single repository share git infrastructure,
can be created and deleted with simple tooling, and are navigated with
the `branch_manager.py` utility described in Section 14.

The correct approach is git branches as deployment targets. Each branch
contains only the files needed for a specific role. A branch approaching
2MB in total deployed file size must be split immediately. This is a
hard rule, not a guideline. No branch has approached this limit in
current development — deployed code sizes are measured in kilobytes.

### 4.2 Branch Naming Convention

Branches follow a hierarchical prefix convention:

`main` — the coordinator, channel bus, and core network primitives.
The stable deployed branch for the coordinator computer.

`interactive_role_selector` — the emergency toolkit and provisioning
branch. Contains `configure_pc.lua`, `wipe.lua`, and `startup.lua`.
This branch is pulled on first boot to assign a role. It is also the
source for emergency recovery tools.

`node/<role>` — worker node branches. Each contains only the code for
that specific role. Examples: `node/reactor_control`, `node/ae2_monitor`,
`node/display`, `node/db`, `node/test`.

`cluster/<role>` — cluster head branches. Manage a wired cluster of
worker nodes. Examples: `cluster/reactor`, `cluster/ae2`.

### 4.3 The Role Tag System

To make `configure_pc.lua` self-maintaining — to ensure that adding a
new role does not require editing any existing file — valid deployment
branches are identified by git tags with the prefix `role/`.

A branch is tagged as a valid role with:
```bash
python3 branch_manager.py tag node/reactor_control
```

This creates and pushes the tag `role/node/reactor_control`. On first
boot, `configure_pc.lua` fetches the tag list from the GitHub API,
filters for tags starting with `role/`, strips the prefix, and presents
the resulting branch names as selectable roles. Adding a new role
requires only creating the branch and tagging it. No file edits are
needed.

Currently tagged roles: `interactive_role_selector`, `node/test`.

### 4.4 Current Branch State

As of the last verified audit:

`main` — tracks `bootstrap.lua` (banned), `startup.lua`. Deploys
`startup.lua` only. Last commit: `8a80fe7`.

`interactive_role_selector` — tracks `bootstrap.lua` (banned),
`configure_pc.lua`, `startup.lua`, `wipe.lua`. Deploys
`configure_pc.lua`, `startup.lua`, `wipe.lua`.

`node/test` — tracks `bootstrap.lua` (banned), `startup.lua`,
`test_role_hello.lua`. Deploys `startup.lua`, `test_role_hello.lua`.

All three branches also track `deploy_banlist.json`, `universal_files.json`,
and `gen_file_list.py` as universal files. These are not Lua files and
are not listed in `file_index.json` — they live on every branch for
local tooling use but are never deployed to CC computers.

---

## 5. The File Declaration and Deployment System

This section describes the system that replaced the original
`file_list.json` manifest. The replacement was designed after the
developer identified that the original system was "too fragile" and
that "the plan is way more than the done section" — meaning the system
needed to scale to dozens of branches without becoming a maintenance
burden.

### 5.1 The Problem With the Original System

The original `file_list.json` was a simple JSON array of file paths
maintained manually. It had two jobs: define what gets deployed to CC
computers, and serve as the sync payload for `startup.lua`. Conflating
these two jobs created fragility. The file could drift from reality.
There was no enforcement mechanism — a file could be tracked by git but
omitted from `file_list.json`, and it would silently never be deployed.
There was no way to know if the list was correct without manually
comparing it to `git ls-files`.

The developer identified the core insight: "I am not the thing that
preserves state. The system should." The manifest needed to be
self-verifying.

### 5.2 The Whitelist: File Header Declarations

Every Lua file in this project declares its branch membership in a
structured header comment. The declaration line follows the format:

```lua
-- Branches : main
-- Branches : node/reactor_control, node/test
-- Branches : main, interactive_role_selector,
--            node/test
-- Branches : all
```

The `Branches :` tag is the parser trigger. Everything following the
colon on that line and on immediately following comment lines that
contain no colon is collected and split on commas to produce the list
of branches where this file should be deployed.

The special value `all` means the file is deployed to every branch
without exception.

A Lua file with no `Branches :` declaration in its header is a hard
error. `gen_file_list.py` aborts with an error message naming the
offending file. Deployment cannot proceed until every Lua file has a
valid declaration. This is Law, not Convention. It cannot be bypassed.

### 5.3 The Blacklist: deploy_banlist.json

`deploy_banlist.json` lists files that must never reach a CC computer
regardless of any other declaration. It overrides the whitelist. A file
listed in the banlist is excluded from `file_index.json` even if its
header says `Branches : all`.

The banlist is intentionally small and stable. It changes rarely and
only when a new file category is introduced that should never be
deployed. Current contents:

```json
{
  "banned": [
    "bootstrap.lua",
    "CC_NETWORK_DESIGN.md",
    "deploy_banlist.json",
    "gen_file_list.py",
    "branch_manager.py",
    "LICENSE",
    ".gitignore"
  ]
}
```

`bootstrap.lua` is banned because it is a one-time paste utility, not
a deployed program. `CC_NETWORK_DESIGN.md` is banned because it is
documentation. `deploy_banlist.json` and `gen_file_list.py` are banned
because they are tooling that belongs on the developer's machine, not
on CC computers. `branch_manager.py` is untracked and never enters git.

### 5.4 The Deployment Artifact: file_index.json

`file_index.json` is generated by `gen_file_list.py` and consumed by
`startup.lua` on CC computers. It is the list of files that should be
fetched and deployed to this computer on this branch.

`file_index.json` is derived automatically from the declarations in Lua
file headers filtered through the banlist. It is never manually edited.
If the file index is wrong, the fix is to correct the header declaration
of the offending file and regenerate.

### 5.5 Universal Files: universal_files.json

`universal_files.json` lists files that are eligible for the
`propagate --all` command. Only files listed here may be universally
propagated. This guard prevents accidentally propagating a
branch-specific file to every branch via `--all`.

The universal files are:
- `deploy_banlist.json` — every branch must know what is banned
- `universal_files.json` — every branch must know what is universal
- `gen_file_list.py` — every branch needs to generate its own index

These three files are non-Lua and therefore not processed by the header
declaration system. Their universal status is declared by their presence
in `universal_files.json`. They are propagated to all branches using
the `propagate --all` command.

### 5.6 How gen_file_list.py Works

`gen_file_list.py` performs the following steps:

1. Load `deploy_banlist.json` into a set for O(1) lookup.
2. Get the current branch using `git branch --show-current`.
3. Get all tracked files using `git ls-files`, filter to `.lua` files.
4. For each Lua file:
   a. If it is in the banlist, mark it BANNED and skip.
   b. Read its header and parse the `Branches :` declaration.
   c. If no declaration is found, mark it ERROR and set error flag.
   d. If `all` is in the declared branches, mark it UNIVERSAL and
      include it.
   e. If the current branch is in the declared branches, mark it
      INCLUDE and add it to the deployment list.
   f. Otherwise, mark it SKIP.
5. If any errors were found, abort without writing `file_index.json`.
6. Write `file_index.json` with the deployment list.

The output to stdout shows the disposition of every file — BANNED,
UNIVERSAL, INCLUDE, SKIP, or ERROR — so the developer can verify that
every file was handled correctly before committing.

### 5.7 The Continuation Line Parser

The header declaration parser reads the `Branches :` line and then
continues reading subsequent comment lines as long as they:
- Start with `--` (are comment lines)
- Contain no `:` (a colon would indicate a new header field)

This allows multi-line branch declarations for files that belong to many
branches without exceeding the 51-character terminal width constraint.
The collected lines are joined, split on commas, and trimmed. Trailing
commas on continuation lines are handled correctly.

---

## 6. Node Provisioning System

### 6.1 Design Goals

The provisioning system must satisfy three requirements. First, it must
be operable entirely from within the CC terminal — no external tools,
no file transfers, no commands from outside the game. Second, it must
be self-documenting — the developer should not need to remember role
names or branch names. Third, it must produce a computer that will
correctly self-maintain on every subsequent reboot without further
manual intervention.

### 6.2 The First Boot Detection

`startup.lua` checks for the existence of `role.cfg` on every boot. If
the file does not exist, the computer is not yet provisioned. Rather
than failing or prompting the developer to paste a command, it
automatically fetches `configure_pc.lua` from the
`interactive_role_selector` branch and runs it. This means a computer
that has only been bootstrapped — that has `startup.lua` but no
`role.cfg` — will enter the role selection flow automatically on its
first boot after bootstrapping.

### 6.3 The Role Selection Flow

`configure_pc.lua` runs on first boot. It connects to the GitHub API
and fetches the list of all tags matching `role/*`. It strips the
`role/` prefix from each tag to get the branch name and presents the
resulting list as a numbered menu. The developer selects a role. A
confirmation prompt shows the selected role and branch and asks for
confirmation. After confirmation, `configure_pc.lua`:

1. Writes `branch=<selected_branch>` to `role.cfg`.
2. Deletes itself from the CC filesystem.
3. Reboots.

On the next boot, `startup.lua` finds `role.cfg`, reads the configured
branch, and performs the standard sync against that branch. The computer
is fully provisioned and self-maintaining.

The list of available roles is always current because it is fetched live
from GitHub. Adding a new role requires creating the branch and running
`python3 branch_manager.py tag <branch>`. No files need to be edited.

The developer tested this flow and it worked correctly on the first
attempt after the system was built.

### 6.4 The Exit Path

At every prompt in `configure_pc.lua`, entering `0` exits to the CC
terminal without making any changes. The exit message tells the
developer how to resume: `Run configure_pc.lua to reconfigure.` Since
`configure_pc.lua` deletes itself after successful completion, an
exited-but-not-completed flow leaves `configure_pc.lua` on disk and
the developer can re-run it by typing its name.

### 6.5 The wipe.lua Emergency Utility

`wipe.lua` lives on the `interactive_role_selector` branch. It is the
nuclear option — a full filesystem wipe for computers in states that
cannot be repaired by normal recovery. It exists because the developer
anticipated that some failure modes would produce states where even the
soft and hard recovery procedures would not work.

`wipe.lua` requires typing `WIPE` in full caps at the confirmation
prompt. This is stronger than a `y/N` prompt because the word `WIPE`
is semantically unambiguous — you cannot type it accidentally while
trying to type something else. After wiping, it prints the bootstrap
one-liner so the developer does not need to remember it.

`wipe.lua` never auto-reboots. After wiping, the computer sits at a
clean terminal prompt. The developer decides what to do next. This is
intentional — automatic reboot after a wipe would immediately trigger
a boot with no `startup.lua`, which would fail. The developer must
paste the bootstrap one-liner manually after wiping.

### 6.6 Recovery Without State

A key design principle: nearly every computer on this network holds no
state that needs to be recovered. Its role is in `role.cfg` and its
code comes from GitHub. If a computer needs to be fully reset, wipe it
and run the bootstrap one-liner. The provisioning flow handles the rest.
The only computers that require special recovery consideration are
database nodes, which hold data on their local filesystem that must
be treated as persistent.

---

## 7. Network Topology

### 7.1 Two Transport Layers

The network uses two physically distinct transport layers.

The wireless fabric uses CC:Tweaked wireless modems and the rednet API.
Wireless communication reaches any computer with a wireless modem within
range. The fabric is used for coordinator-to-node communication, channel
state broadcasts, and display subscription messages. Any computer
anywhere can participate by having a wireless modem.

The wired cluster network uses CC:Tweaked wired modems and networking
cable. Wired communication is restricted to computers physically
connected by cable. Clusters of worker nodes performing related tasks —
monitoring different components of the same reactor array — use wired
networks because they are easier to manage at high node density.

### 7.2 Node Roles

**Fabric coordinator** — the root of the process tree. Has a wireless
modem. Manages the channel registry, process lifetime, and shutdown
broadcast. Designated permanent infrastructure. Killing the coordinator
initiates graceful shutdown of all managed processes.

**Cluster I/O manager** — interface between a wired cluster and the
wireless fabric. Has both a wired modem and a wireless modem. Proxies
messages between worker nodes and the fabric. Each cluster has one.

**Worker nodes** — run a single process. Have a wired modem connecting
to the cluster I/O manager. Publish state on a named channel, receive
control commands through the cluster I/O manager.

**Display nodes** — attached to one or more CC monitors. Subscribe to
a named channel and render state payloads. No process logic of their
own — purely renderers. May have wireless (arbitrary location) or wired
(dedicated control room) modems.

### 7.3 The Coordinator as Root

The coordinator is the single point of authority for the entire network.
It maintains the authoritative list of all live channels, display
subscriptions, and process assignments. It is the only node that can
spawn and kill processes and reassign displays.

If the coordinator goes down, managed processes continue running but
become unmanageable. They cannot be killed, reassigned, or monitored
through the normal interface. They will run until their host computers
are rebooted or exhaust memory. This is an accepted failure mode. The
coordinator is permanent infrastructure and its loss is a significant
event requiring manual recovery.

Processes spawned directly from individual CC terminals (standalone
processes, not coordinator-managed) are unaffected by coordinator loss.

---

## 8. The Display Fabric

### 8.1 The Mental Model

The display fabric was designed around a specific mental model that the
developer articulated during the design session: switching inputs on a
monitor. When you switch a physical monitor's input, the monitor changes
what it displays. The signal sources themselves do not change. They
continue producing signal. The monitor simply stops showing one source
and starts showing another.

This mental model has a critical implication: you command the display,
not the producer. If you want to see the reactor status on the central
display, you send a command to the central display node telling it to
tune to the reactor channel. You do not send a command to the reactor
controller telling it to also send its data to the central display.
The reactor controller never knows or cares what is displaying its data.

This design decision means that the producer is stateless with respect
to its display assignment. It broadcasts on its channel continuously
regardless of who is listening. This makes the system significantly
simpler: adding or removing display nodes from a channel requires no
changes to the producing process.

### 8.2 The Core Contract

A process exists if and only if its channel is live.

Every process that runs on the network owns a named channel and
broadcasts its state to that channel on a fixed interval. A process
that has crashed, hung, or been killed stops broadcasting. The
coordinator detects channel silence via missed heartbeats and marks
the process as dead.

This contract has two consequences. First, there are no silent
background processes. If something is running, its channel is live.
Second, every running process is always observable from anywhere on
the network. Subscribing a monitor to any live channel requires no
changes to the producing process.

### 8.3 The Broadcast-Subscribe Model

Every producer broadcasts on its channel regardless of subscriber count.
Zero subscribers is valid. One hundred subscribers is valid. The
producer does not track subscribers.

Every display node subscribes to exactly one channel at a time. It
renders the state packets it receives. It can be reassigned to a
different channel by a coordinator command. Multiple display nodes
can subscribe to the same channel simultaneously.

The "cast to big screen" operation: the developer sends a watch command
to the central display node telling it to subscribe to the reactor
channel. The reactor controller does not change. The control room
display does not change. The central display begins receiving and
rendering the same state packets. When done, the central display is
reassigned to its previous channel.

### 8.4 The Invocation Model

Every process is invoked with a display assignment:
```
run reactor_control --display control_room
```

The display assignment is a runtime parameter, not hardwired. The same
process can be started with a different display. A running process can
have additional displays attached with `watch`:
```
watch reactor_control --display central_display
```

### 8.5 The Shutdown Protocol

Graceful shutdown is a first-class operation. The sequence:

1. Kill command reaches the coordinator.
2. Coordinator broadcasts SHUTDOWN on every live channel.
3. Every managed process receives SHUTDOWN, completes its current
   bounded operation, cleans up, and exits.
4. Every display node receives SHUTDOWN, clears its screen, goes idle.
5. Coordinator exits last.

SHUTDOWN is a reserved message type in the channel bus. It is checked
before any application logic. A process that receives SHUTDOWN must
exit within a bounded time. The finite pattern requirement guarantees
this — every operation is bounded, so SHUTDOWN is always reached within
a finite number of steps.

---

## 9. The Channel Bus and Process Model

### 9.1 Purpose and Status

`channel_bus.lua` is the lowest-level network primitive. Everything
in the network depends on it. It is not yet written. This section
describes what it must implement.

### 9.2 Required Functionality

Named channel semantics over computer ID and port addressing. A process
sends to a named channel, not to a computer ID. The bus resolves the
channel to the appropriate transport.

Transport abstraction. The same API covers both wireless rednet and
wired modems. Application code never calls `rednet.send` directly.

Message framing. Every message has a type field. The bus checks the
type before passing the message to application logic.

Reserved message types. SHUTDOWN and HEARTBEAT are handled by the bus
itself and never passed to application logic.

Heartbeat generation. Every process sends a HEARTBEAT message on a
fixed interval. The coordinator receives heartbeats and maintains
last-seen timestamps for every channel.

Fragmentation for large payloads. Payloads exceeding practical
single-message size are split into chunks with sequence numbers and
total count. The receiving end reassembles and delivers the complete
payload only when all chunks arrive.

### 9.3 The Heartbeat and Health Monitoring

Every process sends HEARTBEAT on its channel at a configured interval
regardless of whether its state has changed. The coordinator updates
the last-seen timestamp. If no heartbeat arrives within a configured
timeout, the coordinator begins a grace period. If no heartbeat arrives
within the grace period, the channel is marked dead, removed from the
registry, and subscribed display nodes are notified.

Health monitoring is passive. Processes that are running generate their
own evidence of health. Processes that have crashed stop generating
heartbeats and are detected automatically.

---

## 10. Memory Management

### 10.1 The Fundamental Rule

No data structure in any process may grow without bound. Every table
that accumulates data over time must have a maximum size enforced at
insertion time. When a new entry would exceed the maximum, the oldest
entry is removed before the new one is added. This is non-negotiable
and applies to every file in every branch.

### 10.2 The Comments-Cost-Zero-RAM Insight

This came up as an explicit question during development: given the 2MB
RAM limit, how many comments and headers are too many? The answer was
confirmed definitively: comments cost zero RAM. They are stripped by
the Lua parser and never loaded into the heap. The 2MB limit is about
runtime allocation, not source file size. Write full headers on every
file. Write verbose comments. The only cost is disk space, which is
not the binding constraint.

### 10.3 State Packet Design

State packets must be compact. Every field must be justified by a
downstream consumer. For a reactor state packet: heat stored, heat per
tick, cooling per tick, max heat capacity, energy stored, energy
capacity, energy per tick, reactivity level, active state. Everything
the display renderer needs to draw the display and everything the
safety logic needs to make control decisions. Nothing else.

### 10.4 The Registry Pruning Rule

The coordinator's channel registry must prune dead entries promptly.
The coordinator does not accumulate historical data about dead
processes. When a process dies and is restarted, it registers as a
new channel entry. There is no merger with the old entry.

### 10.5 Database Cluster Memory Model

Database cluster nodes hold data on their local filesystem and load
it into memory only to service a query. An idle node consumes no heap
beyond the minimal overhead of `startup.lua` waiting for a rednet
message. When a query arrives: load data from disk, process query,
send response, deallocate. Idle between queries. Total RAM cost is
determined by the maximum working set of a single query, not by the
total dataset size.

---

## 11. The NuclearCraft Peripheral API

### 11.1 Peripheral Registration

The NuclearCraft fission reactor exposes a CC:Tweaked peripheral through
`SolidFissionReactorPeripheral.java` at:
```
src/main/java/igentuman/nc/compat/cc/SolidFissionReactorPeripheral.java
```

This is the only file in the entire NuclearCraft fork that imports
CC:Tweaked APIs. The peripheral is registered under the type name
`nc_fission_reactor`. In Lua:
```lua
local reactor = peripheral.find("nc_fission_reactor")
```

### 11.2 Full API Reference

Three methods were added during this project and are not present in
the upstream igentuman NuclearCraft Neoteric repository: `isActive`,
`getEnergyCapacity`, and `getReactivityLevel`. The mod has been
rewritten to include these but has not yet been rebuilt and redeployed.
They must be compiled and the JAR redeployed before they are callable
from Lua.

**State query methods:**

`isFormed()` → boolean. Checks both `isCasingValid` and
`isInternalValid`. A reactor that is not formed will not process fuel.

`isActive()` → boolean. Reads `reactor.controllerEnabled`. This is the
computed active state: true only when formed, has a redstone signal,
and has not been force-shut down. This is the authoritative active
state. Do not derive active state from `getHeat() > 0` — that check
is unreliable because a reactor at zero heat production may still be
active during ramp-up.

`getName()` → string. The reactor's configured name.

`hasRecipe()` → boolean. Whether the current fuel has a valid recipe.

`isSteamMode()` → boolean. Whether the reactor outputs steam rather
than FE.

`getSteamRate()` → double. Current steam output rate.

`getDepletionProgress()` → int (0-100). Percentage of fuel consumed.

`getMaxHeatCapacity()` → double. Maximum heat before damage.

`getEnergyPerTick()` → int. FE generated per tick at current conditions.

`getEnergyStored()` → int. FE currently in the internal buffer.

`getEnergyCapacity()` → int. Maximum FE capacity. Reads
`energyStorage().getMaxEnergyStored()`. Fixed at 100,000,000 FE by
`createEnergy()` in `FissionControllerBE`. Buffer percentage is
computed in Lua as `getEnergyStored() / getEnergyCapacity() * 100`.

`getHeatMultiplier()` → double. Current heat multiplier.

`getModeratorsCount()` → int. Count of moderator blocks.

`getHeatSinksCount()` → int. Count of heat sink blocks.

`getFuelCellsCount()` → int. Count of fuel cell blocks.

`getCooling()` → int. Heat removed per tick by heat sinks.

`getHeat()` → int. Heat generated per tick by fuel. Zero when inactive.

`getHeatStored()` → int. Current stored heat.

`getReactivityLevel()` → int (0-100). Reads `reactor.reactivityLevel`.
Increments by 1 per tick when active, decrements by 1 per tick when
inactive, clamped to 0-100. Directly affects heat output and FE output.
Essential for detecting whether a recently enabled reactor has reached
steady state. A reactor at 50% reactivity produces approximately half
its steady-state output. Control decisions made during ramp-up or
ramp-down are unreliable without accounting for reactivity.

`getFuelInSlot()` → table. Describes the current fuel item.

**Control methods:**

`enableReactor()` — calls `reactor.disableForceShutdown()`. Clears the
force shutdown flag. The reactor will run if formed and has redstone.

`disableReactor()` — calls `reactor.forceShutdown()`. Sets force
shutdown. Reactor stops regardless of redstone state.

`setModerationLevel(int)` — calls `reactor.adjustModerationLevel(level)`.

`voidFuel()` — calls `reactor.voidFuel()`. Discards current fuel.

### 11.3 Derived Values Computed in Lua

All safety logic is computed in Lua, not Java. The peripheral exposes
raw values only.

Heat margin: `getCooling() - getHeat()`. Positive means cooling faster
than generating. Negative means accumulating heat.

Heat percentage: `getHeatStored() / getMaxHeatCapacity() * 100`.

Energy buffer percentage: `getEnergyStored() / getEnergyCapacity() * 100`.

Overheating: `getHeat() > getCooling()`. Heat is accumulating. Note
that this can be true even with stored heat below danger threshold.
Heat percentage and heat margin together determine safety state.

### 11.4 Java Source Locations

Peripheral implementation:
`src/main/java/igentuman/nc/compat/cc/SolidFissionReactorPeripheral.java`

Controller block entity (source of all peripheral data):
`src/main/java/igentuman/nc/block/fission/entity/FissionControllerBE.java`

Energy storage utility:
`src/main/java/igentuman/nc/util/capability/CustomEnergyStorage.java`

### 11.5 Rebuild Status

The three peripheral additions (`isActive`, `getEnergyCapacity`,
`getReactivityLevel`) are written in Java. The mod has not been rebuilt
since these additions. The JAR in the server's mods folder does not
include them. All three methods will return "no such method" errors from
Lua until the mod is rebuilt and the JAR redeployed. This is a blocking
dependency for all reactor control Lua code.

---

## 12. Third Party Code Assessment

### 12.1 touchpoint.lua

Source: Lyqyd (original), modified by DrunkenKas (Kasra Ghaffari)
Repository: https://github.com/Kasra-G/ReactorController
License: MIT
Status: Adopted as the button library for all display work.

`touchpoint.lua` is a click-map based button system for CC:Tweaked
monitors. It maintains a 2D array mapping monitor coordinates to button
names, handles `monitor_touch` events, and provides toggle, flash, and
rename operations. It is completely generic — no reactor logic, no
application-specific code, no dependencies beyond the CC:Tweaked
standard API. It is well-written, MIT licensed, and actively maintained.
There is no reason to write a replacement.

### 12.2 PID Controller Pattern

Source: Kasra Ghaffari (DrunkenKas)
Repository: https://github.com/Kasra-G/ReactorController
License: MIT
Status: Algorithm adopted, peripheral calls to be replaced.

`reactorController.lua` implements a dual-error weighted PID controller.
Two error signals: difference between actual and target RF/t output, and
difference between actual and target buffer fill level. These are
combined with dynamic weights — buffer error dominates when far from
target, output rate error dominates when close. This produces smoother
control than single-error PID.

PID parameters: Kp = -0.08, Ki = -0.0015, Kd = -0.01. Negative signs
reflect the inverse relationship between control rod insertion and
output.

For NuclearCraft: the same PID structure applies but the controlled
variable is moderation level via `setModerationLevel` rather than
control rod insertion, and the primary controlled quantity is heat
rather than RF buffer. Peripheral calls differ entirely but
`iteratePID` transfers directly.

### 12.3 Rejected Third Party Code

CastilloAnthony's Nuclearcraft-Reactor-UI-ControlPanel targets
OpenComputers on Minecraft 1.12.2. OpenComputers uses `component.proxy`
and `component.list`. These APIs are incompatible with CC:Tweaked. No
code is transferable.

ThePoleThatFishes' NC-feat-OC-scripts similarly targets OpenComputers.
The turbine calculator is pure math and is a usable reference for
turbine efficiency calculations but no direct code transfers.

---

## 13. Coding Conventions for Lua on CC

### 13.1 The Source of These Conventions

The developer has an existing C coding convention system documented in
three companion documents: `naming_and_code_form_conventions.md`,
`code_taste_and_functional_form.md`, and `visual_identity_theme.md`.
These documents were read in full during development. The Lua
conventions in this project are derived from those documents but
adapted for the CC:Tweaked environment.

The adaptation is not a simplification. It is a translation. Every rule
that transfers is transferred at full fidelity. Rules that cannot
transfer due to Lua's syntax or CC's physical constraints are replaced
with equivalent rules that achieve the same goals.

### 13.2 What Transfers Directly

**Verbosity is mandatory.** Abbreviations are prohibited. `error` not
`err`. `buffer` not `buf`. `response` not `res`. `configuration` not
`cfg`. `channel` not `ch`. `filesystem` not `fs`. The function name
`util` is prohibited — name what the utility does.

**Function names are verb phrases.** They describe the complete action:
what goes in, what comes out. `fetch_url` not `get`. `write_local_file`
not `write`. `read_branch_declaration` not `parse`.

**Variable names describe what is stored and in what form.** `remote_sha`
not `sha`. `deployed_sha_path` not `path`. `shutdown_requested` not
`running`.

**Whitespace is a structural signal, not padding.** A blank line means
something. No blank line is present for visual breathing room alone.

**Comments exist for non-obvious logic and contracts, not to narrate
code.** The names do the narration. Comments state why a non-obvious
choice was made, or state a contract the caller must understand.

**File names describe what the file contains.** `channel_bus.lua` not
`net.lua`. `deploy_banlist.json` not `blacklist.json`. The name is a
description that can be read as a sentence fragment.

### 13.3 What Does Not Transfer and Why

**The 100-character line width.** The CC:Tweaked advanced computer
terminal is 51 characters wide. A 100-character line wraps and becomes
unreadable. All code and comments in this project must fit within 51
characters. This is the primary adaptation — it affects every visual
convention.

**The `/* */` block comment syntax.** Lua uses `--` for single-line
comments and `--[[ ]]` for multi-line blocks, but multi-line Lua block
comments are not idiomatic in CC Lua. All comment blocks in this project
use `--` prefixed lines.

**The five-term parameter contract annotation.** Lua has no type system
to enforce against. The annotation `VALID CONSUME ALWAYS KEEP NONE`
carries no enforcement weight in Lua. The same information is captured
in the Operation block's IN section in plain language.

**The full TOC with line numbers.** The C convention includes a Table
of Contents with function names and line numbers inside the file header.
In a 60-150 line Lua file this is overhead. The TOC in Lua headers
lists section names and approximate line numbers but not individual
function entries.

### 13.4 The File Header Format

Every Lua file opens with a file header. This is Law, not Convention.
No Lua file may be committed to this repository without a header. The
header is the file's title page. It is the first thing read and the
document that orients the reader before any code is seen.

The header format:

```lua
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- filename.lua
-- Purpose statement. As many lines as needed
-- to fully describe what this file does,
-- what system it belongs to, what its
-- contracts and invariants are, and what
-- the reader must understand before reading
-- the code.
--
-- Branches : branch_name
-- Depends  : dependency list or none
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
--
-- [1] SECTION NAME        ln. XX
-- [2] SECTION NAME        ln. XX
--
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
```

The `%` border character was chosen following the same analysis as in
the C convention: it is visually unambiguous, appears in no other
context in Lua comments, and reads at scroll speed as "this is the
title page." The border fills to 45 characters to fit the terminal.

The `Branches :` field is not optional. It is parsed by `gen_file_list.py`
and is the mechanism by which the file declares where it belongs.

The `Depends :` field lists other files this file requires. `none` if
there are no dependencies.

The Table of Contents lists section names and approximate line numbers.
Line numbers are advisory — they do not need to be updated on every
edit. Their purpose is orientation.

### 13.5 Section Markers

Within a file, sections are marked with `=` borders matching the section
entries in the TOC:

```lua
-- ===========================================================================
-- [1] SECTION NAME
-- ===========================================================================
```

Sections carry a body when context is needed before entering the section.
When a section's purpose is obvious from its name, the body is omitted.

### 13.6 Authority Tiers

Following the C convention document, every rule in this coding system
carries one of three tiers:

**Law** — enforced by tooling or produces a hard error if violated.
The `Branches :` declaration in every Lua header is Law. The finite
pattern requirement is Law. The exit path requirement is Law.

**Convention** — followed by discipline. The verbosity rules, the
naming conventions, the section marker format are Convention.

**Guidance** — admits judgment. TOC line number accuracy is Guidance.

### 13.7 The Finite Pattern Rule as Law

No function in this codebase may call itself recursively. No loop may
have an unbounded termination condition. This is Law because the
consequence of violation is a hung computer that cannot be remotely
killed.

`configure_pc.lua` was initially written with a recursive cancel path:
cancelling a selection called `shell.run("configure_pc.lua")`. This was
noted as a concern and the developer approved it on the grounds that
human input is required at each iteration, making infinite recursion
impossible in practice. However, it was subsequently replaced with a
`while true` loop which achieves the same behavior without any
recursion. The loop pattern is always preferable to recursion in this
environment.

### 13.8 Error Handling

Every network operation returns either a value or nil plus an error
message. The caller must check for nil before using the value. Silent
failures — discarding the error and proceeding as if the operation
succeeded — are prohibited. Every error either terminates the current
operation with a logged message or triggers a retry with a bounded
retry count.

---

## 14. The branch_manager.py Toolkit

`branch_manager.py` is a local Python utility that is never committed
to the repository. It is listed in `.gitignore`. It provides all
branch management and repository inspection operations. It is the
primary interface between the developer and the git repository for
this project.

### 14.1 Design Philosophy

The toolkit was designed around the same principle as the rest of the
system: the developer should not need to remember commands, sequences,
or state. The tool provides what the developer needs in one command.
Every destructive operation requires explicit confirmation. The `audit`
and `state` commands replace manual for-loop sequences that the developer
had to run repeatedly.

Every command that modifies the repository shows what it will do before
doing it and requires confirmation. The `propagate --all` command
requires typing `ALL BRANCHES` in full — not `y`, not `yes`, the
exact string — because universal propagation is the highest-impact
operation available.

### 14.2 Command Reference

**`help`** — prints all available commands with one-line descriptions.
No arguments.

**`list`** — lists all local and remote branches. Marks the current
branch with `*`. No arguments.

**`show`** — prints the current branch name. No arguments.

**`create <branch>`** — creates a new branch locally and pushes to
remote. Prints a reminder to tag the branch if it is intended to be a
deployable role. One argument: branch name.

**`delete <branch>`** — deletes a branch locally and remotely. Requires
`y` confirmation. Also removes the role tag if present. Uses `-D`
(force delete) rather than `-d` because branches may not be fully
merged. One argument: branch name.

**`switch <branch>`** — checks out a branch. One argument: branch name.

**`tag <branch>`** — creates and pushes a `role/<branch>` git tag,
making the branch selectable in `configure_pc.lua`. Verifies the branch
exists remotely before tagging. One argument: branch name.

**`untag <branch>`** — removes the `role/<branch>` tag locally and
remotely. Requires `y` confirmation. One argument: branch name.

**`tags`** — lists all `role/*` tags and their corresponding branch
names. No arguments.

**`state`** — deep view of the current branch. Shows: last commit SHA
and message, whether the branch is role-tagged, working tree status
(uncommitted changes), unpushed commits, all tracked Lua files with
their disposition (BANNED, UNIVERSAL, DEPLOY, SKIP, NO HDR), and the
current contents of `file_index.json`. No arguments.

**`audit`** — full view of all remote branches. For each branch shows:
last commit SHA and message, whether the branch is role-tagged, all
tracked Lua files, and the contents of `file_index.json`. No arguments.
This command replaces the manual for-loop sequence that was run
repeatedly during development.

**`propagate <file> <branch> [<branch>...]`** — targeted propagation.
Copies the specified file from the current branch to one or more target
branches. For each target branch: checks out the branch, copies the
file using `git checkout <source_branch> -- <file>`, commits with the
message `propagate: <file> from <source_branch>`, pushes, returns to
source branch. Shows target list and requires `y` confirmation before
proceeding. Skips branches where the file is already up to date.

**`propagate <file> --all`** — universal propagation. Copies the file
to every remote branch. First verifies that the file is listed in
`universal_files.json` — if not, refuses with an error message
explaining the requirement. Shows the full list of target branches and
requires typing `ALL BRANCHES` exactly before proceeding. Uses the
same per-branch copy mechanism as targeted propagation.

### 14.3 Deferred Commands

The following commands were designed during development but deliberately
deferred. They are documented here so they are not forgotten and so
future development can implement them with full context.

**`sync`** — dry run diff. Shows what would change if `gen_file_list.py`
were run and the result committed. Never touches git. The developer
described this as safe because "a bad sync is a ruiner" — automatic
synchronization that commits without review is too dangerous. `sync`
is read-only.

**`deploy`** — guarded commit and push. Would run `gen_file_list.py`,
show the full diff of what will be committed including the updated
`file_index.json`, verify that the current branch is a known valid
branch, verify that no Lua files exist on disk without a branch
declaration, require explicit confirmation, then commit and push. The
developer noted that `deploy` needs a guard not just that the branch
is valid but that it is the intended branch — the system should enforce
correctness, not rely on the developer to verify. The implementation
approach is to show the branch name prominently and require the developer
to acknowledge it explicitly before proceeding.

---

## 15. What the Developer Taught the System

This section records the specific insights, corrections, and design
principles that the developer contributed during the course of building
this system. These are not elaborations of existing ideas — they are
inputs that changed the direction of development or established
constraints that would not have existed without explicit developer
direction.

### 15.1 The Developer Is Not the Protection Mechanism

This was stated in response to repeated instructions that relied on the
developer remembering sequences, branch names, and file relationships.
The developer said: "I am not the thing that preserves state. The system
should if that makes sense." This became the central principle of the
entire codebase. Every guard, every hard error, every confirmation
prompt exists because of this statement.

### 15.2 Finite Patterns Are Non-Negotiable

The developer identified recursion as uniquely dangerous in this
environment before the system was built. "I would stick to what I will
call finite patterns. This can cause huge issues." This established the
finite pattern requirement as Law before any code was written.

### 15.3 The Display Fabric Mental Model

The developer articulated the display fabric design in terms of
"switching inputs on a monitor" — the signal sources do not change,
only what the monitor shows. This mental model resolved the design
ambiguity about who receives commands when display assignment changes.
The answer is always the display node, never the producer.

### 15.4 The CC Computer Is Not the Dev Machine

During initial setup, instructions assumed the CC computer's filesystem
was accessible from the developer's machine. The developer corrected
this immediately: "Careful, you're assuming code PC is Minecraft PC.
Also, this is a server. There is nothing under saves for the client."
This correction established the correct architecture — GitHub as
intermediary, CC pulling rather than being pushed to.

### 15.5 The 2MB Is Not a Code Size Constraint

The developer asked explicitly whether the header format was "too much"
given the 2MB limit. The answer was that comments cost zero RAM.
The developer accepted this and it established the convention that
headers and comments should be written at full fidelity without concern
for size.

### 15.6 The Whitelist/Banlist Split

The developer proposed separating the deployment manifest into a
whitelist (file headers declaring where they belong) and a blacklist
(a small, stable list of files that must never reach CC). The developer
noted: "90% of the time files moving around is benign. We have a few
files that should never move around." This created the `Branches :`
header declaration system and `deploy_banlist.json`.

### 15.7 Branches as the Scope Boundary

The developer proposed using git branches rather than multiple
repositories for role isolation. When the branches-vs-repositories
question came up, the developer decided on branches because "everything
is branches and we can branch the branches themselves." The branch
naming hierarchy (`node/`, `cluster/`, etc.) followed from this.

### 15.8 The Universal Files Pattern

After the propagation command was designed, the developer asked whether
`gen_file_list.py` should also be propagated. The question revealed
that three files — `deploy_banlist.json`, `universal_files.json`, and
`gen_file_list.py` — should exist on every branch. This led to the
`universal_files.json` classification system and the `Branches : all`
header value. The developer confirmed these were the only three
universal files, reasoning through each one explicitly.

### 15.9 The System Caught Its Own Bug

The branch header system was invented to prevent deployment errors. On
its first real test — running `gen_file_list.py` on `interactive_role_selector`
after the header system was introduced — it correctly detected that
`startup.lua` had declared only `Branches : main` and skipped it on
the other branches. The developer said: "I was going to see if you took
it through the entire repo. This is why we invented this system — glad
to see it's working." This was a real bug that would have caused
`startup.lua` never to be updated on non-main branches. The system
caught it before any CC computer was affected.

### 15.10 Sprawl Control

The developer repeatedly redirected the conversation away from over-
scoped responses. "Your sprawl is really bad right now. Get concise
and ask all your questions now." "I already made the change — I assume
now we push?" "Yes but first we need to clone." This established the
working pattern: understand the problem, propose, get explicit approval,
execute. Do not expand scope without permission. Cache deferred items
rather than pursuing them immediately.

### 15.11 The Context Document Standard

The developer specified that the context document must be written without
compression, without simplification, and without reduction. "No
reductions unless it is removed from the current implementation.
Modifications only to give clarity and not to simplify/compress. Adding
everything you learn, why you learned it, and outputs/inputs/context.
Your doing this correct?" The document you are reading is the result
of that specification.

---

## 16. Anti-Patterns Explicitly Rejected

This section documents architectural approaches that were considered
and rejected, with the exact reasoning. Future development must not
reintroduce these patterns.

### 16.1 Git Hooks for Automation

Git hooks were introduced twice and caused catastrophic failures both
times. The first hook was a pre-commit hook running `gen_file_list.py`
and `git add`. This was safe on its own but created the false impression
that hooks were a viable automation tool. The second hook was a
post-commit hook that called `git commit --no-verify` to update a SHA
file. This produced infinite recursion — hundreds of commits in seconds.

Git hooks that call git commands will always risk recursive firing.
`--no-verify` does not prevent post-commit hooks from firing. There is
no safe way to make a post-commit hook that commits without the risk of
recursion. Git hooks are permanently prohibited in this project.

### 16.2 File Content Hashing for Change Detection

Hashing file contents to detect changes is encoding-dependent. Any
difference in line endings, encoding, or whitespace between the hash
computation environment and the CC runtime environment will cause
permanent false positives. The CC computer detected changes on every
boot and rebooted infinitely. Commit SHA comparison is encoding-immune
and is the only correct approach for this cross-platform deployment
context.

### 16.3 Hardcoded Role Lists

`configure_pc.lua` initially contained a hardcoded list of roles.
Adding a new role required editing `configure_pc.lua` and pushing to
the `interactive_role_selector` branch. This is a maintenance burden
and a drift risk — the hardcoded list will eventually diverge from the
actual available branches. The live tag fetch from GitHub API ensures
the list is always current. The correct approach is always to derive
lists from the authoritative source rather than maintaining a copy.

### 16.4 Monorepo Without Branch Isolation

A single branch with all code for all roles would eventually exceed 2MB
in deployed size. More immediately, it would mean every CC computer
pulling gigabytes of code it does not need. The branch-per-role pattern
is not optional — it is a hard requirement derived from the 2MB storage
constraint.

### 16.5 Auto-Reboot on Any File Change

Early versions of `startup.lua` rebooted whenever any file was updated.
This caused infinite reboot loops when `startup.lua` itself was the
changed file — each reboot pulled the new `startup.lua`, which detected
itself as changed, and rebooted again. The correct rule is: reboot only
when non-startup files change. `startup.lua` updates take effect on
the next natural reboot.

### 16.6 Polling for Updates

Polling GitHub for changes was considered as an alternative to
reboot-triggered sync. This was rejected for three reasons. First,
GitHub's raw content servers have rate limits that polling would
eventually hit. Second, a control system computer that reboots itself
mid-operation is dangerous. Third, the operational model of rebooting
to apply updates is standard and expected. The developer controls when
updates apply by controlling when computers reboot.

### 16.7 Recursive Interactive Loops

`configure_pc.lua` was initially written with a cancel path that called
`shell.run("configure_pc.lua")` — recursing into itself. This was noted
as bounded by human input requirements and technically safe, but was
replaced with a `while true` loop. Recursive self-invocation is a
pattern that should not be used in this environment even when bounded,
because it consumes stack frames on each recursion and could in theory
exhaust the heap given enough iterations.

---

## 17. Open Items and Build Order

### 17.1 Immediate Blocking Items

**NC mod rebuild and redeploy.** The three peripheral additions
(`isActive`, `getEnergyCapacity`, `getReactivityLevel`) are written
in Java but the mod has not been rebuilt. The JAR in the server mods
folder does not include them. All reactor control Lua code is blocked
until this is done.

### 17.2 Network Primitives (In Dependency Order)

These must be built in strict dependency order. Each item depends on
all items above it being complete and tested.

**`channel_bus.lua`** — first primitive. Must implement named channel
semantics, transport abstraction (wireless and wired), message framing
with type field, SHUTDOWN and HEARTBEAT reserved types, heartbeat
generation, and payload fragmentation. Must be tested in isolation.
Branches: `main`.

**`process_registry.lua`** — second primitive. Maintains the channel
registry table, prunes dead entries on missed heartbeat, provides the
coordinator with routing information. Depends on `channel_bus.lua`.
Branches: `main`.

**`display_node.lua`** — third primitive. Channel subscription,
state packet reception, monitor rendering using `touchpoint.lua`.
Depends on `channel_bus.lua`. Branches: `node/display`.

**`shell_commands.lua`** — fourth primitive. Implements `run`, `list`,
`watch`, `kill`. Depends on `process_registry.lua` and
`channel_bus.lua`. Branches: `main`.

### 17.3 branch_manager.py Deferred Commands

**`sync`** — dry-run diff, read-only, never commits. Safe to implement
at any time.

**`deploy`** — guarded commit and push. Must include: branch validity
check, `file_index.json` correctness verification, no-untracked-lua
guard, prominent branch name display, explicit confirmation. Implement
after the network primitives are stable — the deployment workflow must
be reliable before the control system is built.

### 17.4 First Application: Reactor Controller

After network primitives are complete. Deployed to `node/reactor_control`
branch. Components:

Reactor polling loop: reads full peripheral state on a configured
interval, constructs a compact state packet.

Safety monitor: evaluates heat margin, heat percentage, and reactivity
level against configured thresholds on every tick. Calls
`disableReactor()` if any threshold is exceeded. Runs independently of
the polling interval.

PID controller: adapted from Kasra-G pattern. Uses `setModerationLevel`
as the control output. Controls heat rather than RF buffer.

Channel bus publisher: broadcasts state packets and sends heartbeats.

Display renderer: deployed to `node/display`. Receives state packets
and renders using `touchpoint.lua`. Interactive controls for
enable/disable, moderation level adjustment.

### 17.5 Second Application: AE2 Monitor

Requires Advanced Peripherals (already planned). The AE2 peripheral
API must be investigated after Advanced Peripherals is installed. Peripheral
type names and available methods are not known and must not be assumed.

### 17.6 Infrastructure Items

**Update `CC_NETWORK_DESIGN.md`** — this document — after each
significant session. The document is the authoritative knowledge
transfer artifact and must remain current.

**Database cluster design** — architecture is complete (described in
Section 10.5) but not specified in detail. Defer until a concrete
persistent storage use case emerges.

**Coordinator redundancy** — automatic coordinator failover is a
significant architectural addition. Deferred until the basic system
is operational. Manual recovery on coordinator loss is the current
approach.

**Developer's deferred idea** — the developer mentioned an idea about
partial propagation patterns during the propagation command design
session but explicitly did not state it to avoid expanding scope.
This idea exists and should be solicited at the start of the next
development session.
