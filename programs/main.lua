-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- programs/main.lua
-- NC Fork fission reactor interior builder.
-- Reads reactor.json from this branch,
-- navigates the reactor interior using a
-- boustrophedon (snake) scan, and places
-- each block with turtle.placeDown().
-- Reports progress to job_meta.json via
-- the GitHub Contents API.
--
-- PHYSICAL SETUP:
--   Build the reactor casing on all sides
--   except the front face. Place the turtle
--   just inside the front opening at the
--   bottom-left corner of the interior,
--   facing into the reactor (+Z).
--   Place a chest DIRECTLY BELOW the
--   turtle's starting position. Load all
--   required blocks into the chest.
--   The turtle restocks via turtle.suckDown
--   by returning home between placements.
--
--   Run: programs/main.lua
--   Resume after crash: automatic (reads
--   ncfork_progress.json if present).
--   Enter 0 if prompted to exit early.
--
-- Branches : reactor-1, reactor-2,
--            reactor-3, reactor-4,
--            reactor-5, reactor-6,
--            reactor-7, reactor-8,
--            reactor-9, reactor-10
-- Depends  : lib/base64, lib/github
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
--
-- [1]  CONFIGURATION      ln. 44
-- [2]  FILE OPERATIONS    ln. 65
-- [3]  CONFIG LOADING     ln. 85
-- [4]  REACTOR FETCH      ln. 115
-- [5]  JOB METADATA       ln. 150
-- [6]  MOVEMENT           ln. 200
-- [7]  INVENTORY          ln. 290
-- [8]  BUILD              ln. 345
-- [9]  ENTRY POINT        ln. 430
--
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-- =========================================
-- [1] CONFIGURATION
-- =========================================

local github = require("lib.github")

local REPO_OWNER     = "ZacharyTPerry-lang"
local REPO_NAME      = "cc-repo"
local RAW_ROOT       =
    "https://raw.githubusercontent.com/"
    .. REPO_OWNER .. "/"
    .. REPO_NAME .. "/"
local ROLE_CFG_PATH  = "role.cfg"
local TOKEN_PATH     = ".github_token"
local PROGRESS_PATH  = "ncfork_progress.json"
local META_PATH      = "job_meta.json"
local MAX_MOVE_TRIES = 64
local MAX_SUCK_TRIES = 32
local UPDATE_INTERVAL = 50

-- =========================================
-- [2] FILE OPERATIONS
-- =========================================

local function read_local_file(path)
    if not fs.exists(path) then
        return nil
    end
    local handle = fs.open(path, "r")
    local content = handle.readAll()
    handle.close()
    return content
end

local function write_local_file(
        path, content)
    local handle = fs.open(path, "w")
    handle.write(content)
    handle.close()
end

-- =========================================
-- [3] CONFIG LOADING
-- =========================================

-- read_configured_branch
-- Reads role.cfg to determine which
-- reactor-N branch this turtle is on.
local function read_configured_branch()
    local content =
        read_local_file(ROLE_CFG_PATH)
    if not content then
        error("No role.cfg found.")
    end
    local branch =
        content:match("branch=([^\n]+)")
    if not branch then
        error("role.cfg has no branch=")
    end
    return branch:gsub("%s+", "")
end

-- load_github_token
-- Reads .github_token and strips whitespace.
-- The token is written once at provisioning
-- time and never committed to git.
local function load_github_token()
    local raw = read_local_file(TOKEN_PATH)
    if not raw then
        error(
            "No .github_token found. "
            .. "Write your GitHub token to "
            .. TOKEN_PATH
        )
    end
    return raw:match("^%s*(.-)%s*$")
end

-- =========================================
-- [4] REACTOR FETCH
-- =========================================

-- fetch_reactor_layout
-- Downloads reactor.json from this branch
-- via the GitHub raw CDN (no auth needed).
-- Returns the parsed layout table or
-- calls error() on failure.
local function fetch_reactor_layout(branch)
    local url = RAW_ROOT .. branch
        .. "/" .. "reactor.json"
    local response, error_message =
        http.get(url)
    if not response then
        error(
            "Cannot fetch reactor.json: "
            .. tostring(error_message)
        )
    end
    local content = response.readAll()
    response.close()
    local layout =
        textutils.unserialiseJSON(content)
    if not layout
            or not layout.grid
            or not layout.meta then
        error(
            "reactor.json is invalid or"
            .. " unpublished."
        )
    end
    return layout
end

-- count_non_air_blocks
-- Counts placeable blocks in the layout.
-- Used to show total progress.
local function count_non_air_blocks(layout)
    local count  = 0
    local grid   = layout.grid
    local size_y = layout.meta.sizeY
    local size_x = layout.meta.sizeX
    local size_z = layout.meta.sizeZ
    for ry = 0, size_y - 1 do
      for rx = 0, size_x - 1 do
        for rz = 0, size_z - 1 do
          local block =
            grid[ry+1][rx+1][rz+1]
          if block ~= "minecraft:air" then
            count = count + 1
          end
        end
      end
    end
    return count
end

-- =========================================
-- [5] JOB METADATA
-- =========================================

-- fetch_job_metadata_and_sha
-- Fetches job_meta.json via the Contents
-- API (authenticated). Returns the parsed
-- metadata table, the current sha, and
-- an error string. sha is required for
-- all subsequent update_file calls.
local function fetch_job_metadata_and_sha(
        branch, token)
    local data, sha, error_string =
        github.fetch_file_with_sha(
            META_PATH, branch, token
        )
    if error_string then
        return nil, nil, error_string
    end
    -- data.content is base64-encoded;
    -- decode by fetching via raw URL instead
    local url = RAW_ROOT .. branch
        .. "/" .. META_PATH
    local response, _ = http.get(url)
    if not response then
        return nil, sha, "raw fetch failed"
    end
    local raw = response.readAll()
    response.close()
    local parsed =
        textutils.unserialiseJSON(raw)
    return parsed, sha, nil
end

-- update_job_metadata
-- Writes updated metadata back to the
-- branch via the Contents API PUT.
-- Returns the new sha or nil on failure.
-- On failure, logs a warning but does NOT
-- abort the build — progress is cosmetic.
local function update_job_metadata(
        branch, token, current_sha,
        status, blocks_placed,
        blocks_total, turtle_id)
    local updated = {
        status        = status,
        blocks_placed = blocks_placed,
        blocks_total  = blocks_total,
        turtle_id     = turtle_id,
    }
    local content_string =
        textutils.serialiseJSON(updated)
    local new_sha, error_string =
        github.update_file(
            META_PATH,
            branch,
            content_string,
            current_sha,
            token,
            "build: " .. status
                .. " " .. blocks_placed
                .. "/" .. blocks_total
        )
    if error_string then
        print(
            "WARN: metadata update failed: "
            .. tostring(error_string)
        )
        return current_sha
    end
    return new_sha
end

-- =========================================
-- [6] MOVEMENT
-- =========================================

-- Turtle position in turtle-space.
-- (0,0,0) = home = starting position.
-- Facing: 0=+Z forward, 1=+X right,
--         2=-Z back,    3=-X left.
local cur_pos    = {x = 0, y = 0, z = 0}
local cur_facing = 0

local function turn_right()
    turtle.turnRight()
    cur_facing = (cur_facing + 1) % 4
end

local function turn_left()
    turtle.turnLeft()
    cur_facing = (cur_facing - 1 + 4) % 4
end

-- face_direction
-- Rotates the turtle to the given facing
-- using the minimum number of turns.
local function face_direction(target)
    local diff =
        (target - cur_facing + 4) % 4
    if diff == 1 then
        turn_right()
    elseif diff == 2 then
        turn_right()
        turn_right()
    elseif diff == 3 then
        turn_left()
    end
end

-- move_y
-- Moves the turtle vertically. Retries
-- up to MAX_MOVE_TRIES times with a short
-- sleep on failure. Errors if blocked.
local function move_y(target_y)
    local attempts = 0
    while cur_pos.y ~= target_y do
        attempts = attempts + 1
        if attempts > MAX_MOVE_TRIES then
            error("Y movement blocked.")
        end
        if target_y > cur_pos.y then
            if turtle.up() then
                cur_pos.y = cur_pos.y + 1
            else
                os.sleep(0.5)
            end
        else
            if turtle.down() then
                cur_pos.y = cur_pos.y - 1
            else
                os.sleep(0.5)
            end
        end
    end
end

-- move_x
-- Moves the turtle along the X axis.
-- Attacks obstacles to clear the path.
local function move_x(target_x)
    if target_x == cur_pos.x then return end
    if target_x > cur_pos.x then
        face_direction(1) -- +X
    else
        face_direction(3) -- -X
    end
    local attempts = 0
    while cur_pos.x ~= target_x do
        attempts = attempts + 1
        if attempts > MAX_MOVE_TRIES then
            error("X movement blocked.")
        end
        if turtle.forward() then
            if target_x > cur_pos.x then
                cur_pos.x = cur_pos.x + 1
            else
                cur_pos.x = cur_pos.x - 1
            end
        else
            turtle.attack()
            os.sleep(0.3)
        end
    end
end

-- move_z
-- Moves the turtle along the Z axis.
local function move_z(target_z)
    if target_z == cur_pos.z then return end
    if target_z > cur_pos.z then
        face_direction(0) -- +Z
    else
        face_direction(2) -- -Z
    end
    local attempts = 0
    while cur_pos.z ~= target_z do
        attempts = attempts + 1
        if attempts > MAX_MOVE_TRIES then
            error("Z movement blocked.")
        end
        if turtle.forward() then
            if target_z > cur_pos.z then
                cur_pos.z = cur_pos.z + 1
            else
                cur_pos.z = cur_pos.z - 1
            end
        else
            turtle.attack()
            os.sleep(0.3)
        end
    end
end

-- navigate_to
-- Navigates to (tx, ty, tz) in turtle
-- space. Always moves Y first (upward),
-- then X, then Z. Going down is handled
-- only by go_home which exits the interior
-- before descending.
local function navigate_to(tx, ty, tz)
    move_y(ty)
    move_x(tx)
    move_z(tz)
end

-- go_home
-- Returns turtle to (0,0,0). Must exit
-- the reactor interior (Z>0) before
-- descending, because placed blocks
-- occupy interior Z positions at Y=0.
local function go_home()
    move_z(0)
    move_y(0)
    move_x(0)
end

-- =========================================
-- [7] INVENTORY
-- =========================================

-- find_block_in_inventory
-- Returns the first slot containing the
-- named block, or nil if not found.
local function find_block_in_inventory(
        block_name)
    for slot = 1, 16 do
        local detail =
            turtle.getItemDetail(slot)
        if detail
                and detail.name ==
                    block_name then
            return slot
        end
    end
    return nil
end

-- restock_from_chest
-- Navigates home and sucks all available
-- items from the chest directly below.
-- Returns true if the needed block was
-- found after restocking, false if the
-- chest does not contain it.
-- Saves and restores position state.
local function restock_from_chest(
        block_name, return_x, return_y,
        return_z)
    print(
        "Restocking: " .. block_name
    )
    go_home()

    -- Dump all inventory to chest to make
    -- room. This lets us maximise the haul.
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            turtle.dropDown()
        end
    end

    -- Pull items from chest until full
    -- or chest is exhausted.
    local attempts = 0
    while attempts < MAX_SUCK_TRIES do
        attempts = attempts + 1
        if not turtle.suckDown() then
            break
        end
    end

    local slot =
        find_block_in_inventory(block_name)
    if not slot then
        return false
    end

    -- Return to build position
    navigate_to(return_x, return_y, return_z)
    return true
end

-- =========================================
-- [8] BUILD
-- =========================================

-- load_progress
-- Returns the number of blocks already
-- placed in a previous run, or 0.
local function load_progress(branch)
    local content =
        read_local_file(PROGRESS_PATH)
    if not content then return 0 end
    local data =
        textutils.unserialiseJSON(content)
    if not data
            or data.branch ~= branch then
        return 0
    end
    return data.blocks_placed or 0
end

-- save_progress
-- Writes current block count to disk so
-- a crash can be resumed.
local function save_progress(
        branch, blocks_placed)
    local data = {
        branch        = branch,
        blocks_placed = blocks_placed,
    }
    write_local_file(
        PROGRESS_PATH,
        textutils.serialiseJSON(data)
    )
end

-- build_reactor
-- Main build loop. Traverses the reactor
-- grid in boustrophedon order (Y then Z,
-- alternating X direction per Z row).
-- Skips air blocks. Skips already-placed
-- blocks when resuming. Updates metadata
-- every UPDATE_INTERVAL placements.
local function build_reactor(
        layout, branch, token,
        initial_sha, turtle_id)
    local grid   = layout.grid
    local size_y = layout.meta.sizeY
    local size_x = layout.meta.sizeX
    local size_z = layout.meta.sizeZ

    local blocks_total =
        count_non_air_blocks(layout)
    local resume_count =
        load_progress(branch)
    local blocks_placed = resume_count
    local scan_count    = 0
    local meta_sha      = initial_sha

    print(string.format(
        "Building %dx%dx%d (%d blocks)",
        size_x, size_y, size_z,
        blocks_total
    ))
    if resume_count > 0 then
        print(
            "Resuming from block "
            .. resume_count
        )
    end

    for ry = 0, size_y - 1 do
      for rz = 0, size_z - 1 do

        local forward = (rz % 2 == 0)

        for rx_index = 0, size_x - 1 do
          local rx
          if forward then
            rx = rx_index
          else
            rx = size_x - 1 - rx_index
          end

          local block =
            grid[ry+1][rx+1][rz+1]

          if block ~= "minecraft:air" then
            scan_count = scan_count + 1

            if scan_count > resume_count then
              -- Navigate one above target
              navigate_to(
                rx, ry + 1, rz + 1
              )

              -- Ensure block in inventory
              local slot =
                find_block_in_inventory(
                  block
                )
              if not slot then
                local ok =
                  restock_from_chest(
                    block,
                    rx, ry + 1, rz + 1
                  )
                if not ok then
                  error(
                    "Chest has no: "
                    .. block
                  )
                end
                slot =
                  find_block_in_inventory(
                    block
                  )
              end

              turtle.select(slot)

              local placed = false
              for _ = 1, 8 do
                if turtle.placeDown() then
                  placed = true
                  break
                end
                os.sleep(0.5)
              end

              if not placed then
                error(
                  "Cannot place at "
                  .. rx .. ","
                  .. ry .. ","
                  .. rz
                )
              end

              blocks_placed =
                blocks_placed + 1

              -- Periodic status update
              if blocks_placed
                    % UPDATE_INTERVAL
                    == 0 then
                print(string.format(
                  "  %d / %d placed",
                  blocks_placed,
                  blocks_total
                ))
                meta_sha =
                  update_job_metadata(
                    branch, token,
                    meta_sha,
                    "building",
                    blocks_placed,
                    blocks_total,
                    turtle_id
                  )
                save_progress(
                  branch, blocks_placed
                )
              end
            end
          end
        end
      end
    end

    return blocks_placed, blocks_total,
        meta_sha
end

-- =========================================
-- [9] ENTRY POINT
-- =========================================

term.clear()
term.setCursorPos(1, 1)
print("NC Fork Reactor Builder")
print(string.rep("-", 43))

-- Load configuration
local branch    = read_configured_branch()
local token     = load_github_token()
local turtle_id = os.getComputerID()

print("Branch  : " .. branch)
print("Turtle  : " .. tostring(turtle_id))
print("")

-- Fetch reactor layout
print("Fetching reactor.json...")
local layout = fetch_reactor_layout(branch)
print(string.format(
    "Reactor : %dx%dx%d  Fuel: %s",
    layout.meta.sizeX,
    layout.meta.sizeY,
    layout.meta.sizeZ,
    layout.meta.fuel or "?"
))
print("")

-- Fetch job metadata for progress tracking
print("Fetching job_meta.json...")
local metadata, meta_sha, meta_error =
    fetch_job_metadata_and_sha(
        branch, token
    )
if meta_error then
    print(
        "WARN: metadata unavailable: "
        .. meta_error
    )
    meta_sha = ""
end
print("")

-- Confirm before starting
io.write(
    "Ready. Press Enter to build, 0 exit: "
)
local confirm = io.read()
if confirm == "0" then
    print("Exiting.")
    return
end

-- Mark job as building
if meta_sha ~= "" then
    meta_sha = update_job_metadata(
        branch, token, meta_sha,
        "building", 0, 0, turtle_id
    )
end

-- Build
local placed, total, final_sha =
    build_reactor(
        layout, branch, token,
        meta_sha, turtle_id
    )

-- Return home and mark complete
go_home()

if final_sha and final_sha ~= "" then
    update_job_metadata(
        branch, token, final_sha,
        "complete", placed, total,
        turtle_id
    )
end

-- Clear progress file on success
if fs.exists(PROGRESS_PATH) then
    fs.delete(PROGRESS_PATH)
end

print("")
print(string.rep("=", 43))
print(string.format(
    "Complete! %d blocks placed.", placed
))
print("Seal the reactor front face.")
print(string.rep("=", 43))
