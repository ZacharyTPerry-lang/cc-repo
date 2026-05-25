-- startup.lua
-- On every boot: fetch deployed_sha.txt from raw.githubusercontent.com.
-- If SHA differs from last deployed, pull all files from repo.
-- Reboots only if non-startup files were updated.

local REPO_BASE_URL     = "https://raw.githubusercontent.com/ZacharyTPerry-lang/cc-repo/main/"
local REMOTE_SHA_URL    = REPO_BASE_URL .. "deployed_sha.txt"
local FILE_LIST_URL     = REPO_BASE_URL .. "file_list.json"
local DEPLOYED_SHA_PATH = ".deployed_sha"
local STARTUP_PATH      = "startup.lua"

local function fetch_url(url)
    local response, error_message = http.get(url)
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
    local content = file_handle.readAll()
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

-- Fetch latest SHA from repo
print("Checking for updates...")
local remote_sha, fetch_error = fetch_url(REMOTE_SHA_URL)

if not remote_sha then
    print("Could not reach GitHub: " .. tostring(fetch_error))
    print("Running cached version.")
else
    remote_sha         = remote_sha:gsub("%s+", "")
    local deployed_sha = read_local_file(DEPLOYED_SHA_PATH)

    if deployed_sha then
        deployed_sha = deployed_sha:gsub("%s+", "")
    end

    if remote_sha == deployed_sha then
        print("Up to date. SHA: " .. remote_sha:sub(1, 7))
    else
        print("New commit: " .. remote_sha:sub(1, 7) .. ". Pulling files...")

        local file_list_raw, file_list_error = fetch_url(FILE_LIST_URL)
        if not file_list_raw then
            print("Could not fetch file list: " .. tostring(file_list_error))
        else
            local file_list           = textutils.unserialiseJSON(file_list_raw)
            local non_startup_changed = false
            local files_updated       = 0

            for _, file_path in ipairs(file_list.files) do
                local content, download_error = fetch_url(REPO_BASE_URL .. file_path)
                if content then
                    write_local_file(file_path, content)
                    files_updated = files_updated + 1
                    if file_path ~= STARTUP_PATH then
                        non_startup_changed = true
                    end
                else
                    print("WARN: failed to fetch " .. file_path .. ": " .. tostring(download_error))
                end
            end

            write_local_file(DEPLOYED_SHA_PATH, remote_sha)
            print(files_updated .. " file(s) updated.")

            if non_startup_changed then
                print("Rebooting to apply changes...")
                os.sleep(0.5)
                os.reboot()
            end
        end
    end
end

-- Run main program if present
if fs.exists("programs/main.lua") then
    shell.run("programs/main.lua")
else
    print("No programs/main.lua found. Ready.")
end
