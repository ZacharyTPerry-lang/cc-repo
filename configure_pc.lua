-- configure_pc.lua
-- Runs once on first boot via the interactive_role_selector branch.
-- Fetches the live list of tagged roles from the GitHub API, presents
-- them as a numbered selection, writes the chosen role to /role.cfg,
-- deletes itself, and reboots into the assigned branch.
-- Enter 0 at any prompt to exit to the terminal without configuring.

local GITHUB_TAGS_URL      = "https://api.github.com/repos/ZacharyTPerry-lang/cc-repo/tags"
local ROLE_TAG_PREFIX      = "role/"
local ROLE_CONFIGURATION_PATH = "role.cfg"

local function clear_screen()
    term.clear()
    term.setCursorPos(1, 1)
end

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

    local roles = {}
    for _, tag_entry in ipairs(tag_list) do
        local tag_name = tag_entry.name
        if tag_name:sub(1, #ROLE_TAG_PREFIX) == ROLE_TAG_PREFIX then
            local branch_name = tag_name:sub(#ROLE_TAG_PREFIX + 1)
            table.insert(roles, {
                display_name = branch_name,
                branch       = branch_name,
            })
        end
    end

    if #roles == 0 then
        return nil, "No role tags found on GitHub. Tag a branch with 'python3 branch_manager.py tag <branch>'."
    end

    table.sort(roles, function(first, second)
        return first.branch < second.branch
    end)

    return roles
end

local function print_header()
    print("=========================================")
    print("       CC Network Node Configurator      ")
    print("=========================================")
    print("")
    print("Select a role for this computer.")
    print("Enter 0 at any prompt to exit to terminal.")
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

local function read_selection(role_count)
    while true do
        io.write("Enter role number: ")
        local input     = io.read()
        local selection = tonumber(input)
        if selection == 0 then
            return 0
        end
        if selection ~= nil and selection >= 1 and selection <= role_count then
            return selection
        end
        print("Invalid selection. Enter a number between 0 and " .. role_count .. ".")
    end
end

local function confirm_selection(role)
    print("")
    print("Selected role: " .. role.display_name)
    print("Branch:        " .. role.branch)
    print("")
    io.write("Confirm? [y/N/0 to exit]: ")
    local input = io.read()
    if input == "0" then
        return "exit"
    end
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
    print("Run 'shell.run(\"configure_pc.lua\")' to configure this computer.")
end

-- Main configuration flow
clear_screen()
print_header()

print("Fetching available roles from GitHub...")
local available_roles, fetch_error = fetch_available_roles()

if not available_roles then
    print("Error: " .. fetch_error)
    print("")
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
        print("Cancelled. Returning to role selection...")
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
