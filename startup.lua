-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- startup.lua
-- Boot-time synchronization entry point.
-- Runs on every reboot. Fetches the latest
-- commit SHA from the GitHub API and compares
-- it to the locally stored deployed SHA.
-- If they differ, fetches the deploy banlist,
-- pulls all non-banned lua files declared in
-- their headers for this branch, writes the
-- new SHA, and reboots if non-self files
-- changed. Drops to shell after sync.
-- If no role.cfg exists, fetches and runs
-- configure_pc.lua to assign a role.
--
-- Branches : main, interactive_role_selector,
--            node/test
-- Depends  : none
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
--
-- [1] CONFIGURATION       ln. 22
-- [2] FILE OPERATIONS     ln. 34
-- [3] SYNC                ln. 60
-- [4] ENTRY POINT         ln. 125
--
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-- ===========================================================================
-- [1] CONFIGURATION
-- ===========================================================================

local GITHUB_API_BASE_URL     = "https://api.github.com/repos/ZacharyTPerry-lang/cc-repo/commits/"
local GITHUB_RAW_BASE_URL     = "https://raw.githubusercontent.com/ZacharyTPerry-lang/cc-repo/"
local DEPLOY_BANLIST_FILENAME = "deploy_banlist.json"
local FILE_INDEX_FILENAME     = "file_index.json"
local DEPLOYED_SHA_PATH       = ".deployed_sha"
local ROLE_CONFIGURATION_PATH = "role.cfg"
local STARTUP_FILE_PATH       = "startup.lua"

-- ===========================================================================
-- [2] FILE OPERATIONS
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

local function read_local_file(path)
    if not fs.exists(path) then return nil end
    local file_handle = fs.open(path, "r")
    local content     = file_handle.readAll()
    file_handle.close()
    return content
end

local function write_local_file(path, content)
    local parent_directory = fs.getDir(path)
    if parent_directory ~= "" and not fs.exists(parent_directory) then
        fs.makeDir(parent_directory)
    end
    local file_handle = fs.open(path, "w")
    file_handle.write(content)
    file_handle.close()
end

-- ===========================================================================
-- [3] SYNC
-- ===========================================================================

local function read_configured_branch()
    local role_content = read_local_file(ROLE_CONFIGURATION_PATH)
    if not role_content then return "main" end
    local branch = role_content:match("branch=([^\n]+)")
    return branch or "main"
end

local function build_api_url(branch)
    return GITHUB_API_BASE_URL .. branch
end

local function build_raw_url(branch, file_path)
    return GITHUB_RAW_BASE_URL .. branch .. "/" .. file_path
end

local function fetch_remote_sha(branch)
    local api_response, api_error = fetch_url(
        build_api_url(branch),
        { ["Accept"] = "application/vnd.github.v3+json" }
    )
    if not api_response then
        return nil, api_error
    end
    local api_data   = textutils.unserialiseJSON(api_response)
    local remote_sha = api_data and api_data.sha
    return remote_sha
end

local function fetch_banlist(branch)
    local raw, error_message = fetch_url(
        build_raw_url(branch, DEPLOY_BANLIST_FILENAME)
    )
    if not raw then return nil, error_message end
    local banlist = textutils.unserialiseJSON(raw)
    if not banlist then return nil, "Failed to parse deploy_banlist.json" end
    local banned = {}
    for _, entry in ipairs(banlist.banned) do
        banned[entry] = true
    end
    return banned
end

local function fetch_file_index(branch)
    local raw, error_message = fetch_url(
        build_raw_url(branch, FILE_INDEX_FILENAME)
    )
    if not raw then return nil, error_message end
    local file_index = textutils.unserialiseJSON(raw)
    if not file_index then return nil, "Failed to parse file_index.json" end
    return file_index.files
end

local function sync_branch(branch, remote_sha)
    print("New commit: " .. remote_sha:sub(1, 7) .. ". Pulling files...")

    local banlist, banlist_error = fetch_banlist(branch)
    if not banlist then
        print("Could not fetch banlist: " .. tostring(banlist_error))
        return false
    end

    local file_list, file_list_error = fetch_file_index(branch)
    if not file_list then
        print("Could not fetch file index: " .. tostring(file_list_error))
        return false
    end

    local non_startup_changed = false
    local files_updated       = 0

    for _, file_path in ipairs(file_list) do
        if not banlist[file_path] then
            local content, download_error = fetch_url(
                build_raw_url(branch, file_path)
            )
            if content then
                write_local_file(file_path, content)
                files_updated = files_updated + 1
                if file_path ~= STARTUP_FILE_PATH then
                    non_startup_changed = true
                end
            else
                print("WARN: failed to fetch " .. file_path
                    .. ": " .. tostring(download_error))
            end
        end
    end

    write_local_file(DEPLOYED_SHA_PATH, remote_sha)
    print(files_updated .. " file(s) updated.")
    return non_startup_changed
end

-- ===========================================================================
-- [4] ENTRY POINT
-- ===========================================================================

if not fs.exists(ROLE_CONFIGURATION_PATH) then
    print("No role.cfg found. Fetching configurator...")
    local configurator_url = build_raw_url(
        "interactive_role_selector",
        "configure_pc.lua"
    )
    local content, fetch_error = fetch_url(configurator_url)
    if content then
        write_local_file("configure_pc.lua", content)
        shell.run("configure_pc.lua")
    else
        print("Could not fetch configurator: " .. tostring(fetch_error))
        print("Paste the bootstrap one-liner to reinitialize.")
    end
    return
end

local configured_branch = read_configured_branch()
print("Checking for updates on branch: " .. configured_branch)

local remote_sha, sha_error = fetch_remote_sha(configured_branch)

if not remote_sha then
    print("GitHub unreachable: " .. tostring(sha_error))
    print("Running cached version.")
else
    local deployed_sha = read_local_file(DEPLOYED_SHA_PATH)
    if deployed_sha then
        deployed_sha = deployed_sha:gsub("%s+", "")
    end

    if remote_sha == deployed_sha then
        print("Up to date. SHA: " .. remote_sha:sub(1, 7))
    else
        local non_startup_changed = sync_branch(configured_branch, remote_sha)
        if non_startup_changed then
            print("Rebooting to apply changes...")
            os.sleep(0.5)
            os.reboot()
        end
    end
end

if fs.exists("programs/main.lua") then
    shell.run("programs/main.lua")
else
    print("Ready.")
end
