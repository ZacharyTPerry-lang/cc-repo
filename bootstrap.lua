-- bootstrap.lua
-- Paste once into a fresh CC computer to initialize the updater.
-- Fetches startup.lua from the repo and reboots into it.

local REPO_BASE_URL = "https://raw.githubusercontent.com/ZacharyTPerry-lang/cc-repo/main/"

local function fetch_url(url)
    local response, error_message = http.get(url)
    if not response then
        error("Failed to fetch " .. url .. ": " .. tostring(error_message))
    end
    local content = response.readAll()
    response.close()
    return content
end

local function write_local_file(path, content)
    local file_handle = fs.open(path, "w")
    file_handle.write(content)
    file_handle.close()
end

print("Bootstrapping...")
print("Fetching startup.lua...")
write_local_file("startup.lua", fetch_url(REPO_BASE_URL .. "startup.lua"))
print("Done. Rebooting...")
os.sleep(1)
os.reboot()
