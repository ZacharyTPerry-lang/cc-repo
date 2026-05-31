-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- programs/main.lua
-- NC Fork fission reactor interior builder.
-- Implements the full slot state machine:
--   queued → claimed → building → done
--                    ↘ error
--
-- PHYSICAL SETUP:
--   Build reactor casing on all faces
--   except the front face. Place turtle
--   inside at the bottom-left-front corner
--   of the interior, facing +Z (into the
--   reactor). Place a chest directly below
--   the turtle's starting position and load
--   it with all required blocks.
--   The turtle restocks by returning home
--   and using turtle.suckDown().
--
--   Run:    programs/main.lua
--   Resume: automatic via progress file.
--   Abort:  Ctrl+T — error handler fires,
--           turtle returns home and writes
--           status=error to GitHub before
--           exiting.
--
-- Branches : reactor-1, reactor-2,
--            reactor-3, reactor-4,
--            reactor-5, reactor-6,
--            reactor-7, reactor-8,
--            reactor-9, reactor-10
-- Depends  : lib/base64, lib/github
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
--
-- [1]  CONFIGURATION      ln.  48
-- [2]  FILE OPERATIONS    ln.  70
-- [3]  CONFIG LOADING     ln.  90
-- [4]  SHARED STATE       ln. 120
-- [5]  GITHUB WRAPPERS    ln. 140
-- [6]  HEARTBEAT          ln. 200
-- [7]  REACTOR FETCH      ln. 240
-- [8]  CLAIM SLOT         ln. 280
-- [9]  PRE-BUILD CHECKS   ln. 340
-- [10] MOVEMENT           ln. 410
-- [11] INVENTORY          ln. 510
-- [12] BUILD LOOP         ln. 570
-- [13] ERROR HANDLER      ln. 660
-- [14] ENTRY POINT        ln. 690
--
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-- =========================================
-- [1] CONFIGURATION
-- =========================================

local github = require("lib.github")

local REPO_OWNER       = "ZacharyTPerry-lang"
local REPO_NAME        = "cc-repo"
local RAW_ROOT         =
    "https://raw.githubusercontent.com/"
    .. REPO_OWNER .. "/"
    .. REPO_NAME .. "/"
local ROLE_CFG_PATH    = "role.cfg"
local SELECTOR_BRANCH  = "node/reactor-builder"
local TOKEN_PATH       = ".github_token"
local PROGRESS_PATH    = "ncfork_progress.json"
local META_PATH        = "job_meta.json"
local REACTOR_PATH     = "reactor.json"
local DEPLOYED_SHA     = ".deployed_sha"

local MAX_MOVE_TRIES   = 64
local MAX_SUCK_TRIES   = 32
local FUEL_PER_BLOCK   = 6
local UPDATE_INTERVAL  = 50
local CLAIM_TIMEOUT_MS = 600000

-- Heartbeat intervals by activity (seconds)
local INTERVAL = {
    checking      = 60,
    confirmation  = 60,
    building      = 30,
    restocking    = 10,
    returning     = 15,
}

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
-- Returns the branch from role.cfg.
local function read_configured_branch()
    local content =
        read_local_file(ROLE_CFG_PATH)
    if not content then
        error("No role.cfg found.")
    end
    local branch =
        content:match("branch=([^\n]+)")
    if not branch then
        error("role.cfg: missing branch=")
    end
    return branch:gsub("%s+", "")
end

-- load_github_token
-- Reads .github_token, strips whitespace.
-- Written once at provisioning. Not pushed.
local function load_github_token()
    local raw = read_local_file(TOKEN_PATH)
    if not raw then
        error(
            "No .github_token found.\n"
            .. "Write token to " .. TOKEN_PATH
        )
    end
    return raw:match("^%s*(.-)%s*$")
end

-- return_to_selector
-- Reassigns role to node/reactor-builder
-- and reboots. Called when slot claim fails.
local function return_to_selector(reason)
    print("")
    print("Returning to selector:")
    print("  " .. tostring(reason))
    write_local_file(
        ROLE_CFG_PATH,
        "branch=" .. SELECTOR_BRANCH .. "\n"
    )
    if fs.exists(DEPLOYED_SHA) then
        fs.delete(DEPLOYED_SHA)
    end
    os.sleep(2)
    os.reboot()
end

-- =========================================
-- [4] SHARED STATE
-- =========================================

-- state is shared between the build and
-- heartbeat coroutines via cooperative
-- multitasking (parallel.waitForAny).
-- Only one coroutine runs at a time so
-- no locking is needed.
local state = {
    activity           = "starting",
    heartbeat_interval = INTERVAL.checking,
    meta_sha           = "",
    blocks_placed      = 0,
    blocks_total       = 0,
    last_x             = 0,
    last_y             = 0,
    last_z             = 0,
    done               = false,
}

-- =========================================
-- [5] GITHUB WRAPPERS
-- =========================================

-- fetch_meta_raw
-- Fetches job_meta.json via raw CDN.
-- Returns parsed table or nil on failure.
-- CDN may be up to ~30s behind latest push;
-- use only after the claim SHA is secured.
local function fetch_meta_raw(branch)
    local url = RAW_ROOT .. branch
        .. "/" .. META_PATH
    local response, _ = http.get(url)
    if not response then return nil end
    local content = response.readAll()
    response.close()
    return textutils.unserialiseJSON(content)
end

-- push_state_update
-- Writes current shared state fields into
-- job_meta.json on the branch. Updates
-- state.meta_sha with the new SHA on
-- success. On failure, logs a warning and
-- preserves the old SHA for retry.
-- This is the single write path used by
-- both the build loop and heartbeat.
local function push_state_update(
        branch, token,
        status, error_message)
    local now = os.epoch("utc")

    -- Fetch fresh meta to merge with state.
    -- We only overwrite the tracking fields;
    -- we preserve static fields (name, fuel,
    -- size, power, blocks_total, etc.).
    local meta = fetch_meta_raw(branch)
    if not meta then
        print(
            "WARN: cannot fetch meta for"
            .. " state update"
        )
        return
    end

    meta.status        = status
        or meta.status
    meta.activity      = state.activity
    meta.heartbeat_at  = now
    meta.blocks_placed = state.blocks_placed
    meta.last_position = {
        x = state.last_x,
        y = state.last_y,
        z = state.last_z,
    }
    if error_message then
        meta.error_message = error_message
    end
    if status == "building"
            and not meta.started_at then
        meta.started_at = now
    end
    if status == "done" then
        meta.completed_at = now
        meta.activity     = "done"
    end

    local new_sha, err, code =
        github.update_file(
            META_PATH, branch,
            textutils.serialiseJSON(meta),
            state.meta_sha,
            token,
            "state: " .. meta.activity
                .. " "
                .. tostring(
                    state.blocks_placed
                )
                .. "/"
                .. tostring(
                    state.blocks_total
                )
        )

    if new_sha then
        state.meta_sha = new_sha
    else
        -- 409 means SHA is stale — fetch
        -- fresh SHA on next heartbeat.
        -- Other errors are transient.
        print(
            "WARN: state push failed "
            .. "(code " .. tostring(code)
            .. "): " .. tostring(err)
        )
    end
end

-- =========================================
-- [6] HEARTBEAT
-- =========================================

-- run_heartbeat_loop
-- Runs as a parallel coroutine alongside
-- the build. Fires at state.heartbeat_interval
-- seconds. Terminates when state.done=true.
-- Does not raise errors — heartbeat failure
-- is non-fatal (the build continues and the
-- bridge will detect staleness if it stops).
local function run_heartbeat_loop(
        branch, token)
    while not state.done do
        local interval =
            state.heartbeat_interval
        -- Sleep in small increments so
        -- state.done changes are noticed
        -- quickly and state.heartbeat_interval
        -- changes take effect promptly.
        local elapsed = 0
        while elapsed < interval
                and not state.done do
            os.sleep(5)
            elapsed = elapsed + 5
        end
        if state.done then break end
        local ok = pcall(
            push_state_update,
            branch, token, nil, nil
        )
        if not ok then
            -- Swallow errors silently.
            -- Stale detection handles it.
        end
    end
end

-- =========================================
-- [7] REACTOR FETCH
-- =========================================

-- fetch_reactor_layout
-- Downloads reactor.json from this branch
-- via the GitHub raw CDN. Returns the
-- parsed layout table or calls error().
local function fetch_reactor_layout(branch)
    local url = RAW_ROOT .. branch
        .. "/" .. REACTOR_PATH
    local response, err_msg =
        http.get(url)
    if not response then
        error(
            "Cannot fetch reactor.json: "
            .. tostring(err_msg)
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
            "reactor.json missing or"
            .. " invalid. Publish first."
        )
    end
    return layout
end

-- count_non_air_blocks
-- Returns total placeable block count.
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
                if block ~= "minecraft:air"
                        then
                    count = count + 1
                end
            end
        end
    end
    return count
end

-- =========================================
-- [8] CLAIM SLOT
-- =========================================

-- claim_slot
-- Attempts an atomic slot claim via the
-- GitHub SHA optimistic-lock mechanism.
-- Returns: "ok", "conflict", or "error".
--   "ok"       — slot claimed, state.meta_sha
--                holds the new SHA.
--   "conflict" — another turtle claimed
--                first (409). Caller should
--                return to selector.
--   "error"    — network or parse failure.
--                Caller may retry or abort.
local function claim_slot(branch, token)
    print("Claiming slot...")

    -- Fetch current SHA via Contents API.
    -- This is authenticated so not CDN-cached.
    local api_data, sha, err_str =
        github.fetch_file_with_sha(
            META_PATH, branch, token
        )
    if err_str then
        return "error",
            "SHA fetch failed: " .. err_str
    end

    -- Fetch content via raw URL for parsing.
    local meta = fetch_meta_raw(branch)
    if not meta then
        return "error",
            "Cannot read job_meta.json"
    end

    -- Only claim if queued.
    if meta.status ~= "queued" then
        return "error",
            "Slot not queued: "
            .. tostring(meta.status)
    end

    -- Write claimed state.
    local turtle_id = os.getComputerID()
    local now       = os.epoch("utc")
    meta.status     = "claimed"
    meta.turtle_id  = turtle_id
    meta.claimed_at = now
    meta.activity   = "claiming"
    state.meta_sha  = sha

    local new_sha, write_err, http_code =
        github.update_file(
            META_PATH, branch,
            textutils.serialiseJSON(meta),
            sha, token,
            "claim: turtle-"
                .. tostring(turtle_id)
        )

    if not new_sha then
        if http_code == 409 then
            -- SHA mismatch: another turtle
            -- claimed this slot first.
            return "conflict",
                "Slot claimed by another"
                .. " turtle (409)"
        end
        return "error",
            "Claim write failed: "
            .. tostring(write_err)
    end

    state.meta_sha = new_sha
    print(
        "Claimed. SHA: "
        .. new_sha:sub(1, 7)
    )
    return "ok", nil
end

-- =========================================
-- [9] PRE-BUILD CHECKS
-- =========================================

-- compute_shopping_list
-- Returns a table mapping block_name→count
-- for all non-air blocks in the layout.
local function compute_shopping_list(layout)
    local counts = {}
    local grid   = layout.grid
    local size_y = layout.meta.sizeY
    local size_x = layout.meta.sizeX
    local size_z = layout.meta.sizeZ
    for ry = 0, size_y - 1 do
        for rx = 0, size_x - 1 do
            for rz = 0, size_z - 1 do
                local block =
                    grid[ry+1][rx+1][rz+1]
                if block ~= "minecraft:air"
                        then
                    counts[block] =
                        (counts[block] or 0)
                        + 1
                end
            end
        end
    end
    return counts
end

-- check_fuel
-- Verifies turtle has enough fuel for the
-- build. Estimates worst-case navigation
-- distance as FUEL_PER_BLOCK * blocks_total.
local function check_fuel(blocks_total)
    local level = turtle.getFuelLevel()
    if level == "unlimited" then return end
    local required =
        blocks_total * FUEL_PER_BLOCK
    if level < required then
        error(string.format(
            "Insufficient fuel: have %d,"
            .. " need ~%d."
            .. " Refuel and restart.",
            level, required
        ))
    end
    print(string.format(
        "Fuel: %d (need ~%d) OK",
        level, required
    ))
end

-- check_chest
-- Verifies a chest exists below home.
local function check_chest()
    local has_chest =
        turtle.getItemCount(1) > 0
        or turtle.suckDown()
    if not has_chest then
        error(
            "No chest below home or"
            .. " chest is empty."
            .. " Place chest and reload."
        )
    end
    print("Chest: OK")
end

-- display_shopping_list
-- Prints the block manifest. Truncates
-- block names to fit the 51-char terminal.
local function display_shopping_list(counts)
    print(string.rep("=", 43))
    print("  Shopping List")
    print(string.rep("-", 43))
    for block, count in pairs(counts) do
        local short =
            block:match(":(.+)$") or block
        -- Truncate name to fit:
        -- "  9999  " = 8 chars, leaves 43
        if #short > 33 then
            short = short:sub(1, 30) .. "..."
        end
        print(string.format(
            "  %4d  %s",
            count, short
        ))
    end
    print(string.rep("=", 43))
end

-- prompt_with_heartbeat
-- Shows a prompt and waits for input.
-- Fires GitHub heartbeat in the background
-- so the claimed→building bridge watchdog
-- does not time out during a long shopping
-- list review.
-- Returns the raw input string.
local function prompt_with_heartbeat(
        prompt_text, branch, token)
    local response = nil

    parallel.waitForAny(
        function()
            io.write(prompt_text)
            response = io.read()
        end,
        function()
            -- Heartbeat while waiting.
            while response == nil do
                os.sleep(60)
                if response == nil then
                    local ok = pcall(
                        push_state_update,
                        branch, token,
                        nil, nil
                    )
                    if not ok then end
                end
            end
        end
    )

    return response or ""
end

-- =========================================
-- [10] MOVEMENT
-- =========================================

-- Turtle position in turtle-space.
-- (0,0,0) = home = starting position.
-- Facing: 0=+Z  1=+X  2=-Z  3=-X
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
-- Rotates to target facing using the
-- minimum number of turns.
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
-- Moves vertically. Retries on failure.
-- Errors if blocked after MAX_MOVE_TRIES.
local function move_y(target_y)
    local attempts = 0
    while cur_pos.y ~= target_y do
        attempts = attempts + 1
        if attempts > MAX_MOVE_TRIES then
            error(
                "Y blocked after "
                .. MAX_MOVE_TRIES
                .. " attempts."
            )
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
-- Moves along X. Attacks obstacles.
local function move_x(target_x)
    if target_x == cur_pos.x then
        return
    end
    if target_x > cur_pos.x then
        face_direction(1)
    else
        face_direction(3)
    end
    local attempts = 0
    while cur_pos.x ~= target_x do
        attempts = attempts + 1
        if attempts > MAX_MOVE_TRIES then
            error(
                "X blocked after "
                .. MAX_MOVE_TRIES
                .. " attempts."
            )
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
-- Moves along Z. Attacks obstacles.
local function move_z(target_z)
    if target_z == cur_pos.z then
        return
    end
    if target_z > cur_pos.z then
        face_direction(0)
    else
        face_direction(2)
    end
    local attempts = 0
    while cur_pos.z ~= target_z do
        attempts = attempts + 1
        if attempts > MAX_MOVE_TRIES then
            error(
                "Z blocked after "
                .. MAX_MOVE_TRIES
                .. " attempts."
            )
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
-- Moves to (tx, ty, tz) in turtle-space.
-- Always moves Y first (upward to clear
-- placed layers), then X, then Z.
local function navigate_to(tx, ty, tz)
    move_y(ty)
    move_x(tx)
    move_z(tz)
end

-- go_home
-- Returns to (0,0,0). Exits interior
-- (Z=0) before descending to avoid
-- descending into placed blocks.
local function go_home()
    move_z(0)
    move_y(0)
    move_x(0)
end

-- go_home_best_effort
-- Like go_home but never raises an error.
-- Used by the error handler.
local function go_home_best_effort()
    local ok, err = pcall(go_home)
    if not ok then
        print(
            "Could not return home: "
            .. tostring(err)
        )
    end
end

-- =========================================
-- [11] INVENTORY
-- =========================================

-- find_block_in_inventory
-- Returns the first slot holding block_name
-- or nil if not found.
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
-- Navigates to home, dumps all inventory
-- into the chest below, refills from the
-- chest, then returns to the saved build
-- position. Returns true if the needed
-- block was found after restocking.
local function restock_from_chest(
        block_name,
        return_x, return_y, return_z)
    state.activity           = "restocking"
    state.heartbeat_interval =
        INTERVAL.restocking
    print(
        "Restocking: "
        .. (block_name:match(":(.+)$")
            or block_name)
    )

    go_home()

    -- Dump all inventory to chest first
    -- so we maximise the refill haul.
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            turtle.dropDown()
        end
    end

    -- Pull items until inventory is full
    -- or chest is exhausted.
    for _ = 1, MAX_SUCK_TRIES do
        if not turtle.suckDown() then
            break
        end
    end

    local found =
        find_block_in_inventory(block_name)
            ~= nil

    -- Return to build position.
    state.activity           = "returning"
    state.heartbeat_interval =
        INTERVAL.returning
    navigate_to(return_x, return_y, return_z)

    state.activity           = "building"
    state.heartbeat_interval =
        INTERVAL.building
    return found
end

-- =========================================
-- [12] BUILD LOOP
-- =========================================

-- load_progress
-- Returns blocks already placed in a
-- prior run, or 0 if no progress file.
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
-- Writes block count to disk for resume.
local function save_progress(
        branch, blocks_placed)
    write_local_file(
        PROGRESS_PATH,
        textutils.serialiseJSON({
            branch        = branch,
            blocks_placed = blocks_placed,
        })
    )
end

-- run_build
-- Core build coroutine. Runs inside
-- parallel.waitForAny alongside the
-- heartbeat coroutine. Transitions state
-- through pre-checks → building → done.
-- Errors propagate to the pcall wrapper
-- in the entry point for clean handling.
local function run_build(
        layout, branch, token,
        turtle_id)
    local grid   = layout.grid
    local size_y = layout.meta.sizeY
    local size_x = layout.meta.sizeX
    local size_z = layout.meta.sizeZ

    -- ---- Phase 1: Pre-build checks ----
    state.activity =
        "pre_check_fuel"
    state.heartbeat_interval =
        INTERVAL.checking
    push_state_update(
        branch, token, nil, nil
    )

    local total =
        count_non_air_blocks(layout)
    state.blocks_total = total
    check_fuel(total)

    state.activity = "pre_check_chest"
    push_state_update(
        branch, token, nil, nil
    )
    check_chest()

    -- ---- Phase 2: Shopping list ----
    state.activity =
        "awaiting_confirmation"
    state.heartbeat_interval =
        INTERVAL.confirmation
    push_state_update(
        branch, token, nil, nil
    )

    local shopping =
        compute_shopping_list(layout)
    display_shopping_list(shopping)

    print("")
    print(string.format(
        "Total: %d blocks, %dx%dx%d",
        total,
        size_x, size_y, size_z
    ))
    print("Fuel: " .. string.format(
        "%d required",
        total * FUEL_PER_BLOCK
    ))

    -- Check for existing progress.
    local resume_count =
        load_progress(branch)
    if resume_count > 0 then
        print(string.format(
            "Resume: %d/%d already placed",
            resume_count, total
        ))
    end

    -- Confirmation prompt. The heartbeat
    -- fires in the background so the
    -- 10-min claimed timeout does not
    -- expire during a long review.
    local confirm =
        prompt_with_heartbeat(
            "Enter=build, 0=abort: ",
            branch, token
        )
    if confirm == "0" then
        error("Aborted by operator.")
    end

    -- ---- Phase 3: Transition building ----
    state.activity =
        "building"
    state.blocks_placed =
        resume_count
    state.heartbeat_interval =
        INTERVAL.building
    push_state_update(
        branch, token, "building", nil
    )

    -- ---- Phase 4: Build loop ----
    local scan_count = 0

    for ry = 0, size_y - 1 do
      for rz = 0, size_z - 1 do

        -- Boustrophedon: even Z → X++,
        -- odd Z → X-- (snake scan).
        local forward = (rz % 2 == 0)

        for rx_i = 0, size_x - 1 do
          local rx
          if forward then
            rx = rx_i
          else
            rx = size_x - 1 - rx_i
          end

          local block =
            grid[ry+1][rx+1][rz+1]

          if block ~= "minecraft:air" then
            scan_count = scan_count + 1

            if scan_count >
                    resume_count then

              -- Navigate one above target.
              navigate_to(
                rx, ry + 1, rz + 1
              )

              -- Ensure block available.
              local slot =
                find_block_in_inventory(
                  block
                )
              if not slot then
                local found =
                  restock_from_chest(
                    block,
                    rx, ry + 1, rz + 1
                  )
                if not found then
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

              -- Attempt placement.
              local placed = false
              for _ = 1, 8 do
                if turtle.placeDown() then
                  placed = true
                  break
                end
                os.sleep(0.5)
              end

              if not placed then
                error(string.format(
                  "Cannot place at"
                  .. " (%d,%d,%d): %s",
                  rx, ry, rz,
                  block:match(":(.+)$")
                      or block
                ))
              end

              state.blocks_placed =
                state.blocks_placed + 1
              state.last_x = rx
              state.last_y = ry
              state.last_z = rz

              -- Periodic GitHub update.
              if state.blocks_placed
                    % UPDATE_INTERVAL
                    == 0 then
                push_state_update(
                  branch, token,
                  "building", nil
                )
                save_progress(
                  branch,
                  state.blocks_placed
                )
                print(string.format(
                  "  %d/%d (%.0f%%)",
                  state.blocks_placed,
                  total,
                  state.blocks_placed
                    / total * 100
                ))
              end
            end
          end
        end
      end
    end

    -- ---- Phase 5: Wrap up ----
    state.activity = "done"
    state.done     = true
    go_home()
    push_state_update(
        branch, token, "done", nil
    )

    -- Clear progress file on success.
    if fs.exists(PROGRESS_PATH) then
        fs.delete(PROGRESS_PATH)
    end
end

-- =========================================
-- [13] ERROR HANDLER
-- =========================================

-- handle_error
-- Called when run_build raises any error
-- including Ctrl+T "Terminated". Attempts
-- to return home, then writes status=error
-- to GitHub so the bridge and UI can see
-- the failure.
local function handle_error(
        error_message, branch, token)
    state.done = true
    print("")
    print(string.rep("!", 43))
    print("ERROR: " .. tostring(
        error_message
    ))
    print(string.rep("!", 43))

    go_home_best_effort()

    -- Save progress so resume is possible
    -- if the error was transient.
    if state.blocks_placed > 0 then
        save_progress(
            branch,
            state.blocks_placed
        )
        print(string.format(
            "Progress saved: %d blocks",
            state.blocks_placed
        ))
    end

    -- Write error state to GitHub.
    local ok = pcall(
        push_state_update,
        branch, token,
        "error",
        tostring(error_message)
    )
    if not ok then
        print(
            "WARN: could not write"
            .. " error state to GitHub."
        )
    end

    print("")
    print("Slot requires operator wipe.")
    print("Inspect partial build first.")
end

-- =========================================
-- [14] ENTRY POINT
-- =========================================

term.clear()
term.setCursorPos(1, 1)
print("NC Fork Reactor Builder")
print(string.rep("-", 43))

-- Load configuration.
local branch    = read_configured_branch()
local token     = load_github_token()
local turtle_id = os.getComputerID()

print("Branch  : " .. branch)
print("Turtle  : " .. tostring(turtle_id))
print("")

-- Fetch layout.
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

-- Claim slot (atomic).
state.activity = "claiming"
local claim_result, claim_err =
    claim_slot(branch, token)

if claim_result == "conflict" then
    return_to_selector(
        "Slot claimed by another turtle."
    )
    return
end

if claim_result == "error" then
    print(
        "Claim error: "
        .. tostring(claim_err)
    )
    print(
        "Check slot status and retry."
    )
    return
end

-- Run build with heartbeat in parallel.
-- pcall catches all errors including
-- Ctrl+T "Terminated" so the error
-- handler always fires cleanly.
local ok, err = pcall(function()
    parallel.waitForAny(
        function()
            run_build(
                layout, branch,
                token, turtle_id
            )
        end,
        function()
            run_heartbeat_loop(
                branch, token
            )
        end
    )
end)

if not ok then
    handle_error(err, branch, token)
else
    -- Success path.
    print("")
    print(string.rep("=", 43))
    print(string.format(
        "Done! %d blocks placed.",
        state.blocks_placed
    ))
    print("Seal the reactor front face.")
    print(string.rep("=", 43))
end
