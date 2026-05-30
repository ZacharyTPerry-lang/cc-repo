-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- configure_pc.lua
-- First-boot role selection utility.
-- Fetches the live list of role-tagged branches
-- from the GitHub API and presents them as a
-- numbered selection menu. Writes the chosen
-- role to role.cfg, deletes itself, and reboots
-- into the assigned branch. After this runs,
-- startup.lua handles all future syncs.
-- Enter 0 at any prompt to exit to terminal.
--
-- Branches : interactive_role_selector
-- Depends  : none
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
--
-- [1] CONFIGURATION       ln. 20
-- [2] FETCH               ln. 26
-- [3] DISPLAY             ln. 55
-- [4] INPUT               ln. 75
-- [5] ENTRY POINT         ln. 100
--
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-- ===========================================================================
-- [1] CONFIGURATION
-- ===========================================================================

local GITHUB_TAGS_URL         = "https://api.github.com/repos/ZacharyTPerry-lang/cc-repo/tags"
local ROLE_TAG_PREFIX         = "role/"
local ROLE_CONFIGURATION_PATH = "role.cfg"

-- ===========================================================================
-- [2] FETCH
-- ===========================================================================

local function fetch_url(url, request_headers)
    local response, error_message = http.get(url, request_headers)
    if not response then
        return nil, error_message
    end
    local content = response.readAll()
    response.close()
    return content
end

local function fetch_available_roles()
    local raw, error_message = fetch_url(
        GITHUB_TAGS_URL,
        { ["Accept"] = "application/vnd.github.v3+json" }
    )
    if not raw then
        return nil, "Could not reach GitHub API: " .. tostring(error_message)
    end

    local tag_list = textutils.unserialiseJSON(raw)
    if not tag_list then
        return nil, "Could not parse tag list from GitHub API response."
    end

    local available_roles = {}
    for _, tag_entry in ipairs(tag_list) do
        local tag_name = tag_entry.name
        if tag_name:sub(1, #ROLE_TAG_PREFIX) == ROLE_TAG_PREFIX then
            local branch_name = tag_name:sub(#ROLE_TAG_PREFIX + 1)
            table.insert(available_roles, {
                display_name = branch_name,
                branch       = branch_name,
            })
        end
    end

    if #available_roles == 0 then
        return nil, "No role tags found. Tag a branch with branch_manager.py tag <branch>."
    end

    table.sort(available_roles, function(first, second)
        return first.branch < second.branch
    end)

    return available_roles
end

-- ===========================================================================
-- [3] DISPLAY
-- ===========================================================================

local function clear_screen()
    term.clear()
    term.setCursorPos(1, 1)
end

local function print_header()
    print("=========================================")
    print("       CC Network Node Configurator      ")
    print("=========================================")
    print("")
    print("Select a role for this computer.")
    print("Enter 0 at any prompt to exit.")
    print("")
end

local function print_roles(available_roles)
    print("  [0] Exit to terminal")
    print("")
    for index, role in ipairs(available_roles) do
        print(string.format("  [%d] %s", index, role.display_name))
    end
    print("")
end

-- ===========================================================================
-- [4] INPUT
-- ===========================================================================

local function read_selection(role_count)
    while true do
        io.write("Enter role number: ")
        local input     = io.read()
        local selection = tonumber(input)
        if selection == 0 then return 0 end
        if selection ~= nil and selection >= 1 and selection <= role_count then
            return selection
        end
        print("Invalid. Enter 0 to " .. role_count .. ".")
    end
end

local function confirm_selection(role)
    print("")
    print("Role:   " .. role.display_name)
    print("Branch: " .. role.branch)
    print("")
    io.write("Confirm? [y/N/0 exit]: ")
    local input = io.read()
    if input == "0" then return "exit" end
    return input:lower() == "y" and "confirmed" or "cancelled"
end

local function write_role_configuration(branch)
    local file_handle = fs.open(ROLE_CONFIGURATION_PATH, "w")
    file_handle.write("branch=" .. branch .. "\n")
    file_handle.close()
end

local function exit_to_terminal()
    print("")
    print("Exiting to terminal.")
    print("Run configure_pc.lua to reconfigure.")
end

-- ===========================================================================
-- [5] ENTRY POINT
-- ===========================================================================

clear_screen()
print_header()
print("Fetching available roles from GitHub...")

local available_roles, fetch_error = fetch_available_roles()

if not available_roles then
    print("Error: " .. fetch_error)
    exit_to_terminal()
    return
end

while true do
    clear_screen()
    print_header()
    print_roles(available_roles)

    local selected_index = read_selection(#available_roles)

    if selected_index == 0 then
        exit_to_terminal()
        return
    end

    local selected_role = available_roles[selected_index]
    local confirmation  = confirm_selection(selected_role)

    if confirmation == "exit" then
        exit_to_terminal()
        return
    elseif confirmation == "cancelled" then
        print("Cancelled. Returning to selection...")
        os.sleep(1)
    elseif confirmation == "confirmed" then
        print("")
        print("Writing role configuration...")
        write_role_configuration(selected_role.branch)
        print("Removing configurator...")
        fs.delete("configure_pc.lua")
        print("Configuration complete.")
        print("Rebooting into: " .. selected_role.branch)
        os.sleep(2)
        os.reboot()
    end
end
