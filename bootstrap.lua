-- bootstrap.lua
-- Paste this once into a fresh CC computer to initialize the updater.
-- After this runs, startup.lua will handle all future updates.

local REPO = "https://raw.githubusercontent.com/ZacharyTPerry-lang/cc-repo/main/"

print("Bootstrapping CC updater...")

local function fetch(path)
    local url = REPO .. path
    local res, err = http.get(url)
    if not res then
        error("Failed to fetch " .. path .. ": " .. tostring(err))
    end
    local data = res.readAll()
    res.close()
    return data
end

local function writeFile(path, data)
    local f = fs.open(path, "w")
    f.write(data)
    f.close()
end

-- Pull startup.lua
print("Fetching startup.lua...")
writeFile("startup.lua", fetch("startup.lua"))

print("Bootstrap complete. Rebooting...")
os.sleep(1)
os.reboot()
