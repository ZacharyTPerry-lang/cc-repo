-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- programs/main.lua
-- Reactor channel selector for the
-- node/reactor-builder role.
-- Fetches job_meta.json from each of the
-- 10 reactor-N branches and displays a
-- status table. The operator selects a
-- channel or accepts auto-assignment to
-- the first queued slot. Writes role.cfg
-- and reboots into the chosen branch.
--
-- Enter 0 at any prompt to exit to shell.
--
-- Branches : node/reactor-builder
-- Depends  : none
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
--
-- [1] CONFIGURATION       ln. 24
-- [2] FILE OPERATIONS     ln. 36
-- [3] METADATA FETCH      ln. 55
-- [4] DISPLAY             ln. 95
-- [5] SELECTION           ln. 140
-- [6] ENTRY POINT         ln. 180
--
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-- =========================================
-- [1] CONFIGURATION
-- =========================================

local REPO_OWNER    = "ZacharyTPerry-lang"
local REPO_NAME     = "cc-repo"
local RAW_ROOT      =
    "https://raw.githubusercontent.com/"
    .. REPO_OWNER .. "/" .. REPO_NAME .. "/"
local CHANNEL_COUNT = 10
local ROLE_CFG_PATH = "role.cfg"
local SHA_PATH      = ".deployed_sha"

-- =========================================
-- [2] FILE OPERATIONS
-- =========================================

local function write_local_file(
        path, content)
    local directory = fs.getDir(path)
    if directory ~= ""
            and not fs.exists(directory) then
        fs.makeDir(directory)
    end
    local file_handle = fs.open(path, "w")
    file_handle.write(content)
    file_handle.close()
end

-- =========================================
-- [3] METADATA FETCH
-- =========================================

-- fetch_channel_metadata
-- Fetches job_meta.json from reactor-N via
-- the GitHub raw CDN. No authentication
-- needed for public repository reads.
-- Returns the parsed table or nil if the
-- branch has no job file yet (empty slot).
local function fetch_channel_metadata(
        channel_number)
    local branch = "reactor-"
        .. tostring(channel_number)
    local url = RAW_ROOT .. branch
        .. "/job_meta.json"
    local response, _ = http.get(url)
    if not response then
        return nil
    end
    local content = response.readAll()
    response.close()
    if not content or content == "" then
        return nil
    end
    return textutils.unserialiseJSON(content)
end

-- fetch_all_channel_metadata
-- Fetches metadata for all 10 channels.
-- Prints progress to the terminal.
-- Returns a table indexed 1..CHANNEL_COUNT.
local function fetch_all_channel_metadata()
    local channels = {}
    for number = 1, CHANNEL_COUNT do
        io.write(
            "  Fetching reactor-"
            .. tostring(number) .. "..."
        )
        channels[number] =
            fetch_channel_metadata(number)
        if channels[number] then
            print(" ok")
        else
            print(" empty")
        end
    end
    return channels
end

-- =========================================
-- [4] DISPLAY
-- =========================================

-- render_channel_table
-- Prints the channel status table within
-- the 51-character terminal width.
-- Returns the first queued channel number
-- or nil if none are queued.
local function render_channel_table(
        channels)
    print(string.rep("=", 43))
    print("  NC Fork — Reactor Channels")
    print(string.rep("=", 43))
    print(string.format(
        "  %-3s %-20s %-9s",
        "#", "Name", "Status"
    ))
    print("  " .. string.rep("-", 39))

    local first_queued = nil

    for number = 1, CHANNEL_COUNT do
        local metadata = channels[number]
        local status, name
        if not metadata then
            status = "empty"
            name   = "---"
        else
            status = metadata.status or "?"
            name   = metadata.name   or "---"
        end
        if #name > 20 then
            name = name:sub(1, 17) .. "..."
        end
        print(string.format(
            "  %-3d %-20s %-9s",
            number, name, status
        ))
        if status == "queued"
                and not first_queued then
            first_queued = number
        end
    end

    print("  " .. string.rep("-", 39))
    print("  0  Exit to shell")
    print(string.rep("=", 43))
    return first_queued
end

-- =========================================
-- [5] SELECTION
-- =========================================

-- prompt_channel_selection
-- Prompts the operator to enter a channel
-- number or press Enter for auto-assign.
-- Returns the selected number, or nil if
-- the operator entered 0 (exit).
local function prompt_channel_selection(
        first_queued)
    io.write(
        "Channel (Enter=auto, 0=exit): "
    )
    local raw_input = io.read()

    if raw_input == "0" then
        return nil
    end

    local parsed = tonumber(raw_input)
    if parsed
            and parsed >= 1
            and parsed <= CHANNEL_COUNT then
        return math.floor(parsed)
    end

    -- Empty or invalid input: auto-assign
    if first_queued then
        print(
            "Auto-assigning to reactor-"
            .. tostring(first_queued)
        )
        return first_queued
    end

    print("No queued channels available.")
    return nil
end

-- assign_to_channel
-- Writes role.cfg with the chosen branch
-- name and clears .deployed_sha to force
-- a full sync on the next boot.
local function assign_to_channel(
        channel_number)
    local branch = "reactor-"
        .. tostring(channel_number)
    write_local_file(
        ROLE_CFG_PATH,
        "branch=" .. branch .. "\n"
    )
    if fs.exists(SHA_PATH) then
        fs.delete(SHA_PATH)
    end
    print("")
    print("Assigned to " .. branch)
    print("Rebooting in 2 seconds...")
    os.sleep(2)
    os.reboot()
end

-- =========================================
-- [6] ENTRY POINT
-- =========================================

term.clear()
term.setCursorPos(1, 1)
print("NC Fork Reactor Channel Selector")
print(string.rep("-", 43))
print("Fetching channel status...")
print("")

local all_channels =
    fetch_all_channel_metadata()

print("")

local first_queued =
    render_channel_table(all_channels)

print("")

if not first_queued then
    print("No queued jobs. Publish a")
    print("reactor from the optimizer.")
    print("")
end

local selected_channel =
    prompt_channel_selection(first_queued)

if not selected_channel then
    print("")
    print("Exiting. Run programs/main.lua")
    print("to return to this selector.")
    return
end

assign_to_channel(selected_channel)
