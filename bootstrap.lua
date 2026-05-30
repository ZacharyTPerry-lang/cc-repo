-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- bootstrap.lua
-- One-time initialization utility.
-- Paste into a fresh CC computer to pull
-- startup.lua from the main branch and reboot
-- into the sync system. After this runs,
-- startup.lua handles all future updates.
-- Never deployed to CC computers by the sync
-- system. Listed in deploy_banlist.json.
--
-- Branches : none (one-time paste only)
-- Depends  : none
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

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
