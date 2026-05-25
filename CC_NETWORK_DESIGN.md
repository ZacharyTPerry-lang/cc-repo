# ComputerCraft Distributed Control Network
## Design Document v2.0.0

**Project:** CC:Tweaked distributed control network for NuclearCraft Fork + AE2
**Repository:** https://github.com/ZacharyTPerry-lang/cc-repo
**Minecraft Version:** NeoForge 1.21.1
**CC:Tweaked Version:** Current, installed on shared server
**Author:** Zachary Perry
**Status:** Architecture complete, primitives not yet written

---

## Table of Contents

1. Project Intent and Philosophy
2. Hardware Constraints and Their Implications
3. The CI/CD Pipeline
4. Repository Architecture and Branch Strategy
5. Node Provisioning System
6. Network Topology
7. The Display Fabric
8. The Channel Bus and Process Model
9. Memory Management
10. The NuclearCraft Peripheral API
11. Third Party Code Assessment
12. Coding Conventions
13. Open Items and Build Order

---

## 1. Project Intent and Philosophy

The goal of this project is to build a distributed ComputerCraft network that monitors and controls NuclearCraft fission reactors and Applied Energistics 2 networks across a survival Minecraft server. The network must be operable entirely from outside the game — no direct interaction with in-game terminals during normal operation. The developer writes Lua code on a Windows development machine using a standard terminal environment (nvim, WSL Ubuntu), pushes to GitHub, and the in-game computers synchronize automatically on reboot.

The philosophy guiding every architectural decision in this project is that the system must be both operationally transparent and recoverable. Transparency means that every running process is visible and observable from anywhere on the network — there are no silent background processes. Recoverability means that a complete failure of any node, including the coordinator, must be recoverable without server administrator assistance. The developer does not own the server and cannot ask for block removal, world editing, or JVM restarts. Every failure mode must be resolvable from within the CC environment itself.

This project is being built on a private survival server where the developer has constructed a perimeter using world-digging machines. Physical space for computer placement is not a constraint. The binding constraints are Lua heap size per computer, server RAM consumption from active computers, and the absence of administrator access for recovery operations.

A secondary but important goal is that this system should eventually serve as a general-purpose distributed control fabric, not just a reactor monitor. The reactor controller and AE2 monitor are the first applications. The underlying network primitives — the channel bus, the process registry, the display fabric — are being designed to support dozens of independent processes running simultaneously, each with its own display that can be viewed from any monitor on the network.

---

## 2. Hardware Constraints and Their Implications

Understanding the hardware constraints of CC:Tweaked computers is essential to every design decision in this project. These constraints are not soft limits that can be worked around with clever code — they are hard ceilings enforced by the CC:Tweaked mod itself, and the architecture must be designed around them from the beginning.

### 2.1 Memory

Every CC:Tweaked computer has a Lua heap of 2MB. This is the total memory available for all running code, all loaded tables, all string data, and all coroutines on that computer. It is not per-process — it is the total for everything running on that physical CC computer. This is an extremely small heap by any modern standard.

The practical implication is that every data structure must be bounded. A table that grows without bound will eventually exhaust the heap and crash the computer. This is particularly dangerous for monitoring systems that accumulate historical data — a naive implementation that appends sensor readings to a table every tick will run out of memory within minutes. Every accumulating data structure must have a fixed maximum size with old entries pruned as new ones are added.

Code size itself is not the primary concern. A typical well-written Lua file is a few kilobytes. The concern is runtime allocation — tables created and populated during execution. The design response to this constraint is that each computer holds state only for its own process. No computer accumulates state on behalf of other computers. The coordinator holds only a registry table of channel names, computer IDs, and heartbeat timestamps, not the state payloads of every process it manages.

The 2MB limit also means that complex visualization and rendering should not happen on the same computer that is doing control logic. A computer doing reactor monitoring should send a compact state packet over the network to a dedicated display computer, which handles all the rendering work. This separation keeps both computers well within their memory budgets.

### 2.2 Storage

CC:Tweaked computer storage is 1MB for regular computers and 2MB for advanced computers. This is the filesystem limit — files written to the CC computer's virtual filesystem. These files are stored as actual files in a subdirectory of the Minecraft server's world folder, not in server RAM. An idle computer with data on disk consumes zero server RAM. This distinction is critical for the distributed database architecture described later.

The storage limit means that deployed code must be lean. A branch that is deployed to a worker node should contain only the files that node actually needs. The branch architecture described in Section 4 is designed specifically to keep each node's deployed footprint as small as possible. A compute node that performs a single mathematical transformation might have a deployed footprint of a single Lua file of a few kilobytes.

### 2.3 Network

CC:Tweaked supports two network transports: wireless rednet and wired modems with networking cable. Rednet messages can carry Lua tables as payloads, which CC:Tweaked serializes internally. The practical message size limit for table payloads is approximately 64KB per message. This is large enough for most state packets but requires careful design for payloads that carry large datasets, such as AE2 inventory snapshots.

For very large payloads, chunking is required. The channel bus must support fragmented message transmission — splitting a payload across multiple messages with sequence numbers and reassembling on the receiving end. This is a standard fragmentation pattern and must be built into the channel bus from the beginning, not added later.

### 2.4 Concurrency

CC:Tweaked computers are single-threaded. There is no true parallel execution on a single computer. The `parallel.waitForAny` and `parallel.waitForAll` API functions provide cooperative multitasking through coroutines, but only one coroutine executes at a time. A coroutine that blocks indefinitely will starve all other coroutines on that computer.

This means that every blocking operation — every `os.pullEvent`, every HTTP request, every rednet receive — must have a timeout. A process that blocks indefinitely waiting for a message that never arrives will freeze the entire computer. The design response is that the channel bus wraps all blocking operations with timeouts, and the shutdown flag is checked between every operation.

### 2.5 The Distributed Memory Model

Because each computer is limited to 2MB of RAM, the network as a whole can be thought of as a distributed memory system where each node contributes 2MB. Ten computers running as a single logical cluster provide 20MB of combined state capacity, but this capacity is only useful if the work is actually distributed across those computers. A single computer trying to hold 20MB of state will simply crash.

This has a direct implication for the database cluster architecture. A dedicated database cluster can provide meaningful persistent storage capacity by distributing data across many nodes, each holding a bounded slice of the total dataset. Each database node is idle almost all of the time — it wakes when a query arrives, reads from its local filesystem, responds, and returns to idle. Because idle computers consume no server RAM, a 1000-node database cluster would consume only the RAM of the handful of nodes actively processing queries at any moment. The storage capacity of such a cluster would be up to 2GB of server disk space, which is a real and useful amount of persistent storage for a Minecraft control system.

---

## 3. The CI/CD Pipeline

### 3.1 Design Rationale

The fundamental problem this pipeline solves is that the developer writes code on a Windows machine but the execution environment is a CC:Tweaked computer inside a Minecraft server that the developer does not control. There is no direct filesystem access to the server's CC computer directories, no SSH, and no way to push files directly. The only communication channel available is the CC:Tweaked HTTP API, which allows in-game computers to make outbound HTTP requests.

The solution is to use GitHub as the intermediary. The developer pushes code to a public GitHub repository. The CC computer fetches code from GitHub's raw content delivery network on every reboot. GitHub is always reachable from the CC computer (confirmed by `http.checkURL` returning `true nil`), serves files reliably, and provides version control for free.

The workflow was designed to be as simple as possible while remaining correct. After many iterations and several failure modes encountered during development, the final workflow is three commands with no hooks, no automation, and no moving parts that can fail silently.

### 3.2 Development Environment

The development machine runs Windows with WSL Ubuntu. All git operations are performed from WSL, not from PowerShell, because the SSH key for GitHub authentication is stored in the WSL environment. The GitHub account that owns the repository is `ZacharyTPerry-lang`. Authentication uses an SSH key already registered with GitHub, with the remote URL configured as `git@github.com:ZacharyTPerry-lang/cc-repo.git`. Password authentication to GitHub is not supported for git operations and will fail.

### 3.3 The Deployment Workflow

The complete deployment workflow is as follows:

```bash
python3 gen_file_list.py   # run only when lua files are added or removed
git add .
git commit -m "descriptive message"
git push
```

`gen_file_list.py` uses `git ls-files` to enumerate all tracked Lua files in the current branch and writes them to `file_list.json`. It must be run after new files are added to git tracking but before committing, because `git ls-files` only sees tracked files. If no Lua files were added or removed in this commit, `gen_file_list.py` does not need to be run.

There are no git hooks. This is an explicit design decision made after two serious failures with hook-based automation, described in Section 3.7.

### 3.4 The Sync Mechanism

On every boot, `startup.lua` performs the following sequence:

First, it fetches the latest commit SHA from `https://api.github.com/repos/ZacharyTPerry-lang/cc-repo/commits/main`. The GitHub API is confirmed reachable from the CC computer. The response is a JSON object from which the `sha` field is extracted.

Second, it reads the locally stored file `.deployed_sha`. If this file does not exist, the computer has never successfully synced and treats itself as needing a full update.

Third, it compares the remote SHA to the local SHA. If they match, the computer is up to date and proceeds directly to running its assigned program. If they differ, the computer fetches `file_list.json` to obtain the list of files to pull, then fetches each file individually and writes it to the local filesystem.

Fourth, after all files are written, it writes the new SHA to `.deployed_sha`. This is the commit of record — the computer is now at that commit.

Fifth, it determines whether to reboot. If any file other than `startup.lua` was updated, it reboots so that the updated files take effect. If only `startup.lua` itself was updated, it does not reboot — the update will take effect on the next natural reboot. This rule exists because if `startup.lua` triggered a reboot whenever it updated itself, and the new version of `startup.lua` also triggered a reboot for some reason, the computer would enter an infinite reboot loop. By never rebooting for its own update, `startup.lua` guarantees that the reboot chain is finite.

### 3.5 The Bootstrap Process

A freshly provisioned CC computer has nothing on it. The bootstrap process is a single line pasted into the CC terminal that fetches `bootstrap.lua` from GitHub and runs it:

```lua
local r=http.get("https://raw.githubusercontent.com/ZacharyTPerry-lang/cc-repo/main/bootstrap.lua") local f=fs.open("bootstrap.lua","w") f.write(r.readAll()) f.close() r.close() shell.run("bootstrap.lua")
```

`bootstrap.lua` fetches `startup.lua` from GitHub, writes it to disk, and reboots. On the next boot, `startup.lua` takes over and performs the full sync. After this one-time bootstrap, every future reboot is automatic.

For the role provisioning flow, `startup.lua` is configured to detect that no `role.cfg` exists and redirect to the interactive role selector, described in Section 5.

### 3.6 Recovery

If a CC computer enters a bad state — wrong files, corrupted sync, or a previous broken version of `startup.lua` — recovery requires deleting the minimum necessary state and re-bootstrapping. The recovery procedure is:

```lua
fs.delete("startup.lua")
fs.delete(".deployed_sha")
```

Then paste the bootstrap one-liner. This works because `startup.lua` is the entry point and `.deployed_sha` is the sync state. With both deleted, the bootstrap pulls a fresh `startup.lua` which then pulls everything from scratch. No other files need to be deleted unless they are known to be corrupted.

For a full wipe — if for any reason all files on the computer need to be cleared — the safe wipe command is:

```lua
for _, file in ipairs(fs.list("/")) do
    if file ~= "rom" then fs.delete(file) end
end
```

The `rom` directory must never be deleted. It contains the CC:Tweaked operating system and is write-protected, but attempting to delete it produces an access denied error that should not be triggered. All other directories and files in the root are user space and are safe to delete.

### 3.7 Failure Modes Encountered and Resolved

Several failure modes were encountered during development of the CI/CD pipeline. These are documented here so that future development does not repeat them.

**The CRLF hash mismatch loop.** The first sync mechanism used FNV-1a hashes of file contents to detect changes. Windows Git converts line endings from LF to CRLF on checkout by default. This caused the computed hash of every file to differ from the hash stored in the manifest on every sync, because the manifest was generated on Windows with CRLF files but CC expects LF. The computer entered an infinite reboot loop because files were always detected as changed. This approach was abandoned entirely in favor of SHA-based sync, which compares commit SHAs rather than file content hashes and is immune to line ending differences.

**The GitHub API 404.** An early version of the sync mechanism attempted to reach `api.github.com` but received a 404 response. This was caused by a misconfigured URL. The correct endpoint is `https://api.github.com/repos/{owner}/{repo}/commits/{branch}`. The URL format must be exact.

**The infinite post-commit hook loop.** A post-commit git hook was introduced to write the current commit SHA to `deployed_sha.txt` after each commit, solving the problem of `git rev-parse HEAD` returning the previous commit SHA when called from a pre-commit hook. The post-commit hook called `git commit --no-verify` to commit the updated SHA file. However, `--no-verify` only skips pre-commit hooks, not post-commit hooks. The post-commit hook therefore triggered itself recursively, producing hundreds of commits before the terminal was killed with Ctrl+C. All git hooks were removed permanently after this incident. No git hooks are used in this project.

**The Zone.Identifier contamination.** Files downloaded through Windows Explorer acquire Zone.Identifier metadata files (e.g. `startup.lua:Zone.Identifier`). When these files were added via `git add .`, they were committed to the repository and appeared as tracked files. This was resolved by adding `*:Zone.Identifier` to `.gitignore` and removing the contaminated files from tracking. All file operations should be performed from WSL rather than through Windows Explorer to prevent this.

**The gen_file_list.py ordering problem.** `gen_file_list.py` uses `git ls-files` to enumerate tracked files. If it is run before new files are added to git tracking with `git add`, it will not include those files in `file_list.json`. The correct order is: add files to tracking with `git add`, run `gen_file_list.py`, commit. If `gen_file_list.py` is run first, it will generate a stale `file_list.json` that omits the new files.

---

## 4. Repository Architecture and Branch Strategy

### 4.1 Rationale for Branch-Per-Role

The naive approach to a multi-role CC network is a single monolithic repository where every computer pulls the same codebase and runs only the parts it needs. This approach fails for two reasons. First, the total codebase will eventually exceed 2MB, at which point no single computer can hold all of it. Second, a computer pulling files it does not need wastes both storage and HTTP requests during sync.

The correct approach is to use git branches as deployment targets. Each branch contains only the files needed for a specific role. A computer that runs reactor control logic only pulls the reactor control branch, which might contain a handful of Lua files totaling a few dozen kilobytes. A database node that performs a single query-response function pulls a branch that might contain a single Lua file.

Multiple repositories were considered and rejected. The overhead of maintaining authentication, bootstrap URLs, and sync logic for multiple repositories is significantly higher than the overhead of maintaining branches within a single repository. Branches within a single repository can be created, deleted, and navigated with simple tooling, as described in Section 4.3.

### 4.2 Branch Naming Convention

Branches are named with a hierarchical prefix that identifies their category and role:

The `main` branch contains the coordinator, channel bus, and core network primitives. This is the stable deployed branch for the coordinator computer.

Branches prefixed with `node/` contain the code for a specific worker node role. Examples include `node/reactor_control`, `node/ae2_monitor`, and `node/display`. Each node branch contains only the files needed for that specific role.

Branches prefixed with `cluster/` contain the code for cluster head computers that manage a wired cluster of worker nodes. Examples include `cluster/reactor` and `cluster/ae2`.

The `interactive_role_selector` branch is a special throwaway branch containing only `configure_pc.lua`. It exists solely to support the first-boot provisioning flow. After a computer runs `configure_pc.lua` and selects its role, this branch is never pulled by that computer again.

When a branch approaches 2MB in total deployed file size, it must be split into two or more branches immediately. This is a hard rule, not a guideline.

### 4.3 Branch Management Tooling

`branch_manager.py` is a local Python utility that wraps common git branch operations. It is listed in `.gitignore` and is never committed to the repository. It provides the following commands:

```bash
python3 branch_manager.py list              # show all local and remote branches
python3 branch_manager.py create <branch>   # create branch locally and push to remote
python3 branch_manager.py delete <branch>   # delete branch locally and remotely (with confirmation)
python3 branch_manager.py switch <branch>   # checkout branch
python3 branch_manager.py show              # show current branch
```

The tool confirms destructive operations before executing them. Branch deletion requires typing `y` at a confirmation prompt.

### 4.4 Startup.lua and Branch Awareness

`startup.lua` reads `/role.cfg` to determine which branch to pull. The role configuration file contains a single line:

```
branch=node/reactor_control
```

On sync, `startup.lua` fetches `file_list.json` from the configured branch, not from `main`. This means each computer automatically pulls only the files for its assigned role. The GitHub API SHA check also uses the configured branch, so SHA comparisons are branch-specific.

---

## 5. Node Provisioning System

### 5.1 Design Goals

The provisioning system must satisfy three requirements. First, it must be operable entirely from within the CC terminal — no external tools, no file transfers, no commands outside the game. Second, it must be self-documenting — the developer should not need to remember role names or branch names. Third, it must produce a computer that will correctly self-provision on every subsequent reboot without any further manual intervention.

### 5.2 The First Boot Flow

When a CC computer boots with a fresh `startup.lua` but no `role.cfg`, `startup.lua` detects the missing configuration and fetches the `interactive_role_selector` branch instead of a node branch. The `interactive_role_selector` branch contains only `configure_pc.lua`.

`configure_pc.lua` presents an interactive prompt that lists all available roles. The developer selects a role from the numbered list. `configure_pc.lua` writes the selected role to `/role.cfg`, deletes itself, and reboots. On the next boot, `startup.lua` finds `role.cfg`, reads the configured branch, and performs the standard sync against that branch. The computer is now fully provisioned and will self-maintain on every subsequent reboot.

The list of available roles is maintained in `configure_pc.lua` itself. Adding a new role requires creating the corresponding branch, adding it to the role list in `configure_pc.lua`, and pushing the updated `configure_pc.lua` to the `interactive_role_selector` branch. No changes are needed on any already-provisioned computer.

### 5.3 Recovery Without State

A key design requirement is that recovery must be possible from nothing. Nearly every computer on this network holds no state that needs to be recovered — its role is in `role.cfg` and its code comes from GitHub. If a computer needs to be fully reset, the procedure is to wipe it and run the bootstrap one-liner. The interactive provisioning flow handles the rest. The only computers that require special recovery consideration are database nodes, which hold data on their local filesystem that must be treated as persistent.

---

## 6. Network Topology

### 6.1 Two Transport Layers

The network uses two physically distinct transport layers with different roles.

The wireless fabric uses CC:Tweaked wireless modems and the rednet API. Wireless communication reaches any computer with a wireless modem within range. The fabric is used for coordinator-to-node communication, channel state broadcasts, and display subscription messages. Any computer anywhere can participate in the fabric by having a wireless modem attached.

The wired cluster network uses CC:Tweaked wired modems and networking cable. Wired communication is restricted to computers physically connected by cable. Wired networks are used for clusters of worker nodes performing related tasks, such as a cluster of computers monitoring different components of the same reactor array. Wired networks are significantly easier to manage than wireless for high-density node groups because they do not require line-of-sight or range calculations and have no interference issues.

### 6.2 Node Roles

The network has four distinct node roles.

The fabric coordinator is the root of the process tree. It has a wireless modem and manages the channel registry, process lifetime, and shutdown broadcast. It is a designated computer that should be treated as permanent infrastructure. Killing the coordinator initiates a graceful shutdown of all managed processes across the entire network.

The cluster I/O manager is the interface between a wired cluster and the wireless fabric. It has both a wired modem (facing the cluster) and a wireless modem (facing the fabric). It proxies messages between cluster worker nodes and the fabric, translating between the two transport protocols. Each physical cluster has one cluster I/O manager.

Worker nodes are computers that run a single process. Each worker node has a wired modem connecting it to its cluster's I/O manager. A worker node publishes its state on a named channel and receives control commands from the coordinator through the cluster I/O manager.

Display nodes are computers attached to one or more CC monitors. They subscribe to a named channel and render the state payloads they receive onto their attached monitors. A display node has no process logic of its own — it is purely a renderer. Display nodes may have either a wireless modem (for fabric-connected displays in arbitrary locations) or a wired modem (for displays in a dedicated control room connected to a cluster).

### 6.3 The Coordinator as Root

The coordinator is the single point of authority for the entire network. It maintains the authoritative list of all live channels, all display subscriptions, and all process assignments. It is the only node that can spawn and kill processes. It is the only node that can reassign displays. It receives heartbeats from all managed processes and detects dead processes by missed heartbeats.

If the coordinator goes down, all managed processes continue running but become unmanageable — they cannot be killed, reassigned, or monitored through the normal interface. They will continue running until their host computers are rebooted or until they exhaust memory. This is an acceptable failure mode because the coordinator is designated infrastructure and its loss is treated as a significant event requiring the developer to re-enter the game and restart it. Processes spawned directly from individual CC terminals (standalone processes) are not coordinator-managed and are not affected by coordinator loss.

---

## 7. The Display Fabric

### 7.1 Core Contract

The display fabric is built on a single foundational contract: a process exists if and only if its channel is live. Every process that runs on the network owns a named channel. It broadcasts its state to that channel on a fixed interval. It sends a heartbeat on that channel even when its state has not changed. If a channel goes silent — no heartbeat for a configured number of ticks — the process is considered dead.

This contract has two important consequences. First, there are no silent background processes. If something is running, it has a channel. If a channel is live, something is running. The two are definitionally equivalent. Second, every running process is always observable from anywhere on the network. A developer who wants to see what a process is doing simply subscribes a monitor to its channel. The process does not need to be restarted, reconfigured, or modified in any way.

### 7.2 The Broadcast-Subscribe Model

Every producer broadcasts its state continuously on its channel. It does not know or care how many subscribers are listening. It does not know or care what monitors are rendering its state. It simply broadcasts.

Every display node subscribes to exactly one channel at a time. It receives state packets from that channel and renders them. It can be reassigned to a different channel by a command from the coordinator, at which point it unsubscribes from the current channel and subscribes to the new one.

Multiple display nodes can subscribe to the same channel simultaneously. This is the "cast to the big screen" operation. The developer invokes a command that tells the central display to subscribe to the reactor channel. The reactor controller does not change. The control room display does not change. The central display simply begins receiving and rendering the same state packets that the control room display was already receiving. When the developer is done, another command tells the central display to resubscribe to whatever it was showing before.

### 7.3 The Invocation Model

Every subroutine is invoked with a display assignment:

```
run reactor_control --display control_room
```

This command tells the coordinator to spawn the `reactor_control` process and tells the `control_room` display node to subscribe to the `reactor_control` channel. The display assignment is not hardwired — it is a runtime parameter. The same process could be started with a different display:

```
run reactor_control --display central_display
```

To view a running process on an additional display without changing its primary display:

```
watch reactor_control --display central_display
```

This tells the `central_display` node to subscribe to the `reactor_control` channel. The `control_room` display continues showing `reactor_control` unchanged. Both displays now show the same data.

### 7.4 Process Management Commands

The full set of process management commands, to be implemented in `shell_commands.lua`, is as follows.

`run <process> --display <node>` spawns a process and assigns a display to it. The coordinator registers the channel, spawns the process on the appropriate node, and sends a subscribe command to the specified display node.

`list` returns the current state of the channel registry — all live channels, the computer ID of the producing node, the last heartbeat timestamp, and the current display assignment or assignments for each channel.

`watch <channel> --display <node>` subscribes a display node to a channel. The display node begins rendering that channel's state. The channel's producing process is unaffected.

`kill <channel>` sends a SHUTDOWN message to the specified channel. The process receiving the SHUTDOWN message cleans up and exits. The coordinator removes the channel from the registry. Any display nodes subscribed to that channel receive the SHUTDOWN and go idle.

### 7.5 The Shutdown Protocol

Graceful shutdown is a first-class operation, not an afterthought. The complete shutdown sequence for a coordinator-initiated full shutdown is as follows.

The developer issues a kill command targeting the coordinator itself, or the coordinator detects a shutdown condition. The coordinator iterates its channel registry and broadcasts a SHUTDOWN message on every live channel. It then waits for acknowledgement from each channel, with a timeout. Channels that do not acknowledge within the timeout are marked as unresponsive and logged. The coordinator then broadcasts a SHUTDOWN message on the display fabric, causing all display nodes to clear their screens and go idle. The coordinator then exits.

Every process must handle SHUTDOWN as a reserved message type with higher priority than any application message. The channel bus checks every received message against the SHUTDOWN type before passing it to application logic. A process that receives SHUTDOWN must complete its current operation (which, by the finite pattern rule, is always bounded), clean up any allocated resources, and exit cleanly.

The shutdown flag pattern that every process must implement is as follows. A module-level boolean `shutdown_requested` is initialized to false. The channel bus sets it to true when a SHUTDOWN message is received. Every loop in every process checks this flag as its first action. Every blocking operation has a timeout so that the flag check is reached within a bounded time.

The reason this matters is that CC computers have no external kill mechanism accessible to the developer without server admin access. `Ctrl+T` terminates a running program from the local terminal, but the developer is not always at the local terminal. Without a reliable SHUTDOWN protocol, a hung process can only be killed by physically breaking the computer block, which requires server admin access. The SHUTDOWN protocol is the only tool available for clean remote process termination.

---

## 8. The Channel Bus and Process Model

### 8.1 Purpose

`channel_bus.lua` is the lowest-level network primitive. Everything else in the system depends on it. It abstracts the transport layer (wireless rednet vs. wired modem), provides named channel semantics on top of computer ID and port addressing, implements message framing and fragmentation for large payloads, handles heartbeat generation and reception, and enforces the SHUTDOWN reserved message type.

Application code never calls `rednet.send` or `rednet.receive` directly. It calls `channel_bus.send`, `channel_bus.receive`, and `channel_bus.broadcast`. The channel bus handles all transport details.

### 8.2 Message Types

The channel bus defines a small set of reserved message types that are handled by the bus itself and never passed to application logic. SHUTDOWN is the most important. HEARTBEAT is the second — it is sent by every process on a fixed interval and received by the coordinator to maintain the process registry. ACK is sent in response to SHUTDOWN to confirm clean exit.

All other message types are application-defined and passed through to the application layer without modification.

### 8.3 Fragmentation

For payloads that exceed the practical single-message size, the channel bus implements fragmentation. A large payload is split into chunks of a defined maximum size. Each chunk is sent as a separate message with a sequence number, a total count, and a message ID that groups all chunks belonging to the same logical message. The receiving end reassembles chunks in order and delivers the complete payload to the application layer only when all chunks have been received.

Fragmentation adds complexity and latency. It should only be used for payloads that genuinely require it. State packets for reactor monitoring will typically be small enough to fit in a single message. AE2 inventory snapshots, which may contain hundreds of item entries, are the primary use case for fragmentation.

### 8.4 The Heartbeat and Health Monitoring

Every process sends a HEARTBEAT message on its channel at a configured interval, regardless of whether its state has changed. The coordinator receives these heartbeats and updates the last-seen timestamp for each channel in the registry.

If the coordinator does not receive a heartbeat from a channel within a configured timeout (a multiple of the heartbeat interval, to allow for network jitter), it marks that channel as potentially dead and begins a grace period. If no heartbeat arrives within the grace period, the channel is marked as dead, removed from the registry, and any display nodes subscribed to it are notified.

This mechanism provides passive health monitoring without requiring the coordinator to poll every process. Processes that are running correctly generate their own evidence of health. Processes that have crashed, hung, or been killed stop generating heartbeats and are detected automatically.

---

## 9. Memory Management

### 9.1 The Fundamental Rule

No data structure in any process may grow without bound. Every table that accumulates data over time must have a maximum size enforced at insertion time. When a new entry would exceed the maximum, the oldest entry is removed before the new one is added. This is a non-negotiable design rule that applies to every file in every branch of this repository.

### 9.2 State Packet Design

State packets — the payloads that processes broadcast on their channels — must be designed to be as compact as possible. Every field in a state packet must be justified by a downstream consumer that actually uses it. Fields that are "nice to have" but not consumed by any subscriber are waste. For a reactor state packet, the core required fields are the values needed by the display renderer and the values needed by the safety logic. Everything else is excluded.

Numeric values should use integers where possible. Floating point values should be rounded to a useful precision before transmission. String values should be kept as short as possible — use codes or enumerated integers instead of descriptive strings where the receiving end can reconstruct the display text.

### 9.3 The Registry Pruning Rule

The coordinator's channel registry is the central data structure most at risk of unbounded growth. Every dead channel entry must be removed from the registry promptly. The coordinator does not accumulate historical data about dead processes — that information is irrelevant to the current operational state. If a process dies and is restarted, it registers as a new channel entry. There is no merger with the old entry.

### 9.4 Display Node Memory

Display nodes are at particular risk because they may receive state packets at high frequency from one or more channels. A display node must not accumulate received state packets. It processes each packet, updates its display, and discards the packet. It holds only the most recent state for the channel it is currently rendering. Historical data for graphing or trend display, if required, is held in a fixed-size ring buffer with a defined maximum entry count.

### 9.5 The Database Cluster Memory Model

Database cluster nodes hold data on their local filesystem and load it into memory only to service a query. A database node that is idle consumes no heap memory beyond the minimal overhead of `startup.lua` waiting for a rednet message. When a query arrives, the node loads the relevant data from disk, processes the query, sends the response, and immediately deallocates the loaded data. It does not cache data in memory between queries.

This model means that the database cluster's storage capacity is determined by the total filesystem space across all nodes, which is up to 2GB for a 1000-node cluster, and its memory consumption is determined by the size of the data loaded to service a single query, which must fit within a single node's 2MB heap.

---

## 10. The NuclearCraft Peripheral API

### 10.1 Peripheral Registration

The NuclearCraft fission reactor exposes a CC:Tweaked peripheral through `SolidFissionReactorPeripheral.java`, located at `src/main/java/igentuman/nc/compat/cc/SolidFissionReactorPeripheral.java` in the NuclearCraft fork. This is the only file in the entire fork that imports CC:Tweaked APIs.

The peripheral is registered under the type name `nc_fission_reactor`. In Lua, the peripheral is accessed as:

```lua
local reactor = peripheral.find("nc_fission_reactor")
```

### 10.2 Full API Reference

The following methods are exposed by the peripheral. Three methods — `isActive`, `getEnergyCapacity`, and `getReactivityLevel` — are additions made during this project and are not present in the upstream igentuman NuclearCraft Neoteric repository.

**State query methods:**

`isFormed()` returns a boolean indicating whether the reactor multiblock structure is currently valid. This checks both `isCasingValid` and `isInternalValid` on the controller block entity. A reactor that is not formed will not process fuel regardless of its active state.

`isActive()` returns a boolean indicating whether the reactor is currently running. This reads `controllerEnabled` from the controller block entity. `controllerEnabled` is the computed active state — it is true only when the reactor is formed, has a redstone signal enabling it, and has not been force-shut down via `disableReactor()`. This is the authoritative active state and should be used in preference to any derived approximation.

`getName()` returns the reactor's configured name as a string.

`hasRecipe()` returns a boolean indicating whether the current fuel configuration has a valid recipe.

`isSteamMode()` returns a boolean indicating whether the reactor is configured for steam output rather than FE output.

`getSteamRate()` returns a double representing the current steam output rate.

`getDepletionProgress()` returns an integer from 0 to 100 representing the percentage of fuel consumed. 100 indicates the fuel is fully depleted.

`getMaxHeatCapacity()` returns a double representing the maximum heat the reactor can hold before damage occurs.

`getEnergyPerTick()` returns an integer representing the FE generated per tick at current operating conditions.

`getEnergyStored()` returns an integer representing the FE currently stored in the reactor's internal buffer.

`getEnergyCapacity()` returns an integer representing the maximum FE capacity of the reactor's internal buffer. This reads `energyStorage().getMaxEnergyStored()`. The buffer capacity is fixed at 100,000,000 FE by the `createEnergy()` method in `FissionControllerBE`. Buffer percentage is computed in Lua as `getEnergyStored() / getEnergyCapacity() * 100`.

`getHeatMultiplier()` returns a double representing the current heat multiplier.

`getModeratorsCount()` returns an integer count of moderator blocks in the reactor structure.

`getHeatSinksCount()` returns an integer count of heat sink blocks in the reactor structure.

`getFuelCellsCount()` returns an integer count of fuel cell blocks in the reactor structure.

`getCooling()` returns an integer representing the heat removed per tick by heat sinks.

`getHeat()` returns an integer representing the heat generated per tick by the fuel. This value is zero when the reactor is inactive, even if the reactor retains stored heat.

`getHeatStored()` returns an integer representing the current stored heat.

`getReactivityLevel()` returns an integer from 0 to 100 representing the current reactivity. This reads `reactor.reactivityLevel`, which increments by 1 per tick when the reactor is active and decrements by 1 per tick when inactive, clamped to the range 0-100. Reactivity directly affects both heat output and FE output — a reactor at 50% reactivity produces approximately half its steady-state output. This value is essential for understanding whether a recently enabled reactor has reached steady state and for interpreting heat and power readings during the ramp-up and ramp-down periods.

`getFuelInSlot()` returns a table describing the current fuel item.

**Control methods:**

`enableReactor()` calls `reactor.disableForceShutdown()`, clearing the force shutdown flag and allowing the reactor to run if it has a redstone signal and is formed.

`disableReactor()` calls `reactor.forceShutdown()`, setting the force shutdown flag and stopping the reactor regardless of redstone state.

`setModerationLevel(int)` calls `reactor.adjustModerationLevel(level)` to adjust the neutron moderation level.

`voidFuel()` calls `reactor.voidFuel()` to discard the current fuel.

### 10.3 Derived Values Computed in Lua

All safety logic and derived state is computed in Lua, not in Java. The Java peripheral exposes raw values only. The following derived values are computed by the reactor control program:

Heat margin is computed as `getCooling() - getHeat()`. A positive heat margin means the reactor is cooling faster than it is generating heat. A negative heat margin means the reactor is accumulating heat and will eventually exceed capacity.

Heat percentage is computed as `getHeatStored() / getMaxHeatCapacity() * 100`.

Energy buffer percentage is computed as `getEnergyStored() / getEnergyCapacity() * 100`.

Overheating state is computed as `getHeat() > getCooling()`, which indicates that heat is accumulating. Note that this can be true even with a positive heat margin if the stored heat is already high — the combination of heat percentage and heat margin together determine the safety state.

### 10.4 Java Source Locations

The peripheral implementation is at:
`src/main/java/igentuman/nc/compat/cc/SolidFissionReactorPeripheral.java`

The controller block entity (source of all peripheral data) is at:
`src/main/java/igentuman/nc/block/fission/entity/FissionControllerBE.java`

The energy storage utility is at:
`src/main/java/igentuman/nc/util/capability/CustomEnergyStorage.java`

The three additions (`isActive`, `getEnergyCapacity`, `getReactivityLevel`) have been written but the mod has not been rebuilt and redeployed since the additions were made. They must be compiled and the JAR redeployed to the server before they can be used in Lua.

---

## 11. Third Party Code Assessment

### 11.1 touchpoint.lua

Source: Lyqyd (original), modified by DrunkenKas (Kasra Ghaffari)
Repository: https://github.com/Kasra-G/ReactorController
License: MIT
Status: Adopted as the button library for all display work.

`touchpoint.lua` is a click-map based button system for CC:Tweaked monitors. It maintains a 2D array mapping monitor coordinates to button names, handles `monitor_touch` events, and provides toggle, flash, and rename operations on buttons. It is completely generic — it contains no reactor logic, no application-specific code, and no dependencies beyond the CC:Tweaked standard API. It is well-written, MIT licensed, and actively maintained. There is no reason to write a replacement.

The library is used as follows. A `touchpoint` instance is created for a specific monitor peripheral. Buttons are added with position, size, callback function, and color parameters. The instance's `handleEvents` method is called in the main event loop and returns a `button_click` event when a button is activated. The instance's `draw` method renders all buttons to the monitor.

### 11.2 PID Controller Pattern

Source: Kasra Ghaffari (DrunkenKas)
Repository: https://github.com/Kasra-G/ReactorController
License: MIT
Status: Algorithm adopted, peripheral calls replaced.

The reactor controller in `reactorController.lua` implements a dual-error weighted PID controller for managing reactor output. The controller maintains two error signals simultaneously: the difference between actual and target RF/t output, and the difference between actual and target buffer fill level. These two errors are combined with dynamic weights — when the buffer level is far from target, the buffer error dominates; when it is close to target, the output rate error dominates. This produces smoother control behavior than a single-error PID.

The PID parameters in the original are Kp = -0.08, Ki = -0.0015, Kd = -0.01. The negative signs reflect the inverse relationship between control rod insertion level and output — more insertion means less output, so the control response to a positive error (target greater than actual) is a decrease in insertion level.

For the NuclearCraft application, the same PID structure applies but the controlled variable is moderation level (via `setModerationLevel`) rather than control rod insertion, and the primary controlled quantity is heat rather than RF buffer. The peripheral calls are entirely different but the mathematical structure of `iteratePID` transfers directly.

### 11.3 Rejected Third Party Code

CastilloAnthony's Nuclearcraft-Reactor-UI-ControlPanel targets OpenComputers on Minecraft 1.12.2. OpenComputers uses a completely different peripheral API (`component.proxy`, `component.list`) that is incompatible with CC:Tweaked. No code is transferable.

ThePoleThatFishes' NC-feat-OC-scripts similarly targets OpenComputers. The turbine calculator script is pure mathematics with no peripheral calls and is potentially usable as a reference for turbine efficiency calculations, but no direct code transfer is applicable.

---

## 12. Coding Conventions

### 12.1 Naming

The project adopts the verbosity principles from the developer's primary C project conventions, adapted for Lua. Abbreviations are prohibited except where the abbreviation is more universally understood than the full word in the context of systems programming. `error` not `err`. `buffer` not `buf`. `filesystem` not `fs`. `channel` not `ch`. `response` not `res`.

Function names are verb phrases that describe the complete action. `fetch_url` not `get`. `write_local_file` not `write`. `compute_heat_margin` not `heat`.

Variable names describe what is stored and in what form. `remote_sha` not `sha`. `deployed_sha_path` not `path`. `shutdown_requested` not `running`.

File names describe what the file contains, not what it is called informally. `channel_bus.lua` not `net.lua`. `process_registry.lua` not `registry.lua`. The name `util` is prohibited — if a file contains utilities, name it for what those utilities do.

### 12.2 Comments

Comments exist for non-obvious logic and contracts the caller must understand. They do not describe what the code does — the names do that. A function whose purpose is clear from its name and parameters does not need a comment. A function with a non-obvious precondition, a side effect the caller must account for, or a behavioral guarantee the caller depends on does need a comment stating that contract explicitly.

### 12.3 Finite Patterns

Recursion is prohibited. All loops must have a termination condition that is guaranteed to be reached within a bounded number of iterations. No loop may depend on an external condition (network response, peripheral availability) without a timeout that guarantees eventual termination. This rule exists because CC computers have no external kill mechanism accessible without server admin access. A hung loop cannot be interrupted remotely.

### 12.4 Error Handling

Every network operation returns either a value or nil plus an error message. The caller must check for nil before using the value. Silent failures — discarding the error and proceeding as if the operation succeeded — are prohibited. Every error either terminates the current operation with a logged message or triggers a retry with a bounded retry count.

### 12.5 Storage Discipline

No file is written to the CC computer's filesystem except role configuration (`role.cfg`), sync state (`.deployed_sha`), and application-specific persistent data that is explicitly designed to be persistent. Log files, temporary files, and cached data must not accumulate on the filesystem. The 1-2MB filesystem limit will be exhausted by unconstrained file accumulation.

---

## 13. Open Items and Build Order

### 13.1 Immediate Prerequisites

The NuclearCraft fork must be rebuilt and the JAR redeployed to the server before the three peripheral additions (`isActive`, `getEnergyCapacity`, `getReactivityLevel`) are available in Lua. This is a blocking dependency for all reactor control code.

The `interactive_role_selector` branch must be created before any new computers are provisioned. This requires creating the branch, writing `configure_pc.lua` with the complete role list, pushing, and verifying that the bootstrap flow correctly selects and applies a role.

### 13.2 Build Order for Network Primitives

The network primitives must be built in dependency order. Each item depends on all items above it being complete and tested before the next is begun.

`channel_bus.lua` is the first primitive to write. It must implement: named channel broadcast and receive over both wireless rednet and wired modems, message framing with type field, SHUTDOWN reserved message handling, heartbeat generation and reception, and fragmentation for large payloads. It must be tested in isolation before any other primitive depends on it.

`process_registry.lua` is the second primitive. It maintains the channel registry table, prunes dead entries on missed heartbeat, and provides the coordinator with the information needed to route display subscriptions and process kill commands. It depends on `channel_bus.lua`.

`display_node.lua` is the third primitive. It handles channel subscription, state packet reception, and monitor rendering. It uses `touchpoint.lua` for any interactive display elements. It depends on `channel_bus.lua`.

`shell_commands.lua` is the fourth primitive. It implements the `run`, `list`, `watch`, and `kill` commands. It depends on `process_registry.lua` and `channel_bus.lua`.

`configure_pc.lua` for the `interactive_role_selector` branch is independent of the above and can be written at any time. It depends only on the CC:Tweaked standard API.

### 13.3 First Application: Reactor Controller

After the network primitives are complete, the reactor controller is the first application. It will be deployed to the `node/reactor_control` branch. It consists of:

A reactor polling loop that reads the full peripheral state on a configured interval and constructs a compact state packet. The polling interval must be chosen to balance data freshness against CPU and network load — every tick is almost certainly unnecessary and wastes resources.

A safety monitor that evaluates heat margin, heat percentage, and reactivity level against configured thresholds and calls `disableReactor()` if any threshold is exceeded. The safety monitor runs on every tick regardless of polling interval, because safety conditions can change faster than the display update rate.

A PID controller adapted from the Kasra-G pattern that adjusts moderation level to maintain target operating conditions.

A channel bus publisher that broadcasts the state packet on the reactor's channel at the polling interval and sends heartbeats between state broadcasts.

A display renderer, deployed to the display node, that receives state packets and renders them using `touchpoint.lua` for interactive controls.

### 13.4 Second Application: AE2 Monitor

AE2 integration requires Advanced Peripherals, which is already planned for installation. The AE2 peripheral API must be investigated after Advanced Peripherals is installed before any AE2 code is written. The peripheral type names and available methods are not known and must not be assumed.

### 13.5 Long-Term Items

The database cluster architecture is designed but not yet specified in detail. The query protocol, data schema, and distribution strategy must be designed when a concrete use case requiring persistent storage emerges. The architecture supports it but no immediate implementation is planned.

The coordinator redundancy problem — what happens if the coordinator computer is lost — is noted but not solved. For the current deployment context (private server, developer is present), coordinator loss is a recoverable manual event. Automatic coordinator failover is a significant architectural addition that is deferred until the basic system is operational.
