-- startup.lua
-- On every boot: ask GitHub API for the latest commit SHA on main.
-- If it differs from the last deployed SHA, pull all files in file_list.json.
-- Reboots only when non-startup files are updated.

local GITHUB_API_URL    = "https://api.github.com/repos/ZacharyTPerry-lang/cc-repo/commits/main"
local REPO_BASE_URL     = "https://raw.githubusercontent.com/ZacharyTPerry-lang/cc-repo/main/"
local DEPLOYED_SHA_PATH = ".deployed_sha"
local STARTUP_PATH      = "startup.lua"

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

-- Ask GitHub API for the latest commit SHA
print("Checking for updates...")
local api_response, api_error = fetch_url(
    GITHUB_API_URL,
    { ["Accept"] = "application/vnd.github.v3+json" }
)

if not api_response then
    print("GitHub API unreachable: " .. tostring(api_error))
    print("Running cached version.")
else
    local api_data   = textutils.unserialiseJSON(api_response)
    local remote_sha = api_data and api_data.sha

    if not remote_sha then
        print("Could not parse SHA from API response. Running cached version.")
    else
        local deployed_sha = read_local_file(DEPLOYED_SHA_PATH)

        if deployed_sha then
            deployed_sha = deployed_sha:gsub("%s+", "")
        end

        if remote_sha == deployed_sha then
            print("Up to date. SHA: " .. remote_sha:sub(1, 7))
        else
            print("New commit: " .. remote_sha:sub(1, 7) .. ". Pulling files...")

            local file_list_raw, file_list_error = fetch_url(REPO_BASE_URL .. "file_list.json")
            if not file_list_raw then
                print("Could not fetch file_list.json: " .. tostring(file_list_error))
                print("Running cached version.")
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
end

-- Run main program if present
if fs.exists("programs/main.lua") then
    shell.run("programs/main.lua")
else
    print("No programs/main.lua found. Ready.")
end
