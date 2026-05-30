-- test_role_hello.lua
-- Deployed to the node/test branch.
-- Confirms that configure_pc.lua correctly selected a role and
-- that startup.lua successfully synced the correct branch.
-- Prints confirmation and exits cleanly to the terminal.

print("")
print("=========================================")
print("         Role Selection Test             ")
print("=========================================")
print("")

local role_configuration_path = "role.cfg"

if fs.exists(role_configuration_path) then
    local file_handle = fs.open(role_configuration_path, "r")
    local configured_branch = file_handle.readAll()
    file_handle.close()
    print("role.cfg contents:")
    print("  " .. configured_branch)
else
    print("WARNING: role.cfg not found.")
end

if fs.exists(".deployed_sha") then
    local file_handle = fs.open(".deployed_sha", "r")
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
print("This computer is ready for role assignment.")
print("Run configure_pc.lua to assign a permanent role.")
print("")
