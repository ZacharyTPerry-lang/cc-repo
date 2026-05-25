-- startup.lua
-- Runs on every boot. Fetches manifest, compares hashes, pulls changed files.

local REPO = "https://raw.githubusercontent.com/ZacharyTPerry-lang/cc-repo/main/"
local MANIFEST_URL = REPO .. "manifest.json"

-- Simple FNV-1a hash for change detection
local function hash(s)
    local h = 2166136261
    for i = 1, #s do
        h = bit32.bxor(h, s:byte(i))
        h = (h * 16777619) % 2^32
    end
    return string.format("%08x", h)
end

local function fetch(url)
    local res, err = http.get(url)
    if not res then return nil, err end
    local data = res.readAll()
    res.close()
    return data
end

local function readLocal(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    local data = f.readAll()
    f.close()
    return data
end

local function writeFile(path, data)
    -- Ensure parent dirs exist
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local f = fs.open(path, "w")
    f.write(data)
    f.close()
end

-- Fetch and parse manifest
print("Checking for updates...")
local manifestRaw, err = fetch(MANIFEST_URL)
if not manifestRaw then
    print("Could not reach GitHub: " .. tostring(err))
    print("Running cached version...")
    -- Fall through to run whatever is already on disk
else
    local manifest = textutils.unserialiseJSON(manifestRaw)
    if not manifest then
        print("Bad manifest, running cached version...")
    else
        local updated = 0
        for _, entry in ipairs(manifest.files) do
            local localData = readLocal(entry.path)
            local localHash = localData and hash(localData) or ""
            if localHash ~= entry.hash then
                print("Updating: " .. entry.path)
                local data, ferr = fetch(REPO .. entry.path)
                if data then
                    writeFile(entry.path, data)
                    updated = updated + 1
                else
                    print("  WARN: failed to fetch " .. entry.path .. ": " .. tostring(ferr))
                end
            end
        end
        if updated > 0 then
            print(updated .. " file(s) updated. Rebooting...")
            os.sleep(0.5)
            os.reboot()
        else
            print("Up to date.")
        end
    end
end

-- Run main program if it exists
if fs.exists("programs/main.lua") then
    shell.run("programs/main.lua")
else
    print("No programs/main.lua found. Ready.")
end
