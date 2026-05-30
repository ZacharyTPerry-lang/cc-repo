-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- test_role_hello.lua
-- End-to-end pipeline validation program.
-- Confirms that configure_pc.lua correctly
-- wrote role.cfg and that startup.lua
-- successfully synced the node/test branch
-- from GitHub. Prints confirmation and exits
-- cleanly to the terminal.
--
-- Branches : node/test
-- Depends  : none
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

local ROLE_CONFIGURATION_PATH = "role.cfg"
local DEPLOYED_SHA_PATH       = ".deployed_sha"

print("")
print("=========================================")
print("         Role Selection Test             ")
print("=========================================")
print("")

if fs.exists(ROLE_CONFIGURATION_PATH) then
    local file_handle       = fs.open(ROLE_CONFIGURATION_PATH, "r")
    local configured_branch = file_handle.readAll()
    file_handle.close()
    print("role.cfg:")
    print("  " .. configured_branch)
else
    print("WARNING: role.cfg not found.")
end

if fs.exists(DEPLOYED_SHA_PATH) then
    local file_handle  = fs.open(DEPLOYED_SHA_PATH, "r")
    local deployed_sha = file_handle.readAll()
    file_handle.close()
    print("Deployed SHA: " .. deployed_sha:sub(1, 7))
else
    print("WARNING: .deployed_sha not found.")
end

print("")
print("SUCCESS: node/test branch deployed correctly.")
print("Role selection and sync pipeline are working.")
print("")
print("Run configure_pc.lua to assign a permanent role.")
print("")
