-- startup.lua
-- Runs on every boot. Fetches manifest, compares hashes, pulls changed files.
-- Reboots only when non-startup files change. If only startup.lua changed,
-- writes it silently and continues — picked up on the next natural reboot.

local REPO_BASE_URL = "https://raw.githubusercontent.com/ZacharyTPerry-lang/cc-repo/main/"
local MANIFEST_URL  = REPO_BASE_URL .. "manifest.json"
local STARTUP_PATH  = "startup.lua"

-- FNV-1a hash matching gen_manifest.py exactly
local function compute_hash(content)
    local hash_value = 2166136261
    for index = 1, #content do
        hash_value = bit32.bxor(hash_value, content:byte(index))
        hash_value = (hash_value * 16777619) % 2^32
    end
    return string.format("%08x", hash_value)
end

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

-- Fetch manifest
print("Checking for updates...")
local manifest_raw, fetch_error = fetch_url(MANIFEST_URL)

if not manifest_raw then
    print("Could not reach GitHub: " .. tostring(fetch_error))
    print("Running cached version.")
else
    local manifest = textutils.unserialiseJSON(manifest_raw)

    if not manifest then
        print("Manifest parse failed. Running cached version.")
    else
        local non_startup_changed = false
        local files_updated = 0

        for _, entry in ipairs(manifest.files) do
            local local_content = read_local_file(entry.path)
            local local_hash    = local_content and compute_hash(local_content) or ""

            if local_hash ~= entry.hash then
                local remote_content, download_error = fetch_url(REPO_BASE_URL .. entry.path)

                if remote_content then
                    write_local_file(entry.path, remote_content)
                    files_updated = files_updated + 1

                    if entry.path ~= STARTUP_PATH then
                        non_startup_changed = true
                    end
                else
                    print("WARN: could not fetch " .. entry.path .. ": " .. tostring(download_error))
                end
            end
        end

        if files_updated > 0 then
            print(files_updated .. " file(s) updated.")
        else
            print("Up to date.")
        end

        -- Only reboot if something other than startup.lua changed.
        -- startup.lua changes take effect on the next natural reboot.
        if non_startup_changed then
            print("Rebooting to apply changes...")
            os.sleep(0.5)
            os.reboot()
        end
    end
end

-- Run main program if present
if fs.exists("programs/main.lua") then
    shell.run("programs/main.lua")
else
    print("No programs/main.lua found. Ready.")
end
